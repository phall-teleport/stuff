import Foundation
import AppKit
import Observation

struct Toast: Identifiable {
    enum Kind { case info, ok, err }
    let id = UUID()
    let text: String
    let kind: Kind
    var url: String? = nil
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let okLabel: String
    let destructive: Bool
    let action: () -> Void
    /// Optional second choice shown between the primary button and Cancel.
    var secondaryLabel: String? = nil
    var secondaryAction: (() -> Void)? = nil
}

enum InspectorTab: String, CaseIterable { case files = "Save locally", github = "GitHub" }

/// Where an agent's conversation file lives in a beam, relative to $HOME, so
/// a beam started from a phase can be checked for it before `--resume`.
enum PhaseRestore {
    /// nil when there's nothing to look for (a Codex session without a saved rollout path).
    static func conversationPath(sessionID: String, isCodex: Bool, codexRel: String, workDir: String) -> String? {
        if isCodex { return codexRel.isEmpty ? nil : ".codex/" + codexRel }
        return ".claude/projects/\(ClaudePaths.projectSlug(workDir))/\(sessionID).jsonl"
    }

    /// Prints "present" or "missing".
    static func checkScript(_ relPath: String) -> String {
        "test -f \"$HOME\"/\(Shell.quote(relPath)) && echo present || echo missing\n"
    }
}

/// All app state and actions. Views observe it; services do the work.
@MainActor
@Observable
final class AppModel {
    let store: Store
    var client: BeamClient
    var config: Config
    let isMock: Bool
    let osUser = ProcessInfo.processInfo.environment["USER"] ?? ""

    // beams & sessions
    var beams: [Beam] = []
    var beamsNote = ""
    /// True once `beams` reflects a successful `tsh beams ls`, so an empty or
    /// missing beam means "gone" rather than "not loaded yet".
    var beamsLoaded = false
    var sessions: [Session] = []
    var currentID: String?
    var items: [String: [TranscriptItem]] = [:]
    private var seq: [String: Int] = [:]
    var busy: Set<String> = []
    private var running: [String: RunningProcess] = [:]
    /// Tool-permission questions from Claude Code waiting for an answer, per session.
    var pendingPermissions: [String: [PermissionRequest]] = [:]
    /// Sessions where the user chose "allow everything for the rest of this turn".
    private var allowAllThisTurn: Set<String> = []
    // Persistent-session mode bookkeeping.
    private var lifeTasks: [String: Task<Void, Never>] = [:]
    private var persistentActive: Set<String> = []
    private var turnStart: [String: Date] = [:]
    var probeHint = ""
    var composer = ""
    /// Images pasted or dropped into the composer, sent with the next prompt.
    var composerImages: [ImageAttachment] = []
    /// Mirrors the composer's focus so ⌘V can attach images (Composer).
    var composerFocused = false
    /// True while `pi update --all` is running (Sessions header button).
    var updatingPi = false

    // teleport login
    var tsh = TshStatus()
    var tshChecked = false
    var tshPending: String? = nil          // banner text while waiting for a login
    var tshUser = ""
    var tshLoggingIn = false
    private var tshPollTask: Task<Void, Never>?

    // github
    var gh = GitHubAuthStatus()
    var ghChecked = false
    var ghLoggingIn = false
    var ghDeviceCode: String? = nil
    var repos: [GitHubRepo] = []
    var loadingRepos = false
    var branches: [String] = []
    var branchesFor = ""
    var newBranch = false
    var newBranchName = ""
    var syncLog: [String] = []
    var syncing = false

    // previous sessions from GitHub
    var showOpenFromGitHub = false
    var remoteSessions: [RemoteSession] = []
    var loadingRemote = false
    var remoteError = ""
    var remoteQuery = ""
    /// Beam chosen in the "continue this session" banner; "" means a new beam.
    var continueBeamID = ""
    /// Session whose "continue in a beam" sheet is open, if any.
    var continueSheetSessionID: String?
    var restoring: Set<String> = []


    // ui
    var showInspector = true
    var inspectorTab: InspectorTab = .files
    var toasts: [Toast] = []
    /// Sessions whose working directory is being saved to this Mac.
    var savingLocal: Set<String> = []

    // MCP servers (Settings → MCP servers; AppModel+MCP.swift)
    var mcpApps: [MCPApp] = []
    var mcpLoading = false
    var mcpNote = ""
    /// Supervisor state by key ("proxy:<server id>", "tunnel:<beam id>",
    /// "agentProxy" — see reconcileAgentProxy).
    var mcpStatus: [String: String] = [:]
    @ObservationIgnored var mcpSupervisors: [String: Supervisor] = [:]
    @ObservationIgnored var mcpTunnelPorts: [String: [Int]] = [:]
    @ObservationIgnored var mcpLoginWatch: Task<Void, Never>?
    @ObservationIgnored var mcpProxyHosts: [String: String] = [:]
    /// (agent, port) the running "agentProxy" supervisor was started with, to
    /// notice a Settings change that needs a restart.
    @ObservationIgnored var agentProxyParams: (agent: String, port: Int)?
    var confirm: ConfirmRequest? = nil

    init() throws {
        Shell.augmentPath()
        let st = try Store()
        let cfg = st.loadConfig()
        let mock = ProcessInfo.processInfo.environment["BEAMSUI_MOCK"] == "1"
        store = st
        config = cfg
        isMock = mock
        client = mock ? MockClient() : TshClient(bin: cfg.tshBin, proxy: cfg.proxy, login: cfg.login, auth: cfg.tshAuth, mfaBrowser: cfg.tshMFABrowser)
        tshUser = cfg.teleportUser.isEmpty ? (ProcessInfo.processInfo.environment["USER"] ?? "") : cfg.teleportUser
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAllMCP() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    /// After a Mac sleep, SSH tunnels/proxies are almost certainly dead even
    /// before keepalives or health probes would notice — the sleep itself is
    /// the trigger, not just a network blip. Force every supervised process
    /// to restart and re-check login state immediately rather than waiting
    /// out ServerAliveInterval/health-probe thresholds.
    private func handleWake() {
        guard !isMock else { return }
        for sup in mcpSupervisors.values where sup.isRunning { sup.restart() }
        Task { [weak self] in _ = await self?.checkTsh() }
    }

    var current: Session? { sessions.first { $0.id == currentID } }
    var currentItems: [TranscriptItem] { currentID.flatMap { items[$0] } ?? [] }
    var currentBusy: Bool { currentID.map { busy.contains($0) } ?? false }
    var backendLabel: String { isMock ? "mock" : (config.proxy.isEmpty ? "tsh" : config.proxy) }

    var tshClient: TshClient { TshClient(bin: config.tshBin, proxy: config.proxy, login: config.login, auth: config.tshAuth, mfaBrowser: config.tshMFABrowser) }

    // MARK: boot

    func boot() async {
        sessions = store.listSessions()
        // Drop 🌐 URLs recorded by older builds that weren't published apps
        // (e.g. https://anthropic.<tenant>, the beam's API proxy).
        for s in sessions where s.publishedUrls.contains(where: { !PublishedURLs.isPublishedApp($0, proxy: config.proxy) }) {
            updateSession(s.id) { $0.publishedUrls.removeAll { !PublishedURLs.isPublishedApp($0, proxy: self.config.proxy) } }
        }
        backfillCodexUsage()
        if isMock { tsh = TshStatus(tshFound: true, loggedIn: true, proxy: "mock", user: "mock", cluster: "mock", message: "Mock backend"); tshChecked = true }
        await refreshGitHub()
        if await checkTsh() { await loadBeams() } else { beamsNote = "Log in to Teleport to see your sandboxes." }
        reconcileAgentProxy()
    }

    // MARK: toasts & confirm

    func toast(_ text: String, _ kind: Toast.Kind = .info, url: String? = nil, seconds: Double = 4.5) {
        let t = Toast(text: text, kind: kind, url: url)
        toasts.append(t)
        Task { try? await Task.sleep(for: .seconds(seconds)); toasts.removeAll { $0.id == t.id } }
    }

    func fail(_ e: Error) { toast(e.localizedDescription, .err, seconds: 8) }

    func ask(_ title: String, _ message: String, ok: String, destructive: Bool = false, _ action: @escaping () -> Void) {
        confirm = ConfirmRequest(title: title, message: message, okLabel: ok, destructive: destructive, action: action)
    }

    // MARK: config

    func saveConfig() {
        do {
            try store.saveConfig(config)
            if !isMock { client = tshClient }
        } catch { fail(error) }
    }

    // MARK: beams

    func loadBeams() async {
        do {
            beams = try await client.list()
            beamsLoaded = true
            pruneMCPTunnels()
            beamsNote = beams.isEmpty ? "No sandboxes. Click ＋ to create one." : ""
            // Don't move the Continue sheet's selection while it's open (an empty
            // selection there means "a new beam"); only drop a beam that vanished.
            if continueSheetSessionID == nil {
                if continueBeamID.isEmpty || !beams.contains(where: { $0.id == continueBeamID }) { continueBeamID = beams.first?.id ?? "" }
            } else if !continueBeamID.isEmpty, !beams.contains(where: { $0.id == continueBeamID }) {
                continueBeamID = ""
            }
            for s in sessions where s.phase.isEmpty && !s.isLocal { adoptBuildPhase(s.id) }
        } catch {
            beams = []
            beamsLoaded = false
            if error is NotFoundError || TshClient.isAuthError(error) {
                _ = await checkTsh()
                beamsNote = "Log in to Teleport to see your sandboxes."
            } else {
                beamsNote = "Couldn't list beams"
                fail(error)
            }
        }
    }

    /// ＋ New Beam: starts from the default phase when one is set (Phases
    /// window → Use for New Beams), else the cluster's default image.
    func createBeam() async {
        if !config.defaultPhase.isEmpty,
           let b = await beamFromPhase(config.defaultPhase, fallback: "Creating a plain beam instead.") {
            toast("Beam \(b.name) ready from phase \(config.defaultPhase)", .ok)
            await startSession(on: b)
            return
        }
        toast("Creating beam…")
        do {
            let b = try await client.create()
            toast("Beam \(b.name) ready", .ok)
            await loadBeams()
            await startSession(on: b)
        } catch { fail(error) }
    }

    func deleteBeam(_ b: Beam) {
        ask("Delete beam \(b.name)?", "This destroys the sandbox VM and anything in it.", ok: "Delete beam", destructive: true) { [self] in
            Task {
                stopTunnel(b.id)
                do { try await client.delete(id: b.id); toast("Deleted \(b.name)", .ok); await loadBeams() } catch { fail(error) }
            }
        }
    }

    // MARK: phases

    /// A session on a build beam belongs to the phase that beam is building:
    /// its /home is what gets snapshotted, so continuing later can start from
    /// that phase. No-op if the session already has a phase or the beam isn't
    /// a build beam (or the phase list hasn't loaded yet; later calls catch up).
    /// Beams merely *started* from a phase don't count: their work isn't
    /// snapshotted into it.
    func adoptBuildPhase(_ sessionID: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }), s.phase.isEmpty, !s.isLocal,
              let beam = beams.first(where: { $0.id == s.beamId }),
              let p = PhaseCenter.shared.buildPhase(for: beam) else { return }
        updateSession(sessionID) { $0.phase = p.name }
    }

    /// `tsh beams add --phase=<phase>`; nil (after a toast ending in
    /// `fallback`) if that's not possible, so the caller can fall back.
    private func beamFromPhase(_ phase: String, fallback: String) async -> Beam? {
        guard !isMock, let tsh = client as? TshClient else { return nil }
        toast("Starting a beam from phase \(phase)…")
        do {
            let id = try await tsh.beamAddFromPhase(phase)
            await loadBeams()
            return beams.first { $0.id == id || $0.raw["uuid"] == id } ?? Beam(id: id, name: id)
        } catch {
            let msg = PhaseText.clean(error.localizedDescription)
            let why = PhaseError.isUnsupportedCommand(msg)
                ? "tsh at \(tsh.bin) is too old for Phase; it needs v\(TshVersion.phaseMinimum) or newer"
                : String(msg.prefix(200))
            toast("Couldn't start a beam from phase \(phase) (\(why)). \(fallback)", .err, seconds: 9)
            return nil
        }
    }

    /// Whether the agent's conversation file for `s` is already in the beam
    /// (it is when the phase snapshot was taken after the session's turns).
    private func conversationInBeam(_ s: Session, _ beamID: String) async -> Bool {
        guard let path = PhaseRestore.conversationPath(sessionID: s.id, isCodex: !s.codexThread.isEmpty,
                                                       codexRel: s.codexSessionRel, workDir: config.workDir),
              let res = try? await runInBeam(beamID, PhaseRestore.checkScript(path), timeout: 60) else { return false }
        return res.stdoutText.contains("present")
    }

    // MARK: sessions

    func startSession(on beam: Beam) async {
        let id: String
        // Reuse an untouched session on this beam instead of piling up empties.
        if let empty = sessions.first(where: { $0.beamId == beam.id && $0.turns == 0 && $0.title.isEmpty && !busy.contains($0.id) }) {
            id = empty.id
            openSession(empty.id)
        } else {
            let s = Session(id: UUID().uuidString.lowercased(), beamId: beam.id, beamName: beam.name)
            do { try store.saveSession(s) } catch { fail(error); return }
            sessions.insert(s, at: 0)
            id = s.id
            openSession(s.id)
        }
        adoptBuildPhase(id)
        await probe(beam.id)
    }

    func openSession(_ id: String) {
        invalidateRestorePlan(id)   // recompute once per open, never per render
        currentID = id
        if items[id] == nil {
            var seqN = 0
            var list: [TranscriptItem] = []
            for ln in store.readTranscript(id) {
                guard let ev = StreamEvent(line: ln) else { continue }
                if CodexEvents.isCodexLine(ev) {
                    list += CodexEvents.items(from: ev, seq: &seqN).items
                } else if PiEvents.isPiLine(ev) {
                    list += PiEvents.items(from: ev, seq: &seqN)
                } else {
                    list += TranscriptItem.items(from: ev, seq: &seqN)
                    TranscriptItem.attachToolResults(from: ev, into: &list)
                }
            }
            items[id] = list
            seq[id] = seqN
            backfillPublished(id)
        }
        syncLog = []
        syncLogBranchState()
    }

    /// Removing a session offers to delete its beam too, since that's usually
    /// what "I'm done with this" means. Other sessions on the same beam are
    /// called out so the sandbox isn't destroyed under them by accident.
    func deleteSession(_ s: Session) {
        let name = s.title.isEmpty ? "this session" : "\"\(s.title)\""
        let removeLocal: () -> Void = { [self] in
            stop(s.id)
            endPersistent(s.id)
            do { try store.deleteSession(s.id) } catch { fail(error) }
            sessions.removeAll { $0.id == s.id }
            items[s.id] = nil
            if currentID == s.id { currentID = nil }
        }
        if s.isLocal {
            ask("Remove \(name)?", "This only removes the transcript; \(s.localWorkDir) on this Mac is untouched.", ok: "Remove session", destructive: true, removeLocal)
            return
        }
        let beamExists = beams.contains { $0.id == s.beamId }
        guard beamExists else {
            ask("Remove \(name)?", "Its beam \(s.beamName) is already gone; this only removes the local transcript.", ok: "Remove session", destructive: true, removeLocal)
            return
        }
        let others = sessions.filter { $0.beamId == s.beamId && $0.id != s.id }.count
        var msg = "Deleting beam \(s.beamName) destroys the sandbox VM and everything in it."
        if others > 0 { msg += " \(others) other session\(others == 1 ? "" : "s") also use\(others == 1 ? "s" : "") this beam." }
        confirm = ConfirmRequest(
            title: "Remove \(name)?", message: msg, okLabel: "Remove & delete beam \(s.beamName)", destructive: true,
            action: { [self] in
                removeLocal()
                Task {
                    do { try await client.delete(id: s.beamId); toast("Deleted beam \(s.beamName)", .ok) }
                    catch { toast("Session removed, but deleting the beam failed: \(error.localizedDescription)", .err, seconds: 8) }
                    await loadBeams()
                }
            },
            secondaryLabel: "Remove session only", secondaryAction: removeLocal)
    }

    private func probe(_ beamID: String) async {
        guard sshBlockedReason == nil else { probeHint = "can't reach the beam with this Teleport login"; return }
        do {
            var lines: [String] = []
            try await client.run(id: beamID, script: AgentScripts.probe, stdin: nil, interactiveStdin: false, timeout: 60, onStdoutLine: { lines.append($0) }, onStderrLine: nil, register: nil)
            if lines.count >= 2 { probeHint = "\(lines[0])@\(lines[1]) · \(lines.count > 2 ? lines[2] : "")" }
        } catch { noteSSHFailure(error.localizedDescription); probeHint = "probe failed: \(error.localizedDescription)" }
    }

    func updateSession(_ id: String, _ f: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        f(&sessions[i])
        try? store.saveSession(sessions[i])
    }

    // MARK: turns

    func send() {
        let prompt = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = composerImages
        guard let s = current, !prompt.isEmpty || !images.isEmpty, !busy.contains(s.id) else { return }
        composer = ""
        composerImages = []
        Task { await runTurn(sessionID: s.id, prompt: prompt, images: images) }
    }

    func attachImages(_ imgs: [ImageAttachment]) {
        guard current != nil else { return }
        let room = 8 - composerImages.count
        if imgs.count > room { toast("Up to 8 images per prompt.", .err) }
        composerImages += imgs.prefix(max(0, room))
    }

    /// Keeps a turn's images with the session (shown in the transcript) and
    /// returns their paths relative to the session directory.
    private func saveImages(_ sessionID: String, _ images: [ImageAttachment]) -> [String] {
        guard !images.isEmpty else { return [] }
        let dir = store.imagesDir(sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return images.compactMap { img in
            (try? img.data.write(to: dir.appendingPathComponent(img.fileName))) == nil ? nil : "images/\(img.fileName)"
        }
    }

    /// Title for a new session from its first prompt.
    private func titleFor(_ prompt: String, images: Int) -> String {
        let t = String(prompt.split(separator: "\n").first.map(String.init)?.prefix(80) ?? "")
        return t.isEmpty && images > 0 ? "Image" : t
    }

    /// Persistent-session mode: keep one Claude process alive per session and
    /// feed each turn to it. Env override `BEAMSUI_PERSISTENT=1` forces it on.
    var usePersistent: Bool { config.persistentSession || ProcessInfo.processInfo.environment["BEAMSUI_PERSISTENT"] == "1" }

    private func recordUserTurn(_ sessionID: String, _ prompt: String, images: [ImageAttachment] = []) {
        if var s = sessions.first(where: { $0.id == sessionID }) {
            if s.title.isEmpty { s.title = titleFor(prompt, images: images.count) }
            s.updated = Date()
            updateSession(sessionID) { $0 = s }
        }
        var userLine: [String: Any] = ["type": "beamsui.user", "text": prompt, "ts": RFC3339.string(Date())]
        let paths = saveImages(sessionID, images)
        if !paths.isEmpty { userLine["images"] = paths }
        if let d = try? JSONSerialization.data(withJSONObject: userLine), let ln = String(data: d, encoding: .utf8) {
            store.appendTranscript(sessionID, line: ln)
            if let ev = StreamEvent(line: ln) { ingest(sessionID, ev) }
        }
    }

    /// A session's beam is gone once the beam list has loaded and doesn't
    /// contain it (beams expire; imported sessions start without one). Local
    /// sessions have no beam at all, so they're never "gone".
    func beamGone(_ s: Session) -> Bool {
        !s.isLocal && beamsLoaded && !beams.contains(where: { $0.id == s.beamId })
    }

    /// First prompt after moving a session to a beam without its conversation
    /// file: point the agent at the restored transcript so it has context.
    private func promptToSend(_ s: Session, _ prompt: String) -> String {
        guard s.needsFreshStart else { return prompt }
        return "(Context: this continues an earlier session that ran in a different sandbox. "
            + "Its project files and memory were restored here, and the earlier conversation is in "
            + ".beams/previous-session.md. Read it first if you need the background.)\n\n" + prompt
    }

    private func runTurn(sessionID: String, prompt: String, images: [ImageAttachment] = []) async {
        guard let session0 = sessions.first(where: { $0.id == sessionID }) else { return }
        if session0.isLocal {
            if !images.isEmpty { toast("Images aren't sent to local pi sessions yet.", .info) }
            runPiTurn(sessionID: sessionID, prompt: prompt)
            return
        }
        if beamGone(session0) {
            composer = prompt; composerImages = images   // give the prompt back
            toast("The beam \(session0.beamName.isEmpty ? "for this session" : session0.beamName) is gone. Continue the session in a beam from the banner above.", .err, seconds: 7)
            return
        }
        guard sshAllowed() else { composer = prompt; composerImages = images; return }
        adoptBuildPhase(sessionID)
        prepareMCP(beamID: session0.beamId)
        if config.agent == "codex" { runCodexTurn(sessionID: sessionID, prompt: prompt, images: images); return }
        if usePersistent { runTurnPersistent(sessionID: sessionID, prompt: prompt, images: images); return }
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        busy.insert(sessionID)
        turnStart[sessionID] = Date()
        recordUserTurn(sessionID, prompt, images: images)

        let opts = TurnOptions(sessionID: sessionID, resume: s.turns > 0 && !s.needsFreshStart, workDir: config.workDir, prompt: prompt,
                               permissionMode: config.permissionMode, model: config.model, mcpServers: config.mcpServers)
        let firstMessage = TurnOptions.userMessage(promptToSend(s, prompt), images: images)
        var errMsg = ""
        do {
            // The prompt travels as the first stream-json message on stdin; the
            // same pipe carries our answers to permission requests.
            try await client.run(id: s.beamId, script: opts.script, stdin: nil, interactiveStdin: true, timeout: nil,
                                 onStdoutLine: { [weak self] line in Task { @MainActor in self?.handleLine(sessionID, line) } },
                                 onStderrLine: { [weak self] line in Task { @MainActor in self?.appendStderr(sessionID, line) } },
                                 register: { [weak self] p in
                                     Task { @MainActor in
                                         self?.running[sessionID] = p
                                         p.send(line: firstMessage)
                                     }
                                 })
        } catch {
            errMsg = running[sessionID] == nil ? "stopped" : error.localizedDescription
            if let p = running[sessionID], !p.process.isRunning, p.process.terminationReason == .uncaughtSignal { errMsg = "stopped" }
        }
        running[sessionID] = nil
        pendingPermissions[sessionID] = nil
        allowAllThisTurn.remove(sessionID)
        busy.remove(sessionID)
        logTurnLatency(sessionID)
        if !errMsg.isEmpty {
            noteSSHFailure(errMsg)
            appendItem(sessionID, TranscriptItem(id: nextSeq(sessionID), kind: .result, text: errMsg, ok: false))
            if TshClient.isAuthError(ProcessError(command: "", status: 1, stderr: errMsg)) || errMsg.contains("not found") { _ = await checkTsh() }
        } else if config.github.autoSync {
            await pullMemory(sessionID, quiet: true)
            await syncNow(sessionID)
        }
    }

    func stop(_ id: String? = nil) {
        guard let id = id ?? currentID, let p = running[id] else { return }
        p.terminate()  // in persistent mode this ends the session process; next turn restarts with --resume
    }

    // MARK: persistent-session turns

    /// One long-lived Claude process per session; turns are stream-json user
    /// messages sent to it (no per-turn tsh/claude startup). Verified that a
    /// single `claude -p --input-format stream-json` handles turns in sequence.
    private func runTurnPersistent(sessionID: String, prompt: String, images: [ImageAttachment] = []) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        busy.insert(sessionID)
        turnStart[sessionID] = Date()
        recordUserTurn(sessionID, prompt, images: images)
        let msg = TurnOptions.userMessage(promptToSend(s, prompt), images: images)

        // Process already alive → just send the next turn.
        if persistentActive.contains(sessionID), let p = running[sessionID] {
            p.send(line: msg)
            return
        }

        // Start the session process; it stays up for later turns.
        let opts = TurnOptions(sessionID: sessionID, resume: s.turns > 0 && !s.needsFreshStart, workDir: config.workDir,
                               prompt: "", permissionMode: config.permissionMode, model: config.model, mcpServers: config.mcpServers)
        persistentActive.insert(sessionID)
        lifeTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            var errMsg = ""
            do {
                try await self.client.run(id: s.beamId, script: opts.script, stdin: nil, interactiveStdin: true, timeout: nil,
                    onStdoutLine: { line in Task { @MainActor in self.handleLine(sessionID, line) } },
                    onStderrLine: { line in Task { @MainActor in self.appendStderr(sessionID, line) } },
                    register: { p in Task { @MainActor in self.running[sessionID] = p; p.send(line: msg) } })
            } catch {
                errMsg = error.localizedDescription
            }
            await MainActor.run {
                self.running[sessionID] = nil
                self.persistentActive.remove(sessionID)
                self.lifeTasks[sessionID] = nil
                self.pendingPermissions[sessionID] = nil
                self.allowAllThisTurn.remove(sessionID)
                let wasBusy = self.busy.remove(sessionID) != nil
                // If the process died mid-turn (not a clean stop), surface it.
                if !errMsg.isEmpty { self.noteSSHFailure(errMsg) }
                if wasBusy && !errMsg.isEmpty && !errMsg.lowercased().contains("cancel") {
                    self.appendItem(sessionID, TranscriptItem(id: self.nextSeq(sessionID), kind: .result, text: errMsg, ok: false))
                    if TshClient.isAuthError(ProcessError(command: "", status: 1, stderr: errMsg)) { Task { _ = await self.checkTsh() } }
                }
            }
        }
    }

    // MARK: Codex turns

    /// Runs one `codex exec` turn (OpenAI Codex CLI). Codex has no interactive
    /// permission protocol — beams are externally sandboxed, so approvals are
    /// bypassed. Context continues via the thread id captured on thread.started.
    private func runCodexTurn(sessionID: String, prompt: String, images: [ImageAttachment] = []) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        busy.insert(sessionID)
        turnStart[sessionID] = Date()
        recordUserTurn(sessionID, prompt, images: images)
        // Codex reads images from files: they go to <workDir>/.beams/images
        // first (.beams is never synced) and are passed with -i.
        let imageDir = config.workDir + "/.beams/images"
        var turn = CodexTurn(workDir: config.workDir, model: config.model,
                             prompt: promptToSend(s, prompt.isEmpty ? "Look at the attached image." : prompt),
                             resumeThread: s.needsFreshStart ? "" : s.codexThread, mcpServers: config.mcpServers)
        turn.imagePaths = images.map { imageDir + "/" + $0.fileName }
        Task { [weak self] in
            guard let self else { return }
            var errMsg = ""
            do {
                for img in images {
                    try await self.client.run(id: s.beamId, script: AgentScripts.writeFile(dir: imageDir, name: img.fileName), stdin: img.data,
                                              interactiveStdin: false, timeout: 60, onStdoutLine: nil, onStderrLine: nil, register: nil)
                }
                try await self.client.run(id: s.beamId, script: turn.script, stdin: nil, interactiveStdin: false, timeout: nil,
                    onStdoutLine: { line in Task { @MainActor in self.handleCodexLine(sessionID, line) } },
                    onStderrLine: { line in Task { @MainActor in self.appendStderr(sessionID, line) } },
                    register: { p in Task { @MainActor in self.running[sessionID] = p } })
            } catch { errMsg = self.running[sessionID] == nil ? "stopped" : error.localizedDescription }
            await MainActor.run {
                self.running[sessionID] = nil
                let wasBusy = self.busy.remove(sessionID) != nil
                self.logTurnLatency(sessionID)
                if !errMsg.isEmpty { self.noteSSHFailure(errMsg) }
                if wasBusy && !errMsg.isEmpty && errMsg != "stopped" {
                    self.appendItem(sessionID, TranscriptItem(id: self.nextSeq(sessionID), kind: .result, text: errMsg, ok: false))
                    if TshClient.isAuthError(ProcessError(command: "", status: 1, stderr: errMsg)) { Task { _ = await self.checkTsh() } }
                } else if errMsg.isEmpty && self.config.github.autoSync {
                    Task { await self.pullMemory(sessionID, quiet: true); await self.syncNow(sessionID) }
                }
            }
        }
    }

    private func handleCodexLine(_ id: String, _ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        guard t.hasPrefix("{"), let ev = StreamEvent(line: t) else { appendStderr(id, t); return }
        store.appendTranscript(id, line: t)
        var n = seq[id, default: 0]
        let (newItems, threadID) = CodexEvents.items(from: ev, seq: &n)
        seq[id] = n
        items[id, default: []] += newItems
        if let threadID { updateSession(id) { $0.codexThread = threadID } }
        notePublished(id, t)
        if ev.type == "turn.completed" {
            let usage = (ev.raw["usage"] as? [String: Any]).map(Session.usageTriple)
            updateSession(id) {
                $0.turns += 1; $0.updated = Date(); $0.needsFreshStart = false
                if let usage { $0.codexUsage[$0.codexThread] = usage }
            }
        }
    }

    // MARK: Local pi sessions

    /// Creates a new "Local" session: picks a folder on this Mac, then opens
    /// it. No beam, no SSH — turns run `pi --mode json` directly against the
    /// folder. v1 scope only (see Services/Pi.swift): no permission UI, no
    /// GitHub sync, no memory pull, no image attachments.
    func createLocalSession() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder on this Mac for pi to work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var local = Session(id: UUID().uuidString.lowercased(), beamId: "", beamName: "Local")
        local.isLocal = true
        local.localWorkDir = url.path
        do { try store.saveSession(local) } catch { fail(error); return }
        sessions.insert(local, at: 0)
        openSession(local.id)
    }

    /// Checks for and applies pi/extension updates (Sessions header button).
    /// pi has no dry-run/check-only mode — `pi update --all` IS the check: a
    /// no-op when everything's already current, so running it on demand is
    /// safe. Toasts a condensed one-line summary of what (if anything)
    /// changed instead of pi's fairly verbose, npm-flavored output.
    func updatePi() {
        guard !isMock, !updatingPi else { return }
        updatingPi = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let res = try await Shell.run(["pi", "update", "--all"], timeout: 120, check: false)
                await MainActor.run {
                    self.toast(Self.summarizePiUpdate(res.stdoutText), res.ok ? .ok : .err)
                    self.updatingPi = false
                }
            } catch {
                await MainActor.run {
                    self.toast("pi update failed: \(error.localizedDescription)", .err)
                    self.updatingPi = false
                }
            }
        }
    }

    /// Best-effort parse of `pi update --all`'s output into one line. pi
    /// always prints an "Updated packages" section header, listing changed
    /// extensions underneath it (empty when none changed) followed by pi's
    /// own status line ("pi is already up to date (vX)" or "Updated pi to
    /// vX"). Not a stable CLI contract — just enough to avoid dumping raw
    /// npm chatter into a toast.
    static func summarizePiUpdate(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func isPiStatusLine(_ s: String) -> Bool {
            s.contains("pi is already up to date") || s.lowercased().hasPrefix("updated pi")
        }
        var updatedExtensions: [String] = []
        if let headerIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Updated packages" }) {
            for line in lines[(headerIdx + 1)...] {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if isPiStatusLine(t) { break }
                updatedExtensions.append(t)
            }
        }
        let piStatus = lines.last(where: isPiStatusLine)?.trimmingCharacters(in: .whitespaces)
        guard !updatedExtensions.isEmpty else {
            return piStatus?.replacingOccurrences(of: "pi is already up to date", with: "pi and extensions are up to date")
                ?? "pi update finished"
        }
        let noun = updatedExtensions.count == 1 ? "extension" : "extensions"
        let base = piStatus ?? "pi update finished"
        return "\(base) · updated \(updatedExtensions.count) \(noun): \(updatedExtensions.joined(separator: ", "))"
    }

    /// Runs one local `pi --mode json` turn (no beam, no SSH). Images aren't
    /// forwarded yet — v1 scope.
    private func runPiTurn(sessionID: String, prompt: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        guard config.agentProxyEnabled else {
            composer = prompt
            toast("Enable \"Also proxy the \(PublishedURLs.serviceApp(for: config.agent)) Teleport app to this Mac\" in Settings for local pi sessions.", .err, seconds: 7)
            return
        }
        reconcileAgentProxy()
        busy.insert(sessionID)
        turnStart[sessionID] = Date()
        recordUserTurn(sessionID, prompt)
        // Same agent/model Settings already picks for beam turns, routed to
        // the pi provider named for it (e.g. "teleport-anthropic") instead of
        // a separate pi-specific setting.
        let provider = "teleport-" + PublishedURLs.serviceApp(for: config.agent)
        // pi requires --model whenever --provider is given; Settings' model
        // picker starts blank until touched, so fall back to its first option.
        let defaultModel = (config.agent == "codex" ? SettingsView.codexModels : SettingsView.claudeModels).first ?? ""
        let model = config.model.isEmpty ? defaultModel : config.model
        let turn = PiTurn(workDir: s.localWorkDir, sessionID: sessionID, prompt: prompt, provider: provider, model: model)
        Task { [weak self] in
            guard let self else { return }
            var errMsg = ""
            do {
                try await Shell.run(turn.argv, cwd: s.localWorkDir,
                    onStdoutLine: { line in Task { @MainActor in self.handlePiLine(sessionID, line) } },
                    onStderrLine: { line in Task { @MainActor in self.appendStderr(sessionID, line) } },
                    register: { p in Task { @MainActor in self.running[sessionID] = p } })
            } catch { errMsg = self.running[sessionID] == nil ? "stopped" : error.localizedDescription }
            await MainActor.run {
                self.running[sessionID] = nil
                _ = self.busy.remove(sessionID)
                self.logTurnLatency(sessionID)
                if !errMsg.isEmpty, errMsg != "stopped" {
                    self.appendItem(sessionID, TranscriptItem(id: self.nextSeq(sessionID), kind: .result, text: errMsg, ok: false))
                }
            }
        }
    }

    private func handlePiLine(_ id: String, _ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        guard t.hasPrefix("{"), let ev = StreamEvent(line: t) else { appendStderr(id, t); return }
        store.appendTranscript(id, line: t)
        var n = seq[id, default: 0]
        let newItems = PiEvents.items(from: ev, seq: &n)
        seq[id] = n
        items[id, default: []] += newItems
        if ev.type == "agent_settled" {
            updateSession(id) { $0.turns += 1; $0.updated = Date() }
        }
    }

    /// Ends a session's persistent process (on delete / quit).
    func endPersistent(_ sessionID: String) {
        running[sessionID]?.closeStdin()
        running[sessionID]?.terminate()
        lifeTasks[sessionID]?.cancel()
    }

    /// Called from `ingest` when a turn's result arrives in persistent mode:
    /// the process stays alive, so clear per-turn state here instead.
    private func finishPersistentTurn(_ sessionID: String) {
        busy.remove(sessionID)
        pendingPermissions[sessionID] = nil
        allowAllThisTurn.remove(sessionID)
        logTurnLatency(sessionID)
        if config.github.autoSync {
            Task { await pullMemory(sessionID, quiet: true); await syncNow(sessionID) }
        }
    }

    private func logTurnLatency(_ sessionID: String) {
        guard let start = turnStart[sessionID] else { return }
        let wall = Date().timeIntervalSince(start) * 1000
        NSLog("[beams] turn %@ wall=%.0fms mode=%@", sessionID.prefix(8).description, wall, usePersistent ? "persistent" : "per-turn")
        turnStart[sessionID] = nil
    }

    // MARK: permission prompts (Claude Code control protocol)

    private func handleControlRequest(_ id: String, _ ev: StreamEvent) {
        guard let rid = ev.raw["request_id"] as? String else { return }
        guard let req = PermissionRequest(event: ev, sessionID: id) else {
            // Only tool permissions are supported; refuse anything else politely.
            running[id]?.send(line: TurnOptions.errorResponse(requestID: rid, error: "unsupported control request"))
            return
        }
        if allowAllThisTurn.contains(id) {
            answer(req, allow: true, note: "auto")
            return
        }
        pendingPermissions[id, default: []].append(req)
        if currentID != id, let s = sessions.first(where: { $0.id == id }) {
            toast("\(s.beamName) is asking to use \(req.toolName)", .info, seconds: 6)
        }
    }

    /// Answers one request and records the decision in the transcript.
    func answer(_ req: PermissionRequest, allow: Bool, allRestOfTurn: Bool = false, note: String = "") {
        let sid = req.sessionID
        pendingPermissions[sid]?.removeAll { $0.id == req.id }
        if allRestOfTurn { allowAllThisTurn.insert(sid) }
        let line = allow ? TurnOptions.allowResponse(requestID: req.id, input: req.input)
                         : TurnOptions.denyResponse(requestID: req.id, message: "The user declined this tool use in the Beams app.")
        running[sid]?.send(line: line)
        let record: [String: Any] = ["type": "beamsui.permission", "allowed": allow, "tool": req.toolName,
                                     "summary": req.summary.isEmpty ? req.description : req.summary, "note": note]
        let json = TurnOptions.jsonLine(record)
        store.appendTranscript(sid, line: json)
        if let ev = StreamEvent(line: json) {
            var n = seq[sid, default: 0]
            items[sid, default: []] += TranscriptItem.items(from: ev, seq: &n)
            seq[sid] = n
        }
        // Anything still queued is answered the same way when "allow all" was chosen.
        if allRestOfTurn, let rest = pendingPermissions[sid], !rest.isEmpty {
            for r in rest { answer(r, allow: true, note: "auto") }
        }
    }

    var currentPermission: PermissionRequest? { currentID.flatMap { pendingPermissions[$0]?.first } }

    private func nextSeq(_ id: String) -> String { seq[id, default: 0] += 1; return "\(seq[id]!)" }

    private func appendItem(_ id: String, _ item: TranscriptItem) { items[id, default: []].append(item) }

    private func appendStderr(_ id: String, _ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        appendItem(id, TranscriptItem(id: nextSeq(id), kind: .stderr, text: t))
    }

    private func handleLine(_ id: String, _ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        guard t.hasPrefix("{"), let ev = StreamEvent(line: t) else { appendStderr(id, t); return }
        store.appendTranscript(id, line: t)
        ingest(id, ev)
    }

    private func ingest(_ id: String, _ ev: StreamEvent) {
        switch ev.type {
        case "control_request":
            handleControlRequest(id, ev)
            return
        case "control_cancel_request":
            if let rid = ev.raw["request_id"] as? String { pendingPermissions[id]?.removeAll { $0.id == rid } }
            return
        case "result":
            if usePersistent && persistentActive.contains(id) {
                // Process stays alive for the next turn; clear per-turn state here.
                finishPersistentTurn(id)
            } else {
                // stream-json input keeps Claude waiting for more; tell it we're done.
                running[id]?.closeStdin()
            }
        default:
            break
        }
        var n = seq[id, default: 0]
        let newItems = TranscriptItem.items(from: ev, seq: &n)
        seq[id] = n
        items[id, default: []] += newItems
        if ev.type == "user" { var list = items[id] ?? []; TranscriptItem.attachToolResults(from: ev, into: &list); items[id] = list }
        if ev.type == "assistant" || ev.type == "user" { notePublished(id, ev.line) }
        if ev.type == "result" {
            let cost = ev.raw["total_cost_usd"] as? Double ?? 0
            let isErr = ev.raw["is_error"] as? Bool ?? false
            updateSession(id) { s in
                s.turns += 1; s.costUsd += cost; s.updated = Date()
                s.lastError = isErr ? String((ev.raw["result"] as? String ?? "").prefix(80)) : ""
                // A result means Claude ran and created its conversation file in
                // this beam, so later turns can --resume it.
                s.needsFreshStart = false
            }
        }
    }

    // MARK: published apps

    private func notePublished(_ id: String, _ raw: String) {
        let urls = PublishedURLs.find(in: raw, proxy: config.proxy)
        guard !urls.isEmpty, let s = sessions.first(where: { $0.id == id }) else { return }
        var known = Set(s.publishedUrls.map { $0.lowercased() })
        for u in urls where !known.contains(u.lowercased()) {
            known.insert(u.lowercased())
            updateSession(id) { $0.publishedUrls.append(u) }
            let opened = !config.disableAutoOpenApps
            if opened, let url = URL(string: u) { NSWorkspace.shared.open(url) }
            toast("🌐 \(s.beamName) published an app\(opened ? " — opened in your browser" : "")", .ok, url: u, seconds: 12)
        }
    }

    /// Codex sessions from before token tracking: rebuild their usage from
    /// the transcript, off the main actor (transcripts can be large).
    private func backfillCodexUsage() {
        let todo = sessions.filter { !$0.codexThread.isEmpty && $0.codexUsage.isEmpty }.map { ($0.id, store.transcriptURL($0.id)) }
        guard !todo.isEmpty else { return }
        Task { [weak self] in
            for (id, url) in todo {
                let usage = await Task.detached(priority: .utility) { () -> [String: [Int]] in
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
                    return Session.codexUsage(fromTranscript: text.split(separator: "\n").map(String.init))
                }.value
                if !usage.isEmpty { self?.updateSession(id) { $0.codexUsage = usage } }
            }
        }
    }

    private func backfillPublished(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }), s.publishedUrls.isEmpty else { return }
        var seen = Set<String>(); var found: [String] = []
        for ln in store.readTranscript(id) {
            for u in PublishedURLs.find(in: ln, proxy: config.proxy) where !seen.contains(u.lowercased()) { seen.insert(u.lowercased()); found.append(u) }
        }
        if !found.isEmpty { updateSession(id) { $0.publishedUrls = found } }
    }

    func open(_ url: String) {
        guard url.hasPrefix("https://"), let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: memory

    /// Snapshots Claude's memory from the beam so sync can commit it and a
    /// later "continue in a beam" can put it back. No UI of its own.
    func pullMemory(_ id: String? = nil, quiet: Bool = false) async {
        guard let id = id ?? currentID, let s = sessions.first(where: { $0.id == id }) else { return }
        guard quiet ? sshBlockedReason == nil : sshAllowed() else { return }
        do {
            let res = try await client.run(id: s.beamId, script: AgentScripts.memoryPull, timeout: 120)
            if !res.stdout.isEmpty { try await store.replaceMemory(id, tarGz: res.stdout); invalidateRestorePlan(id) }
            if !quiet { toast("Pulled \(store.listMemory(id).count) memory files", .ok) }
        } catch { noteSSHFailure(error.localizedDescription); if quiet { syncLog.append("memory pull failed: \(error.localizedDescription)") } else { fail(error) } }
    }

    /// Snapshots the beam's working directory (the files the agent generated)
    /// into the session so sync can commit them.
    func pullWorkspace(_ id: String? = nil, quiet: Bool = false) async {
        guard let id = id ?? currentID, let s = sessions.first(where: { $0.id == id }) else { return }
        guard quiet ? sshBlockedReason == nil : sshAllowed() else { return }
        do {
            let res = try await client.run(id: s.beamId, script: AgentScripts.workspacePull(workDir: config.workDir), timeout: 120)
            if !res.stdout.isEmpty {
                try await store.replaceWorkspace(id, tarGz: res.stdout)
                invalidateRestorePlan(id)
                // Off the main actor: a big workspace (a whole repo) takes tens of
                // seconds to scan, and doing it here beach-balled the app.
                let dir = store.workspaceDir(id)
                let (redacted, n) = await Task.detached(priority: .utility) {
                    (Secrets.redactFiles(in: dir), FileManager.default.enumerator(atPath: dir.path)?.allObjects.count ?? 0)
                }.value
                if !redacted.isEmpty {
                    syncLog.append("Redacted credentials in \(redacted.count) file(s): \(redacted.prefix(5).joined(separator: ", "))\(redacted.count > 5 ? "…" : "")")
                }
                if !quiet { toast("Pulled \(n) workspace files", .ok) } else { syncLog.append("Pulled workspace (\(n) files) from \(config.workDir)") }
            } else if !quiet {
                toast("Working directory \(config.workDir) is empty")
            }
        } catch { noteSSHFailure(error.localizedDescription); if quiet { syncLog.append("workspace pull failed: \(error.localizedDescription)") } else { fail(error) } }
    }

    /// For short administrative scripts (restore/pull), not agent turns — so
    /// a beam that's registered but never actually becomes reachable (e.g.
    /// stuck pending on cluster capacity) fails with a clear timeout instead
    /// of hanging `continueSession`'s spinner forever.
    @discardableResult
    private func runInBeam(_ beamID: String, _ script: String, stdin: Data? = nil, timeout: TimeInterval? = 90) async throws -> ProcessResult {
        try await client.run(id: beamID, script: script, stdin: stdin, interactiveStdin: false, timeout: timeout,
                             onStdoutLine: nil, onStderrLine: nil, register: nil)
    }

    /// Saves the agent's own conversation file from the beam, which is what
    /// lets the session be resumed in a different beam later.
    private func pullConversation(_ id: String) async {
        guard let s = sessions.first(where: { $0.id == id }), s.turns > 0, sshBlockedReason == nil else { return }
        do {
            var saved = false
            if !s.codexThread.isEmpty {
                let out = try await runInBeam(s.beamId, AgentScripts.codexSessionPull(threadID: s.codexThread)).stdout
                if let nl = out.firstIndex(of: 0x0A) {
                    let rel = String(decoding: out[out.startIndex..<nl], as: UTF8.self)
                    try Data(out[out.index(after: nl)...]).write(to: store.codexSessionURL(id))
                    updateSession(id) { $0.codexSessionRel = rel }
                    saved = true
                }
            }
            let claude = try await runInBeam(s.beamId, AgentScripts.claudeSessionPull(sessionID: id)).stdout
            if !claude.isEmpty { try claude.write(to: store.claudeSessionURL(id)); saved = true }
            invalidateRestorePlan(id)
            syncLog.append(saved ? "Saved the conversation so it can be resumed in another beam"
                                 : "No conversation file found in the beam; the transcript is still saved")
        } catch { noteSSHFailure(error.localizedDescription); syncLog.append("conversation pull failed: \(error.localizedDescription)") }
    }

    // MARK: previous sessions (GitHub)

    func openFromGitHub() {
        showOpenFromGitHub = true
        Task { await loadRemoteSessions() }
    }

    func loadRemoteSessions() async {
        guard config.github.repo.contains("/") else {
            remoteError = "Pick a repository in the GitHub panel first."; remoteSessions = []; return
        }
        loadingRemote = true; remoteError = ""
        defer { loadingRemote = false }
        do {
            remoteSessions = try await GitHubSync.listRemoteSessions(
                cfg: config.github, cacheDir: store.repoCacheDir(config.github.repo),
                log: { [weak self] l in Task { @MainActor in self?.syncLog.append(l) } })
        } catch {
            remoteSessions = []
            remoteError = error.localizedDescription
        }
    }

    var filteredRemoteSessions: [RemoteSession] {
        let q = remoteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return remoteSessions }
        return remoteSessions.filter { "\($0.title) \($0.beamName) \($0.id)".lowercased().contains(q) }
    }

    func isLocal(_ id: String) -> Bool { sessions.contains { $0.id == id } }

    /// Copies a session from the repo cache into the local store and opens it.
    /// Continuing it then happens from the banner, which puts it in a beam.
    func importRemoteSession(_ r: RemoteSession) {
        if isLocal(r.id) {
            showOpenFromGitHub = false
            openSession(r.id)
            toast("That session is already in your list", .info)
            return
        }
        let src = GitHubSync.remoteSessionDir(cfg: config.github, cacheDir: store.repoCacheDir(config.github.repo), id: r.id)
        let fm = FileManager.default
        func copy(_ name: String, to dst: URL) throws {
            let from = src.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else { return }
            try? fm.removeItem(at: dst)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: dst)
        }
        do {
            try fm.createDirectory(at: store.sessionDir(r.id), withIntermediateDirectories: true)
            try copy("transcript.jsonl", to: store.transcriptURL(r.id))
            try copy("memory", to: store.memoryDir(r.id))
            try copy("workspace", to: store.workspaceDir(r.id))
            try copy("claude-session.jsonl", to: store.claudeSessionURL(r.id))
            try copy("codex-session.jsonl", to: store.codexSessionURL(r.id))
            var s = r.meta ?? Session(id: r.id, beamId: "", beamName: r.beamName)
            if r.meta == nil {
                s.title = r.title; s.turns = r.turns
                if let u = r.updated { s.created = u; s.updated = u }
            }
            s.lastSync = "https://github.com/\(config.github.repo)/tree/\(config.github.branch.isEmpty ? "main" : config.github.branch)/\(GitHubSync.prefix(config.github))/sessions/\(r.id)"
            try store.saveSession(s)
            sessions.insert(s, at: 0)
            showOpenFromGitHub = false
            openSession(s.id)
            toast("Imported \(s.title.isEmpty ? "session" : "“\(s.title)”")", .ok)
        } catch { fail(error) }
    }

    /// What continuing the current session in a new beam would bring along.
    struct RestorePlan { var files: Int; var memory: Bool; var resumable: Bool; var hasTranscript: Bool }

    /// Cached per session so rendering the banner never walks the workspace or
    /// reads the transcript. Not observed: filling it from a view body must
    /// not trigger another view update.
    @ObservationIgnored private var restorePlanCache: [String: RestorePlan] = [:]

    func invalidateRestorePlan(_ id: String) { restorePlanCache[id] = nil }

    func restorePlan(_ s: Session) -> RestorePlan {
        if let cached = restorePlanCache[s.id] { return cached }
        let plan = computeRestorePlan(s)
        restorePlanCache[s.id] = plan
        return plan
    }

    private func computeRestorePlan(_ s: Session) -> RestorePlan {
        var files = 0
        if let en = FileManager.default.enumerator(at: store.workspaceDir(s.id), includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in en where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files += 1
            }
        }
        let resumable = s.turns == 0 || (s.codexThread.isEmpty ? store.hasFile(store.claudeSessionURL(s.id))
                                                                  : store.hasFile(store.codexSessionURL(s.id)) && !s.codexSessionRel.isEmpty)
        return RestorePlan(files: files, memory: store.dirHasFiles(store.memoryDir(s.id)), resumable: resumable,
                           hasTranscript: store.hasFile(store.transcriptURL(s.id)))
    }

    /// Puts the agent's conversation back in `beamID` from the saved copy.
    /// Returns true when there was none, so the next turn starts fresh (with
    /// the previous transcript left in the beam for context).
    private func restoreConversation(_ s: Session, _ plan: RestorePlan, into beamID: String) async throws -> Bool {
        guard s.turns > 0 else { return false }
        var fresh = false
        if !s.codexThread.isEmpty {
            if plan.resumable, let data = try? Data(contentsOf: store.codexSessionURL(s.id)) {
                try await runInBeam(beamID, AgentScripts.codexSessionRestore(relPath: s.codexSessionRel), stdin: data)
            } else { fresh = true }
        } else if plan.resumable, let data = try? Data(contentsOf: store.claudeSessionURL(s.id)) {
            try await runInBeam(beamID, AgentScripts.claudeSessionRestore(sessionID: s.id, workDir: config.workDir), stdin: data)
        } else { fresh = true }
        if fresh && plan.hasTranscript {
            // No conversation file to resume: leave the agent the old transcript.
            let md = store.renderMarkdown(s, lines: store.readTranscript(s.id))
            try await runInBeam(beamID, AgentScripts.previousSessionWrite(workDir: config.workDir), stdin: Data(md.utf8))
        }
        return fresh
    }

    /// Moves a session whose beam is gone into another beam (the one picked in
    /// the banner, or a new one), then rebinds the session so the next turn
    /// continues there. A new beam for a session with a phase starts from that
    /// phase's snapshot, which already has the files, memory and (if taken
    /// after the turns) the conversation. Otherwise a new beam starts from the
    /// default phase (if set) or the cluster image, and everything is restored
    /// by hand on top.
    func continueSession(_ id: String) async {
        guard let s = sessions.first(where: { $0.id == id }), !restoring.contains(id) else { return }
        guard sshAllowed() else { return }
        restoring.insert(id)
        defer { restoring.remove(id) }
        let plan = restorePlan(s)
        do {
            var beam: Beam
            var fromPhase = false
            if let b = beams.first(where: { $0.id == continueBeamID }) {
                beam = b
            } else if !s.phase.isEmpty, let b = await beamFromPhase(s.phase, fallback: "Restoring the saved copy instead.") {
                beam = b
                fromPhase = true
            } else if !config.defaultPhase.isEmpty,
                      let b = await beamFromPhase(config.defaultPhase, fallback: "Creating a plain beam instead.") {
                // The default phase brings tools, not this session's work: still restore.
                beam = b
            } else {
                toast("Creating a beam…")
                beam = try await client.create()
                await loadBeams()
            }

            var fresh = false
            var what: [String] = []
            if fromPhase {
                what.append("phase \(s.phase)")
                if s.turns > 0 {
                    if await conversationInBeam(s, beam.id) {
                        what.append("conversation")
                    } else {
                        // Snapshot predates the conversation: use the saved copy.
                        fresh = try await restoreConversation(s, plan, into: beam.id)
                        what.append(fresh ? "previous transcript" : "saved conversation")
                    }
                }
            } else {
                if plan.files > 0 {
                    let (data, _) = try await store.tarGz(directory: store.workspaceDir(id))
                    try await runInBeam(beam.id, AgentScripts.workspaceRestore(workDir: config.workDir), stdin: data)
                    what.append("\(plan.files) files")
                }
                if plan.memory {
                    let (data, _) = try await store.tarGz(directory: store.memoryDir(id))
                    try await runInBeam(beam.id, AgentScripts.memoryRestore, stdin: data)
                    what.append("memory")
                }
                fresh = try await restoreConversation(s, plan, into: beam.id)
                if s.turns > 0 { what.append(fresh ? "previous transcript" : "conversation") }
            }

            updateSession(id) {
                $0.beamId = beam.id; $0.beamName = beam.name
                $0.needsFreshStart = fresh
                if fresh { $0.codexThread = "" }
            }
            invalidateRestorePlan(id)
            endPersistent(id)
            toast("Continuing in \(beam.name)\(what.isEmpty ? "" : " with " + what.joined(separator: ", "))", .ok, seconds: 7)
            await probe(beam.id)
        } catch {
            // Stops at the first failure; a refused login is recorded so the
            // next click explains instead of connecting again.
            noteSSHFailure(error.localizedDescription)
            fail(error)
        }
    }

    // MARK: github

    func refreshGitHub() async {
        gh = await GitHubSync.status()
        ghChecked = true
        if gh.loggedIn && repos.isEmpty { await loadRepos() }
    }

    func githubLogin() {
        guard !ghLoggingIn else { return }
        ghLoggingIn = true; ghDeviceCode = "····-····"
        syncLog.append("Starting GitHub sign-in (browser device flow)…")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await GitHubSync.login { line in
                    Task { @MainActor in
                        self.syncLog.append(line)
                        if let r = line.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression) { self.ghDeviceCode = String(line[r]) }
                    }
                }
                await self.refreshGitHub()
                self.toast("Signed in to GitHub as \(self.gh.user)", .ok)
            } catch { self.fail(error) }
            self.ghLoggingIn = false; self.ghDeviceCode = nil
        }
    }

    func githubLogout() {
        ask("Sign the gh CLI out of github.com?", "Other tools using gh will be signed out too.", ok: "Sign out", destructive: true) { [self] in
            Task { do { try await GitHubSync.logout() } catch { fail(error) }; repos = []; await refreshGitHub() }
        }
    }

    func loadRepos(force: Bool = false) async {
        guard force || repos.isEmpty, !loadingRepos else { return }
        loadingRepos = true
        do { repos = try await GitHubSync.listRepos() } catch { fail(error) }
        loadingRepos = false
    }

    func loadBranches(force: Bool = false) async {
        let repo = config.github.repo.trimmingCharacters(in: .whitespaces)
        guard repo.contains("/"), force || branchesFor != repo else { return }
        do {
            branches = try await GitHubSync.listBranches(repo)
            branchesFor = repo
            if branches.isEmpty {
                newBranch = true
                if newBranchName.isEmpty { newBranchName = config.github.branch.isEmpty ? "main" : config.github.branch }
                syncLog.append("\(repo) has no branches yet — the first sync will create one.")
            } else if branches.contains(config.github.branch) {
                newBranch = false
            } else if config.github.branch.isEmpty {
                config.github.branch = branches.contains("main") ? "main" : branches[0]; newBranch = false; saveConfig()
            } else {
                newBranch = true; newBranchName = config.github.branch
            }
        } catch { syncLog.append("branches: \(error.localizedDescription)"); branches = []; branchesFor = repo }
    }

    private func syncLogBranchState() {
        if newBranch, !newBranchName.isEmpty, !branches.isEmpty {
            syncLog.append("Branch \(newBranchName) doesn't exist yet — it will be created from the repo's default branch.")
        }
    }

    /// Applies the branch picker to config. Returns false when invalid.
    @discardableResult
    func commitBranchChoice() -> Bool {
        if newBranch {
            let b = newBranchName.trimmingCharacters(in: .whitespaces)
            if b.isEmpty { toast("Enter a name for the new branch.", .err); return false }
            let ok = b.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil && !b.hasPrefix("-") && !b.contains("..") && !b.hasSuffix("/")
            if !ok { toast("\"\(b)\" isn't a valid branch name.", .err); return false }
            config.github.branch = b
        }
        if config.github.prefix.trimmingCharacters(in: .whitespaces).isEmpty { config.github.prefix = "beams" }
        saveConfig()
        return true
    }

    func createRepo() {
        guard commitBranchChoice() else { return }
        let repo = config.github.repo.trimmingCharacters(in: .whitespaces)
        guard repo.contains("/") else { toast("Set a repository (owner/name) first", .err); return }
        ask("Create private repository \(repo) on GitHub?", "It will be created under your gh login.", ok: "Create repo") { [self] in
            Task {
                do { let url = try await GitHubSync.createRepo(repo, isPrivate: true); toast("Created \(repo)", .ok); syncLog.append("created \(url)"); await loadRepos(force: true) }
                catch { fail(error) }
            }
        }
    }

    func syncNow(_ id: String? = nil) async {
        guard let id = id ?? currentID, let s = sessions.first(where: { $0.id == id }) else {
            toast("Open a session first — sync commits that session's transcript, memory, and generated files.", .err, seconds: 6); return
        }
        guard config.github.repo.contains("/") else { toast("Pick a repository (owner/name) first.", .err); return }
        guard commitBranchChoice() else { return }
        syncing = true
        syncLog.append("— sync started —")
        defer { syncing = false }
        do {
            if let reason = sshBlockedReason {
                syncLog.append("Not connecting to the beam (\(reason.prefix(60))…); syncing the saved copy")
            } else if beamGone(s) {
                syncLog.append("Beam \(s.beamName) is gone; syncing the saved copy")
            } else {
                if store.listMemory(id).isEmpty { syncLog.append("Pulling memory from beam first"); await pullMemory(id, quiet: true) }
                // Always refresh the generated files so the commit reflects the beam.
                syncLog.append("Pulling generated files from \(config.workDir)")
                await pullWorkspace(id, quiet: true)
                await pullConversation(id)
            }
            let current = sessions.first(where: { $0.id == id }) ?? s
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let md = store.renderMarkdown(current, lines: store.readTranscript(id))
            let res = try await GitHubSync.sync(cfg: config.github, cacheDir: store.repoCacheDir(config.github.repo), session: current, transcriptMD: md,
                                                transcriptJSONL: store.transcriptURL(id), memoryDir: store.memoryDir(id),
                                                workspaceDir: store.workspaceDir(id),
                                                extras: .init(claudeSession: store.claudeSessionURL(id),
                                                              codexSession: store.codexSessionURL(id),
                                                              meta: try? enc.encode(current)),
                                                log: { [weak self] l in Task { @MainActor in self?.syncLog.append(l) } })
            if res.committed {
                updateSession(id) { $0.lastSync = res.url }
                syncLog.append("committed \(res.sha.prefix(8)) → \(res.url)")
                toast("Pushed \(res.sha.prefix(8))", .ok, url: res.url)
                newBranch = false; branchesFor = ""; await loadBranches(force: true)
            } else { toast(res.message) }
        } catch { syncLog.append("error: \(error.localizedDescription)"); fail(error) }
    }

    // MARK: teleport login

    @discardableResult
    func checkTsh() async -> Bool {
        if isMock { return true }
        let previousCert = tsh.validUntil
        let previousProfiles = tsh.profileExpiry
        tsh = await tshClient.status()
        if tsh.profileExpiry != previousProfiles { mcpLoginsChanged(from: previousProfiles) }
        tshChecked = true
        if tsh.loggedIn {
            tshPending = nil
            // Deterministically re-establish any proxy/tunnel Settings wants
            // running, rather than relying only on mcpLoginsChanged's delta
            // detection above (which needs a supervisor to already exist).
            // Both calls are cheap no-ops when nothing needs to change.
            reconcileAgentProxy()
            reconcileMCP()
        }
        // A new certificate (fresh login) or one that grants the login clears
        // an earlier "access denied".
        if tsh.validUntil != previousCert || (tsh.logins?.contains(beamLogin) ?? false) { sshDenied = nil }
        return tsh.loggedIn
    }

    @ObservationIgnored private var tshRecheckTask: Task<Void, Never>?

    /// Re-checks tsh and reloads beams shortly after Settings stop changing.
    func scheduleTshRecheck() {
        tshRecheckTask?.cancel()
        tshRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            if await self.checkTsh() { await self.loadBeams() }
        }
    }

    // MARK: SSH access to beams

    /// SSH login used inside beams: Settings' "Beam login", else the cluster default.
    var beamLogin: String { config.login.isEmpty ? "beams" : config.login }

    /// Set when a beam refused an SSH login (see `noteSSHFailure`).
    var sshDenied: String?

    /// Non-nil when this identity can't open SSH sessions into beams. The app
    /// then explains it instead of connecting: every attempt is a failed login
    /// in the cluster's audit log (one of them logged in with SSO and got a flood).
    var sshBlockedReason: String? {
        guard !isMock, tsh.loggedIn else { return nil }
        if let logins = tsh.logins, !logins.contains(beamLogin) {
            let who = tsh.user.isEmpty ? "This identity" : tsh.user
            let roles = tsh.roles.isEmpty ? "" : " Its roles are \(tsh.roles.joined(separator: ", "))."
            return "\(who) has no “\(beamLogin)” SSH login, so beams can be listed and created but nothing can run in them.\(roles) "
                + "The beam-user role grants it. If it was just added to your SSO mapping, log in again: roles are fixed at login."
        }
        return sshDenied
    }

    /// Gate for anything that runs a command in a beam.
    func sshAllowed() -> Bool {
        guard sshBlockedReason != nil else { return true }
        toast("Can't run commands in beams with this Teleport login. See the banner above.", .err, seconds: 6)
        return false
    }

    /// Records a refused SSH login so later actions stop instead of retrying.
    func noteSSHFailure(_ message: String) {
        guard TshClient.isSSHLoginDenied(message) else { return }
        let who = tsh.user.isEmpty ? "this identity" : tsh.user
        sshDenied = "The beam refused the “\(beamLogin)” SSH login for \(who). "
            + "Your roles need to grant that login (the beam-user role does). If they were just changed, log in again."
    }

    var tshLoginCommand: String { tshClient.loginCommand(user: tshUser.trimmingCharacters(in: .whitespaces)) }

    private func rememberUser() {
        let u = tshUser.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty, u != config.teleportUser { config.teleportUser = u; saveConfig() }
    }

    var terminalAppName: String {
        switch config.terminalApp.lowercased() {
        case "iterm", "iterm2": return "iTerm"
        case "terminal": return "Terminal"
        default: break
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installed = ["/Applications/iTerm.app", "\(home)/Applications/iTerm.app"].contains { FileManager.default.fileExists(atPath: $0) }
        return installed ? "iTerm" : "Terminal"
    }

    func tshLogin() {
        guard !tshLoggingIn else { return }
        let user = tshUser.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { toast("Enter the Teleport username to log in as.", .err); return }
        rememberUser()
        tshLoggingIn = true
        tshPending = "Starting: $ \(tshLoginCommand)\nSSO clusters open your browser; password clusters open \(terminalAppName)."
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.tshClient.runLogin(user: user) { l in Task { @MainActor in self.tshPending = l } }
                if await self.checkTsh() { self.toast("Logged in to \(self.tsh.cluster) as \(self.tsh.user)", .ok); await self.loadBeams() }
            } catch TshError.needsTerminal {
                do {
                    try self.openTerminalLogin()
                    self.tshPending = "This cluster uses password login, so \(self.terminalAppName) was opened with:\n$ \(self.tshLoginCommand)\nFinish there; this screen updates by itself."
                    self.startTshPoll()
                } catch { self.fail(error); self.tshPending = "Run this in a terminal, then click ⟳:\n$ \(self.tshLoginCommand)" }
            } catch { self.fail(error); self.tshPending = nil; _ = await self.checkTsh() }
            self.tshLoggingIn = false
        }
    }

    func openTerminalLogin() throws {
        rememberUser()
        let cmd = tshLoginCommand
        let quoted = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if terminalAppName == "iTerm" {
            script = """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(quoted)"
                end tell
            end tell
            """
        } else {
            script = "tell application \"Terminal\"\n\tactivate\n\tdo script \"\(quoted)\"\nend tell"
        }
        var err: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { throw SyncError(message: "could not build AppleScript") }
        apple.executeAndReturnError(&err)
        if let err { throw SyncError(message: "open \(terminalAppName): \(err[NSAppleScript.errorMessage] ?? err)") }
    }

    func openTerminalAndWait() {
        do {
            try openTerminalLogin()
            tshPending = "Finish the login in \(terminalAppName).\n$ \(tshLoginCommand)"
            startTshPoll()
        } catch { fail(error) }
    }

    private func startTshPoll() {
        tshPollTask?.cancel()
        tshPollTask = Task { [weak self] in
            for n in 0..<90 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                if await self.checkTsh() {
                    self.toast("Logged in to \(self.tsh.cluster) as \(self.tsh.user)", .ok)
                    await self.loadBeams()
                    return
                }
                if self.tshPending != nil, n > 0 {
                    self.tshPending = "Finish the login in \(self.terminalAppName), then come back. Checking every 3s…\n$ \(self.tshLoginCommand)"
                }
            }
            self?.tshPending = nil
        }
    }

    func recheckTsh() async {
        if await checkTsh() { toast("Logged in", .ok); await loadBeams() }
    }
}
