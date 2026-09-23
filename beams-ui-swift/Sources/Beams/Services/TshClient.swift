import Foundation

/// What the app needs from a beams backend. TshClient is the real thing;
/// MockClient lets the UI run without a cluster (BEAMSUI_MOCK=1).
protocol BeamClient {
    var kind: String { get }
    func list() async throws -> [Beam]
    func create() async throws -> Beam
    func delete(id: String) async throws
    /// Runs `sh -lc <script>` in the beam. Streams stdout lines when
    /// `onStdoutLine` is given, otherwise returns stdout as Data.
    @discardableResult
    func run(id: String, script: String, stdin: Data?, interactiveStdin: Bool,
             onStdoutLine: ((String) -> Void)?, onStderrLine: ((String) -> Void)?,
             register: ((RunningProcess) -> Void)?) async throws -> ProcessResult
    func copyTo(id: String, local: String, remote: String, recursive: Bool) async throws
}

extension BeamClient {
    func run(id: String, script: String) async throws -> ProcessResult {
        try await run(id: id, script: script, stdin: nil, interactiveStdin: false, onStdoutLine: nil, onStderrLine: nil, register: nil)
    }
}

// MARK: - tsh

struct TshStatus {
    var tshFound = false
    var tshPath = ""
    var loggedIn = false
    var proxy = ""
    var user = ""
    var cluster = ""
    var validUntil = ""
    var message = ""
}

enum TshError: Error { case needsTerminal }

struct TshClient: BeamClient {
    var bin: String
    var proxy: String
    var login: String
    var kind: String { "tsh" }

    private func args(_ sub: [String]) -> [String] {
        var a = [bin]
        if !proxy.isEmpty { a.append("--proxy=\(proxy)") }
        if !login.isEmpty { a.append("--login=\(login)") }
        return a + sub
    }

    private func runJSON(_ sub: [String], timeout: TimeInterval = 45) async throws -> Any {
        let res = try await Shell.run(args(sub), timeout: timeout)
        var data = res.stdout
        // tsh may print a login banner before the JSON; skip to the first bracket.
        if let i = data.firstIndex(where: { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "{") }) {
            data = data[i...]
        }
        if data.isEmpty { return [] }
        return try JSONSerialization.jsonObject(with: data)
    }

    func list() async throws -> [Beam] {
        let rows = try await runJSON(["beams", "ls", "-f", "json"]) as? [[String: Any]] ?? []
        return rows.map(Beam.init(row:))
    }

    func create() async throws -> Beam {
        let row = try await runJSON(["beams", "add", "-f", "json", "--no-console"], timeout: 180) as? [String: Any] ?? [:]
        return Beam(row: row)
    }

    func delete(id: String) async throws {
        try await Shell.run(args(["beams", "rm", id]), timeout: 60)
    }

    /// tsh joins the remaining args with spaces for the remote shell, so the
    /// script is single-quoted to arrive intact.
    func run(id: String, script: String, stdin: Data?, interactiveStdin: Bool,
             onStdoutLine: ((String) -> Void)?, onStderrLine: ((String) -> Void)?,
             register: ((RunningProcess) -> Void)?) async throws -> ProcessResult {
        try await Shell.run(args(["beams", "exec", id, "--", "sh", "-lc", Shell.quote(script)]),
                            stdin: stdin, interactiveStdin: interactiveStdin,
                            onStdoutLine: onStdoutLine, onStderrLine: onStderrLine, register: register)
    }

    func copyTo(id: String, local: String, remote: String, recursive: Bool) async throws {
        var sub = ["beams", "scp", "-q"]
        if recursive { sub.append("-r") }
        sub += [local, "\(id):\(remote)"]
        try await Shell.run(args(sub))
    }

    // MARK: login state

    func loginCommand(user: String) -> String {
        var cmd = "\(bin) login --proxy=\(proxy)"
        if !user.isEmpty { cmd += " --user=\(user)" }
        return cmd
    }

    /// Inspects `tsh status -f json` without triggering a login.
    func status() async -> TshStatus {
        var st = TshStatus(proxy: proxy)
        guard let path = Shell.which(bin) else {
            st.message = "\"\(bin)\" not found on PATH. Install Teleport (tsh) or set its path in Settings."
            return st
        }
        st.tshFound = true; st.tshPath = path
        let res = try? await Shell.run([bin, "status", "-f", "json"], timeout: 30, check: false)
        guard var data = res?.stdout else { st.message = "Not logged in to Teleport."; return st }
        if let i = data.firstIndex(of: UInt8(ascii: "{")) { data = data[i...] }
        guard !data.isEmpty, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            st.message = "Not logged in to Teleport."; return st
        }
        var profiles: [[String: Any]] = []
        if let a = obj["active"] as? [String: Any] { profiles.append(a) }
        profiles += obj["profiles"] as? [[String: Any]] ?? []
        let want = hostOnly(proxy)
        let match = profiles.first { p in
            want.isEmpty
                || hostOnly(p["profile_url"] as? String ?? "").contains(want)
                || (p["cluster"] as? String ?? "").contains(want)
        }
        guard let m = match else { st.message = "No tsh profile for \(proxy) yet."; return st }
        st.user = m["username"] as? String ?? ""
        st.cluster = m["cluster"] as? String ?? ""
        st.validUntil = m["valid_until"] as? String ?? ""
        if st.proxy.isEmpty { st.proxy = hostOnly(m["profile_url"] as? String ?? "") }
        if let exp = RFC3339.parse(st.validUntil), exp < Date() {
            let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
            st.message = "Certificate for \(st.cluster) expired \(f.string(from: exp))."
            return st
        }
        st.loggedIn = true
        st.message = "Logged in to \(st.cluster) as \(st.user)"
        return st
    }

    /// Headless `tsh login`. SSO clusters open the browser and succeed;
    /// local-password clusters throw `.needsTerminal`.
    func runLogin(user: String, log: @escaping (String) -> Void) async throws {
        var sub = [bin, "login", "--proxy=\(proxy)"]
        if !user.isEmpty { sub.append("--user=\(user)") }
        var tail: [String] = []
        let handle: (String) -> Void = { raw in
            let ln = Shell.stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ln.isEmpty, !ln.hasPrefix("Update progress") else { return }
            tail.append(ln); if tail.count > 20 { tail.removeFirst() }
            log(ln)
        }
        let res = try await Shell.run(sub, stdin: Data(), onStdoutLine: handle, onStderrLine: handle, check: false)
        if res.ok { return }
        let joined = tail.joined(separator: "\n").lowercased()
        if joined.contains("without a terminal") || joined.contains("not a terminal") || joined.contains("password") {
            throw TshError.needsTerminal
        }
        throw ProcessError(command: "tsh login", status: res.status, stderr: tail.joined(separator: " / "))
    }

    static func isAuthError(_ e: Error) -> Bool {
        let s = String(describing: e).lowercased() + (e.localizedDescription.lowercased())
        return ["not logged in", "certificate has expired", "expired", "no credentials", "cannot perform password login",
                "without a terminal", "access denied", "please login", "relogin", "re-login", "x509",
                "ssh: handshake failed", "no such profile"].contains { s.contains($0) }
    }
}

func hostOnly(_ u: String) -> String {
    var s = u
    for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
    if let i = s.firstIndex(where: { $0 == ":" || $0 == "/" }) { s = String(s[..<i]) }
    return s.lowercased()
}

// MARK: - Mock

/// Simulates a cluster so the UI can be developed without network access.
final class MockClient: BeamClient {
    var kind: String { "mock" }
    private var beams: [Beam] = [Beam(id: "mild-moon", name: "mild-moon", raw: ["owner": "paul.hall@goteleport.com", "region": "us-west-2"])]
    private var n = 0

    func list() async throws -> [Beam] { beams }

    func create() async throws -> Beam {
        try await Task.sleep(nanoseconds: 1_200_000_000)
        n += 1
        let names = ["quiet-river", "bold-fox", "amber-sky", "calm-otter"]
        let b = Beam(id: names[n % names.count], name: names[n % names.count], raw: ["region": "us-west-2"])
        beams.append(b)
        return b
    }

    func delete(id: String) async throws { beams.removeAll { $0.id == id } }
    func copyTo(id: String, local: String, remote: String, recursive: Bool) async throws {}

    func run(id: String, script: String, stdin: Data?, interactiveStdin: Bool,
             onStdoutLine: ((String) -> Void)?, onStderrLine: ((String) -> Void)?,
             register: ((RunningProcess) -> Void)?) async throws -> ProcessResult {
        if script.contains("claude -p") {
            try await fakeAgent(script: script, emit: onStdoutLine ?? { _ in })
            return ProcessResult(status: 0, stdout: Data(), stderr: "")
        }
        if script.contains("tar czf -") {
            return ProcessResult(status: 0, stdout: try fakeMemoryTar(), stderr: "")
        }
        let probe = "beams\n/home/beams\n2.1.258 (Claude Code)\n"
        onStdoutLine?("beams"); onStdoutLine?("/home/beams"); onStdoutLine?("2.1.258 (Claude Code)")
        return ProcessResult(status: 0, stdout: Data(probe.utf8), stderr: "")
    }

    private func fakeMemoryTar() throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("beams-mock-\(UUID().uuidString)")
        let mem = dir.appendingPathComponent("projects/-home-beams-work/memory")
        try FileManager.default.createDirectory(at: mem, withIntermediateDirectories: true)
        try "# Beam sandbox\nRun `cat /etc/motd` for setup notes.\n".write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "- [Repo layout](repo-layout.md) — where things live\n".write(to: mem.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try "---\nname: repo-layout\ndescription: Where the code lives\nmetadata:\n  type: project\n---\n\nSwift app in Sources/Beams.\n".write(to: mem.appendingPathComponent("repo-layout.md"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["czf", "-", "-C", dir.path, "."]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: dir)
        return data
    }

    private func fakeAgent(script: String, emit: @escaping (String) -> Void) async throws {
        var sid = "mock-session"
        for flag in ["--session-id ", "--resume "] {
            if let r = script.range(of: flag) {
                sid = String(script[r.upperBound...].split(separator: " ").first ?? "mock"); break
            }
        }
        let steps: [(String, UInt64)] = [
            (#"{"type":"system","subtype":"init","cwd":"/home/beams/work","session_id":"SID","model":"claude-sonnet-5","permissionMode":"bypassPermissions"}"#, 400),
            (#"{"type":"assistant","session_id":"SID","message":{"role":"assistant","content":[{"type":"text","text":"I'll take a look at the sandbox first."}]}}"#, 900),
            (#"{"type":"assistant","session_id":"SID","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"ls -la ~ && cat /etc/motd | head -20","description":"List home and read the motd"}}]}}"#, 700),
            (#"{"type":"user","session_id":"SID","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"total 44\ndrwxr-xr-x. 5 beams beams 4096 .\n-rw-r--r--. 1 beams beams 2068 AGENTS.md\n\nWelcome to your beam."}]}}"#, 1200),
            (#"{"type":"assistant","session_id":"SID","message":{"role":"assistant","content":[{"type":"text","text":"This beam is a **Debian 12** sandbox with Claude Code, Node 24 and git preinstalled.\n\n- AGENTS.md with API notes\n- examples/ with a sample\n\n```bash\nmkdir -p ~/work && cd ~/work\n```\n\nPublished demo: https://mild-moon-7727.super-grass.beams.sh"}]}}"#, 1500),
            (#"{"type":"result","subtype":"success","is_error":false,"duration_ms":4900,"num_turns":2,"session_id":"SID","total_cost_usd":0.0412,"result":"ok"}"#, 300),
        ]
        for (line, ms) in steps {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: ms * 1_000_000)
            emit(line.replacingOccurrences(of: "SID", with: sid))
        }
    }
}
