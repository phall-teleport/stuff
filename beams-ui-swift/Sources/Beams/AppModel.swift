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

enum InspectorTab: String, CaseIterable { case memory = "Memory", github = "GitHub" }

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
    var restoring: Set<String> = []

    // memory
    var memory: [MemoryFile] = []
    var memorySelected: MemoryFile? = nil
    var memoryContent = ""

    // ui
    var showInspector = true
    var inspectorTab: InspectorTab = .memory
    var toasts: [Toast] = []
    var confirm: ConfirmRequest? = nil

    init() throws {
        Shell.augmentPath()
        let st = try Store()
        let cfg = st.loadConfig()
        let mock = ProcessInfo.processInfo.environment["BEAMSUI_MOCK"] == "1"
        store = st
        config = cfg
        isMock = mock
        client = mock ? MockClient() : TshClient(bin: cfg.tshBin, proxy: cfg.proxy, login: cfg.login)
        tshUser = cfg.teleportUser.isEmpty ? (ProcessInfo.processInfo.environment["USER"] ?? "") : cfg.teleportUser
    }

    var current: Session? { sessions.first { $0.id == currentID } }
    var currentItems: [TranscriptItem] { currentID.flatMap { items[$0] } ?? [] }
    var currentBusy: Bool { currentID.map { busy.contains($0) } ?? false }
    var backendLabel: String { isMock ? "mock" : (config.proxy.isEmpty ? "tsh" : config.proxy) }

    private var tshClient: TshClient { TshClient(bin: config.tshBin, proxy: config.proxy, login: config.login) }

    // MARK: boot

    func boot() async {
        sessions = store.listSessions()
        if isMock { tsh = TshStatus(tshFound: true, loggedIn: true, proxy: "mock", user: "mock", cluster: "mock", message: "Mock backend"); tshChecked = true }
        await refreshGitHub()
        if await checkTsh() { await loadBeams() } else { beamsNote = "Log in to Teleport to see your sandboxes." }
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
            beamsNote = beams.isEmpty ? "No sandboxes. Click ＋ to create one." : ""
            if continueBeamID.isEmpty || !beams.contains(where: { $0.id == continueBeamID }) { continueBeamID = beams.first?.id ?? "" }
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

    func createBeam() async {
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
                do { try await client.delete(id: b.id); toast("Deleted \(b.name)", .ok); await loadBeams() } catch { fail(error) }
            }
        }
    }

    // MARK: sessions

    func startSession(on beam: Beam) async {
        // Reuse an untouched session on this beam instead of piling up empties.
        if let empty = sessions.first(where: { $0.beamId == beam.id && $0.turns == 0 && $0.title.isEmpty && !busy.contains($0.id) }) {
            openSession(empty.id)
        } else {
            let s = Session(id: UUID().uuidString.lowercased(), beamId: beam.id, beamName: beam.name)
            do { try store.saveSession(s) } catch { fail(error); return }
            sessions.insert(s, at: 0)
            openSession(s.id)
        }
        await probe(beam.id)
    }

    func openSession(_ id: String) {
        currentID = id
        if items[id] == nil {
            var seqN = 0
            var list: [TranscriptItem] = []
            for ln in store.readTranscript(id) {
                guard let ev = StreamEvent(line: ln) else { continue }
                if CodexEvents.isCodexLine(ev) {
                    list += CodexEvents.items(from: ev, seq: &seqN).items
                } else {
                    list += TranscriptItem.items(from: ev, seq: &seqN)
                    TranscriptItem.attachToolResults(from: ev, into: &list)
                }
            }
            items[id] = list
            seq[id] = seqN
            backfillPublished(id)
        }
        memory = store.listMemory(id)
        memorySelected = nil; memoryContent = ""
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
        do {
            var lines: [String] = []
            try await client.run(id: beamID, script: AgentScripts.probe, stdin: nil, interactiveStdin: false, onStdoutLine: { lines.append($0) }, onStderrLine: nil, register: nil)
            if lines.count >= 2 { probeHint = "\(lines[0])@\(lines[1]) · \(lines.count > 2 ? lines[2] : "")" }
        } catch { probeHint = "probe failed: \(error.localizedDescription)" }
    }

    private func updateSession(_ id: String, _ f: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        f(&sessions[i])
        try? store.saveSession(sessions[i])
    }

    // MARK: turns

    func send() {
        let prompt = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = current, !prompt.isEmpty, !busy.contains(s.id) else { return }
        composer = ""
        Task { await runTurn(sessionID: s.id, prompt: prompt) }
    }

    /// Persistent-session mode: keep one Claude process alive per session and
    /// feed each turn to it. Env override `BEAMSUI_PERSISTENT=1` forces it on.
    var usePersistent: Bool { config.persistentSession || ProcessInfo.processInfo.environment["BEAMSUI_PERSISTENT"] == "1" }

    private func recordUserTurn(_ sessionID: String, _ prompt: String) {
        if var s = sessions.first(where: { $0.id == sessionID }) {
            if s.title.isEmpty { s.title = String(prompt.split(separator: "\n").first.map(String.init)?.prefix(80) ?? "") }
            s.updated = Date()
            updateSession(sessionID) { $0 = s }
        }
        let userLine = ["type": "beamsui.user", "text": prompt, "ts": RFC3339.string(Date())]
        if let d = try? JSONSerialization.data(withJSONObject: userLine), let ln = String(data: d, encoding: .utf8) {
            store.appendTranscript(sessionID, line: ln)
            if let ev = StreamEvent(line: ln) { ingest(sessionID, ev) }
        }
    }

    /// A session's beam is gone once the beam list has loaded and doesn't
    /// contain it (beams expire; imported sessions start without one).
    func beamGone(_ s: Session) -> Bool {
        beamsLoaded && !beams.contains(where: { $0.id == s.beamId })
    }

    /// First prompt after moving a session to a beam without its conversation
    /// file: point the agent at the restored transcript so it has context.
    private func promptToSend(_ s: Session, _ prompt: String) -> String {
        guard s.needsFreshStart else { return prompt }
        return "(Context: this continues an earlier session that ran in a different sandbox. "
            + "Its project files and memory were restored here, and the earlier conversation is in "
            + ".beams/previous-session.md. Read it first if you need the background.)\n\n" + prompt
    }

    private func runTurn(sessionID: String, prompt: String) async {
        if let s = sessions.first(where: { $0.id == sessionID }), beamGone(s) {
            composer = prompt   // give the prompt back
            toast("The beam \(s.beamName.isEmpty ? "for this session" : s.beamName) is gone. Continue the session in a beam from the banner above.", .err, seconds: 7)
            return
        }
        if config.agent == "codex" { runCodexTurn(sessionID: sessionID, prompt: prompt); return }
        if usePersistent { runTurnPersistent(sessionID: sessionID, prompt: prompt); return }
        guard var s = sessions.first(where: { $0.id == sessionID }) else { return }
        busy.insert(sessionID)
        if s.title.isEmpty { s.title = String(prompt.split(separator: "\n").first.map(String.init)?.prefix(80) ?? "") }
        s.updated = Date()
        updateSession(sessionID) { $0 = s }
        turnStart[sessionID] = Date()

        let userLine = ["type": "beamsui.user", "text": prompt, "ts": RFC3339.string(Date())]
        if let d = try? JSONSerialization.data(withJSONObject: userLine), let ln = String(data: d, encoding: .utf8) {
            store.appendTranscript(sessionID, line: ln)
            if let ev = StreamEvent(line: ln) { ingest(sessionID, ev) }
        }

        let opts = TurnOptions(sessionID: sessionID, resume: s.turns > 0 && !s.needsFreshStart, workDir: config.workDir, prompt: prompt,
                               permissionMode: config.permissionMode, model: config.model)
        let firstMessage = TurnOptions.userMessage(promptToSend(s, prompt))
        var errMsg = ""
        do {
            // The prompt travels as the first stream-json message on stdin; the
            // same pipe carries our answers to permission requests.
            try await client.run(id: s.beamId, script: opts.script, stdin: nil, interactiveStdin: true,
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
    private func runTurnPersistent(sessionID: String, prompt: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        busy.insert(sessionID)
        turnStart[sessionID] = Date()
        recordUserTurn(sessionID, prompt)
        let msg = TurnOptions.userMessage(promptToSend(s, prompt))

        // Process already alive → just send the next turn.
        if persistentActive.contains(sessionID), let p = running[sessionID] {
            p.send(line: msg)
            return
        }

        // Start the session process; it stays up for later turns.
        let opts = TurnOptions(sessionID: sessionID, resume: s.turns > 0 && !s.needsFreshStart, workDir: config.workDir,
                               prompt: "", permissionMode: config.permissionMode, model: config.model)
        persistentActive.insert(sessionID)
        lifeTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            var errMsg = ""
            do {
                try await self.client.run(id: s.beamId, script: opts.script, stdin: nil, interactiveStdin: true,
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
    private func runCodexTurn(sessionID: String, prompt: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        busy.insert(sessionID)
        turnStart[sessionID] = Date()
        recordUserTurn(sessionID, prompt)
        let turn = CodexTurn(workDir: config.workDir, model: config.model, prompt: promptToSend(s, prompt),
                             resumeThread: s.needsFreshStart ? "" : s.codexThread)
        Task { [weak self] in
            guard let self else { return }
            var errMsg = ""
            do {
                try await self.client.run(id: s.beamId, script: turn.script, stdin: nil, interactiveStdin: false,
                    onStdoutLine: { line in Task { @MainActor in self.handleCodexLine(sessionID, line) } },
                    onStderrLine: { line in Task { @MainActor in self.appendStderr(sessionID, line) } },
                    register: { p in Task { @MainActor in self.running[sessionID] = p } })
            } catch { errMsg = self.running[sessionID] == nil ? "stopped" : error.localizedDescription }
            await MainActor.run {
                self.running[sessionID] = nil
                let wasBusy = self.busy.remove(sessionID) != nil
                self.logTurnLatency(sessionID)
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
        if ev.type == "turn.completed" { updateSession(id) { $0.turns += 1; $0.updated = Date(); $0.needsFreshStart = false } }
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

    func pullMemory(_ id: String? = nil, quiet: Bool = false) async {
        guard let id = id ?? currentID, let s = sessions.first(where: { $0.id == id }) else { return }
        do {
            let res = try await client.run(id: s.beamId, script: AgentScripts.memoryPull)
            if !res.stdout.isEmpty { try await store.replaceMemory(id, tarGz: res.stdout) }
            if currentID == id { memory = store.listMemory(id) }
            if !quiet { toast("Pulled \(store.listMemory(id).count) memory files", .ok) }
        } catch { if quiet { syncLog.append("memory pull failed: \(error.localizedDescription)") } else { fail(error) } }
    }

    func selectMemory(_ f: MemoryFile) {
        guard let id = currentID else { return }
        memorySelected = f
        memoryContent = store.readMemoryFile(id, f.path)
    }

    /// Snapshots the beam's working directory (the files the agent generated)
    /// into the session so sync can commit them.
    func pullWorkspace(_ id: String? = nil, quiet: Bool = false) async {
        guard let id = id ?? currentID, let s = sessions.first(where: { $0.id == id }) else { return }
        do {
            let res = try await client.run(id: s.beamId, script: AgentScripts.workspacePull(workDir: config.workDir))
            if !res.stdout.isEmpty {
                try await store.replaceWorkspace(id, tarGz: res.stdout)
                let n = FileManager.default.enumerator(atPath: store.workspaceDir(id).path)?.allObjects.count ?? 0
                if !quiet { toast("Pulled \(n) workspace files", .ok) } else { syncLog.append("Pulled workspace (\(n) files) from \(config.workDir)") }
            } else if !quiet {
                toast("Working directory \(config.workDir) is empty")
            }
        } catch { if quiet { syncLog.append("workspace pull failed: \(error.localizedDescription)") } else { fail(error) } }
    }

    func restoreMemory() async {
        guard let s = current else { return }
        do {
            guard let dir = try await GitHubSync.restoreMemoryDir(cfg: config.github, cacheDir: store.repoCacheDir(config.github.repo), log: { [weak self] l in Task { @MainActor in self?.syncLog.append(l) } }) else {
                toast("No memory snapshot in the repo yet"); return
            }
            let (data, count) = try await store.tarGz(directory: dir)
            guard count > 0 else { toast("Memory snapshot is empty"); return }
            try await client.run(id: s.beamId, script: AgentScripts.memoryRestore, stdin: data, interactiveStdin: false, onStdoutLine: nil, onStderrLine: nil, register: nil)
            toast("Restored \(count) memory files into \(s.beamName)", .ok)
        } catch { fail(error) }
    }

    @discardableResult
    private func runInBeam(_ beamID: String, _ script: String, stdin: Data? = nil) async throws -> ProcessResult {
        try await client.run(id: beamID, script: script, stdin: stdin, interactiveStdin: false,
                             onStdoutLine: nil, onStderrLine: nil, register: nil)
    }

    /// Saves the agent's own conversation file from the beam, which is what
    /// lets the session be resumed in a different beam later.
    private func pullConversation(_ id: String) async {
        guard let s = sessions.first(where: { $0.id == id }), s.turns > 0 else { return }
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
            syncLog.append(saved ? "Saved the conversation so it can be resumed in another beam"
                                 : "No conversation file found in the beam; the transcript is still saved")
        } catch { syncLog.append("conversation pull failed: \(error.localizedDescription)") }
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

    func restorePlan(_ s: Session) -> RestorePlan {
        var files = 0
        if let en = FileManager.default.enumerator(at: store.workspaceDir(s.id), includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in en where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files += 1
            }
        }
        let resumable = s.turns == 0 || (s.codexThread.isEmpty ? store.hasFile(store.claudeSessionURL(s.id))
                                                                  : store.hasFile(store.codexSessionURL(s.id)) && !s.codexSessionRel.isEmpty)
        return RestorePlan(files: files, memory: store.dirHasFiles(store.memoryDir(s.id)), resumable: resumable,
                           hasTranscript: !store.readTranscript(s.id).isEmpty)
    }

    /// Moves a session whose beam is gone into another beam (the one picked in
    /// the banner, or a new one): restores its files, memory and the agent's
    /// conversation, then rebinds the session so the next turn continues there.
    func continueSession(_ id: String) async {
        guard let s = sessions.first(where: { $0.id == id }), !restoring.contains(id) else { return }
        restoring.insert(id)
        defer { restoring.remove(id) }
        let plan = restorePlan(s)
        do {
            let beam: Beam
            if let b = beams.first(where: { $0.id == continueBeamID }) {
                beam = b
            } else {
                toast("Creating a beam…")
                beam = try await client.create()
                await loadBeams()
            }
            if plan.files > 0 {
                let (data, _) = try await store.tarGz(directory: store.workspaceDir(id))
                try await runInBeam(beam.id, AgentScripts.workspaceRestore(workDir: config.workDir), stdin: data)
            }
            if plan.memory {
                let (data, _) = try await store.tarGz(directory: store.memoryDir(id))
                try await runInBeam(beam.id, AgentScripts.memoryRestore, stdin: data)
            }
            var fresh = false
            if s.turns > 0 {
                if !s.codexThread.isEmpty {
                    if plan.resumable, let data = try? Data(contentsOf: store.codexSessionURL(id)) {
                        try await runInBeam(beam.id, AgentScripts.codexSessionRestore(relPath: s.codexSessionRel), stdin: data)
                    } else { fresh = true }
                } else if plan.resumable, let data = try? Data(contentsOf: store.claudeSessionURL(id)) {
                    try await runInBeam(beam.id, AgentScripts.claudeSessionRestore(sessionID: id, workDir: config.workDir), stdin: data)
                } else { fresh = true }
            }
            if fresh && plan.hasTranscript {
                // No conversation file to resume: leave the agent the old transcript.
                let md = store.renderMarkdown(s, lines: store.readTranscript(id))
                try await runInBeam(beam.id, AgentScripts.previousSessionWrite(workDir: config.workDir), stdin: Data(md.utf8))
            }
            updateSession(id) {
                $0.beamId = beam.id; $0.beamName = beam.name
                $0.needsFreshStart = fresh
                if fresh { $0.codexThread = "" }
            }
            endPersistent(id)
            let what = [plan.files > 0 ? "\(plan.files) files" : nil, plan.memory ? "memory" : nil,
                        s.turns > 0 ? (fresh ? "previous transcript" : "conversation") : nil].compactMap { $0 }
            toast("Continuing in \(beam.name)\(what.isEmpty ? "" : " with " + what.joined(separator: ", "))", .ok, seconds: 7)
            await probe(beam.id)
        } catch { fail(error) }
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
        Task {
            do {
                try await GitHubSync.login { [weak self] line in
                    Task { @MainActor in
                        self?.syncLog.append(line)
                        if let r = line.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression) { self?.ghDeviceCode = String(line[r]) }
                    }
                }
                await refreshGitHub()
                toast("Signed in to GitHub as \(gh.user)", .ok)
            } catch { fail(error) }
            ghLoggingIn = false; ghDeviceCode = nil
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
            if beamGone(s) {
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
        tsh = await tshClient.status()
        tshChecked = true
        if tsh.loggedIn { tshPending = nil }
        return tsh.loggedIn
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
        Task {
            do {
                try await tshClient.runLogin(user: user) { [weak self] l in Task { @MainActor in self?.tshPending = l } }
                if await checkTsh() { toast("Logged in to \(tsh.cluster) as \(tsh.user)", .ok); await loadBeams() }
            } catch TshError.needsTerminal {
                do {
                    try openTerminalLogin()
                    tshPending = "This cluster uses password login, so \(terminalAppName) was opened with:\n$ \(tshLoginCommand)\nFinish there; this screen updates by itself."
                    startTshPoll()
                } catch { fail(error); tshPending = "Run this in a terminal, then click ⟳:\n$ \(tshLoginCommand)" }
            } catch { fail(error); tshPending = nil; _ = await checkTsh() }
            tshLoggingIn = false
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
