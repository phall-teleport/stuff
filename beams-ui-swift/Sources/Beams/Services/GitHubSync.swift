import Foundation

struct GitHubAuthStatus {
    var installed = false
    var loggedIn = false
    var user = ""
    var detail = ""
}

struct GitHubRepo: Identifiable, Hashable {
    var fullName: String
    var isPrivate: Bool
    var pushedAt: String
    var id: String { fullName }
}

struct SyncResult {
    var committed = false
    var sha = ""
    var url = ""
    var branch = ""
    var message = ""
}

struct SyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Commits a session's transcript and pulled memory into a GitHub repo using
/// the local git and gh CLIs (inheriting the user's gh login), and restores
/// memory from that repo. All git traffic is HTTPS with gh as the credential
/// helper, so private repos work without SSH keys.
enum GitHubSync {
    private static let gitCred = ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"]

    @discardableResult
    private static func git(_ dir: String?, _ args: [String], timeout: TimeInterval = 120) async throws -> String {
        // GIT_TERMINAL_PROMPT=0 (set in Shell.environment) makes auth failures
        // error instead of prompting; the timeout guards against a blocked
        // fetch/push (network, or a credential helper that won't return).
        try await Shell.run(["git"] + gitCred + args, cwd: dir, timeout: timeout).stdoutText
    }

    // MARK: auth

    static func status() async -> GitHubAuthStatus {
        guard Shell.which("gh") != nil else {
            return GitHubAuthStatus(detail: "GitHub CLI (gh) not found. Install with: brew install gh")
        }
        let res = try? await Shell.run(["gh", "auth", "status", "--hostname", "github.com"], timeout: 30, check: false)
        let text = (res?.stdoutText ?? "") + (res?.stderr ?? "")
        var st = GitHubAuthStatus(installed: true, detail: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard res?.ok == true else { return st }
        st.loggedIn = true
        for ln in text.split(separator: "\n") where ln.contains("Logged in") {
            if let r = ln.range(of: "account ") {
                st.user = String(ln[r.upperBound...].split(separator: " ").first ?? ""); break
            }
        }
        return st
    }

    /// Browser device flow; the one-time code and URL arrive via `log`.
    static func login(log: @escaping (String) -> Void) async throws {
        guard Shell.which("gh") != nil else { throw SyncError(message: "GitHub CLI (gh) not found. Install with: brew install gh") }
        let handle: (String) -> Void = { ln in let t = ln.trimmingCharacters(in: .whitespaces); if !t.isEmpty { log(t) } }
        try await Shell.run(["gh", "auth", "login", "--hostname", "github.com", "--web", "--git-protocol", "https", "--scopes", "repo,read:org"],
                            stdin: Data("\n".utf8), extraEnv: ["GH_PROMPT_DISABLED": "1"], onStdoutLine: handle, onStderrLine: handle)
    }

    static func logout() async throws {
        try await Shell.run(["gh", "auth", "logout", "--hostname", "github.com"])
    }

    // MARK: repos & branches

    static func listRepos() async throws -> [GitHubRepo] {
        let res = try await Shell.run(["gh", "api", "--paginate",
                                       "user/repos?affiliation=owner,collaborator,organization_member&per_page=100&sort=pushed",
                                       "--jq", #".[] | [.full_name, (.private|tostring), .pushed_at] | @tsv"#], timeout: 60)
        var seen = Set<String>(); var out: [GitHubRepo] = []
        for ln in res.stdoutText.split(separator: "\n") {
            let f = ln.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].isEmpty, !seen.contains(f[0]) else { continue }
            seen.insert(f[0])
            out.append(GitHubRepo(fullName: f[0], isPrivate: f[1] == "true", pushedAt: f.count > 2 ? f[2] : ""))
        }
        return out
    }

    static func listBranches(_ repo: String) async throws -> [String] {
        guard repo.contains("/") else { throw SyncError(message: "repo must be owner/name") }
        let res = try await Shell.run(["gh", "api", "--paginate", "repos/\(repo)/branches?per_page=100", "--jq", ".[].name"], timeout: 60)
        return res.stdoutText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func createRepo(_ repo: String, isPrivate: Bool) async throws -> String {
        guard repo.contains("/") else { throw SyncError(message: "repo must be owner/name") }
        let res = try await Shell.run(["gh", "repo", "create", repo, isPrivate ? "--private" : "--public",
                                       "--description", "Beams sessions: Claude Code transcripts and memory"])
        return res.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: sync

    static func prefix(_ cfg: GitHubConfig) -> String {
        let p = cfg.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return p.isEmpty ? "beams" : p
    }

    /// Everything a session needs to be picked up later, all optional.
    struct Extras {
        var claudeSession: URL? = nil     // Claude's conversation file (for --resume)
        var codexSession: URL? = nil      // Codex rollout file (for exec resume)
        var meta: Data? = nil             // Session metadata, for listing and import
    }

    static func sync(cfg: GitHubConfig, cacheDir: URL, session: Session, transcriptMD: String,
                     transcriptJSONL: URL, memoryDir: URL, workspaceDir: URL? = nil, extras: Extras = Extras(),
                     log: @escaping (String) -> Void) async throws -> SyncResult {
        guard cfg.repo.contains("/") else { throw SyncError(message: "GitHub repo must be set as owner/name in the panel") }
        let branch = cfg.branch.isEmpty ? "main" : cfg.branch
        let prefix = prefix(cfg)
        try await ensureClone(repo: cfg.repo, dir: cacheDir, branch: branch, log: log)

        let fm = FileManager.default
        let sessDir = cacheDir.appendingPathComponent("\(prefix)/sessions/\(session.id)", isDirectory: true)
        try fm.createDirectory(at: sessDir, withIntermediateDirectories: true)
        try transcriptMD.write(to: sessDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: transcriptJSONL.path) {
            let dst = sessDir.appendingPathComponent("transcript.jsonl")
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: transcriptJSONL, to: dst)
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: memoryDir.path, isDirectory: &isDir), isDir.boolValue {
            log("Updating memory snapshot at \(prefix)/memory")
            let latest = cacheDir.appendingPathComponent("\(prefix)/memory", isDirectory: true)
            try? fm.removeItem(at: latest)
            try fm.copyItem(at: memoryDir, to: latest)
            let perSession = sessDir.appendingPathComponent("memory", isDirectory: true)
            try? fm.removeItem(at: perSession)
            try fm.copyItem(at: memoryDir, to: perSession)
        }

        // Generated files from the beam's working directory.
        if let workspaceDir, fm.fileExists(atPath: workspaceDir.path, isDirectory: &isDir), isDir.boolValue,
           (try? fm.contentsOfDirectory(atPath: workspaceDir.path))?.isEmpty == false {
            log("Adding generated files at \(prefix)/sessions/\(session.id)/workspace")
            let dst = sessDir.appendingPathComponent("workspace", isDirectory: true)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: workspaceDir, to: dst)
        }

        // What "pick up this session later" needs: the agent's own conversation
        // file (so it can resume in a new beam) and metadata for the list.
        for (src, name) in [(extras.claudeSession, "claude-session.jsonl"), (extras.codexSession, "codex-session.jsonl")] {
            guard let src, ((try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 else { continue }
            log("Saving \(name) so the conversation can be resumed")
            let dst = sessDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        if let meta = extras.meta { try meta.write(to: sessDir.appendingPathComponent("meta.json")) }

        try await git(cacheDir.path, ["add", "-A", "--", prefix])
        let status = try await git(cacheDir.path, ["status", "--porcelain", "--", prefix])
        if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log("Nothing new to commit.")
            return SyncResult(committed: false, branch: branch, message: "nothing to commit")
        }
        let title = session.title.isEmpty ? "session \(session.id.prefix(8))" : String(session.title.prefix(60))
        let msg = "beams: \(title) (\(session.beamName), \(session.turns) turns)"
        try await git(cacheDir.path, ["-c", "user.useConfigOnly=false", "commit", "-q", "-m", msg])
        log("Pushing to \(cfg.repo)@\(branch)")
        try await git(cacheDir.path, ["push", "-q", "-u", "origin", branch])
        let sha = try await git(cacheDir.path, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return SyncResult(committed: true, sha: sha, url: "https://github.com/\(cfg.repo)/commit/\(sha)", branch: branch, message: msg)
    }

    // MARK: previous sessions

    static func remoteSessionDir(cfg: GitHubConfig, cacheDir: URL, id: String) -> URL {
        cacheDir.appendingPathComponent("\(prefix(cfg))/sessions/\(id)", isDirectory: true)
    }

    /// Lists sessions synced under `<prefix>/sessions/` on the configured repo
    /// and branch, newest first. Works for sessions synced by older builds too
    /// (no meta.json): title, beam and turns come from the transcript header.
    static func listRemoteSessions(cfg: GitHubConfig, cacheDir: URL, log: @escaping (String) -> Void) async throws -> [RemoteSession] {
        guard cfg.repo.contains("/") else { throw SyncError(message: "Pick a GitHub repository in the panel first") }
        try await ensureClone(repo: cfg.repo, dir: cacheDir, branch: cfg.branch.isEmpty ? "main" : cfg.branch, log: log)
        return scanSessions(in: cacheDir.appendingPathComponent("\(prefix(cfg))/sessions", isDirectory: true))
    }

    /// Reads every `<id>/` folder under a sessions directory.
    static func scanSessions(in base: URL) -> [RemoteSession] {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
        var out: [RemoteSession] = []
        for id in ids where !id.hasPrefix(".") {
            let dir = base.appendingPathComponent(id, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let meta = (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
                .flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
            let header = parseTranscriptHeader(dir.appendingPathComponent("transcript.md"))
            let size = { (name: String) in ((try? dir.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            let nonEmptyDir = { (name: String) in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(name).path))?.isEmpty == false }
            let isCodex = !(meta?.codexThread ?? "").isEmpty || transcriptMentions(dir.appendingPathComponent("transcript.jsonl"), "\"thread.started\"")
            out.append(RemoteSession(
                id: id,
                title: meta.map { $0.title } ?? header.title,
                beamName: meta.map { $0.beamName } ?? header.beam,
                turns: meta.map { $0.turns } ?? header.turns,
                updated: meta?.updated ?? header.started,
                hasWorkspace: nonEmptyDir("workspace"),
                hasMemory: nonEmptyDir("memory"),
                hasClaudeSession: size("claude-session.jsonl") > 0,
                isCodex: isCodex,
                meta: meta))
        }
        return out.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    /// Reads the "# title / - Beam: / - Started: / - Turns:" header that
    /// `Store.renderMarkdown` writes at the top of transcript.md.
    static func parseTranscriptHeader(_ url: URL) -> (title: String, beam: String, turns: Int, started: Date?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ("", "", 0, nil) }
        var title = "", beam = "", turns = 0
        var started: Date? = nil
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12) {
            let l = String(line)
            if l.hasPrefix("# "), title.isEmpty { title = String(l.dropFirst(2)) }
            else if l.hasPrefix("- Beam: ") { beam = l.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "` ")) }
            else if l.hasPrefix("- Turns: ") { turns = Int(l.dropFirst(9).trimmingCharacters(in: .whitespaces)) ?? 0 }
            else if l.hasPrefix("- Started: ") { started = RFC3339.parse(l.dropFirst(11).trimmingCharacters(in: .whitespaces)) }
        }
        return (title == "Beam session" ? "" : title, beam, turns, started)
    }

    private static func transcriptMentions(_ url: URL, _ needle: String) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        return String(decoding: head, as: UTF8.self).contains(needle)
    }

    /// Pulls the repo and returns <prefix>/memory, or nil if there's no snapshot yet.
    static func restoreMemoryDir(cfg: GitHubConfig, cacheDir: URL, log: @escaping (String) -> Void) async throws -> URL? {
        guard cfg.repo.contains("/") else { throw SyncError(message: "GitHub repo must be set in the panel") }
        try await ensureClone(repo: cfg.repo, dir: cacheDir, branch: cfg.branch.isEmpty ? "main" : cfg.branch, log: log)
        let dir = cacheDir.appendingPathComponent("\(prefix(cfg))/memory", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
    }

    private static func ensureClone(repo: String, dir: URL, branch: String, log: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            log("Cloning \(repo)")
            try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try await git(nil, ["clone", "--quiet", "https://github.com/\(repo).git", dir.path])
            } catch {
                let s = String(describing: error)
                if s.contains("not found") || s.contains("Authentication failed") || s.contains("could not read Username") {
                    throw SyncError(message: "Clone of \(repo) failed: repository not found or no access. Sign in to GitHub in the panel, or create the repo.")
                }
                throw error
            }
        }
        log("Fetching origin")
        try await git(dir.path, ["fetch", "-q", "origin"])
        if (try? await git(dir.path, ["rev-parse", "--verify", "-q", "origin/\(branch)"])) != nil {
            try await git(dir.path, ["checkout", "-q", "-B", branch, "origin/\(branch)"])
            return
        }
        // New branch: start from the repo's default branch, not whatever the cache last had.
        var base = ""
        if let head = try? await git(dir.path, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]) {
            base = head.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if (try? await git(dir.path, ["rev-parse", "--verify", "-q", "origin/main"])) != nil {
            base = "origin/main"
        } else if (try? await git(dir.path, ["rev-parse", "--verify", "-q", "origin/master"])) != nil {
            base = "origin/master"
        }
        if !base.isEmpty {
            log("Creating branch \(branch) from \(base.replacingOccurrences(of: "refs/remotes/", with: ""))")
            try await git(dir.path, ["checkout", "-q", "-B", branch, base])
        } else {
            log("Repository is empty; creating branch \(branch)")
            try await git(dir.path, ["checkout", "-q", "-B", branch])
        }
    }
}
