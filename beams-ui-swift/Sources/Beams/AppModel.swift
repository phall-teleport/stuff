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
            beamsNote = beams.isEmpty ? "No sandboxes. Click ＋ to create one." : ""
        } catch {
            beams = []
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
                list += TranscriptItem.items(from: ev, seq: &seqN)
                TranscriptItem.attachToolResults(from: ev, into: &list)
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

    private func runTurn(sessionID: String, prompt: String) async {
        guard var s = sessions.first(where: { $0.id == sessionID }) else { return }
        busy.insert(sessionID)
        if s.title.isEmpty { s.title = String(prompt.split(separator: "\n").first.map(String.init)?.prefix(80) ?? "") }
        s.updated = Date()
        updateSession(sessionID) { $0 = s }

        let userLine = ["type": "beamsui.user", "text": prompt, "ts": RFC3339.string(Date())]
        if let d = try? JSONSerialization.data(withJSONObject: userLine), let ln = String(data: d, encoding: .utf8) {
            store.appendTranscript(sessionID, line: ln)
            if let ev = StreamEvent(line: ln) { ingest(sessionID, ev) }
        }

        let opts = TurnOptions(sessionID: sessionID, resume: s.turns > 0, workDir: config.workDir, prompt: prompt,
                               permissionMode: config.permissionMode, model: config.model)
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
                                         p.send(line: TurnOptions.userMessage(prompt))
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
        p.terminate()
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
            // stream-json input keeps Claude waiting for more; tell it we're done.
            running[id]?.closeStdin()
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
            toast("Open a session first — sync commits that session's transcript and memory.", .err, seconds: 6); return
        }
        guard config.github.repo.contains("/") else { toast("Pick a repository (owner/name) first.", .err); return }
        guard commitBranchChoice() else { return }
        syncing = true
        syncLog.append("— sync started —")
        defer { syncing = false }
        do {
            if store.listMemory(id).isEmpty { syncLog.append("Pulling memory from beam first"); await pullMemory(id, quiet: true) }
            let md = store.renderMarkdown(s, lines: store.readTranscript(id))
            let res = try await GitHubSync.sync(cfg: config.github, cacheDir: store.repoCacheDir(config.github.repo), session: s, transcriptMD: md,
                                                transcriptJSONL: store.transcriptURL(id), memoryDir: store.memoryDir(id),
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
