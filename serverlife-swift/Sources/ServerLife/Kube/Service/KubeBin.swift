import Foundation

/// Where kubectl (and the tools around it — helm, k9s, stern, kubectx …)
/// live on this machine (kubebin.js). A Dock-launched app does not see the
/// login shell's PATH, so the usual install places are tried first, then
/// `which`, then the bare name as a last resort.
enum KubeBin {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: String?
    nonisolated(unsafe) private static var searchedList: [String] = []
    nonisolated(unsafe) private static var overridePath: String?
    nonisolated(unsafe) private static var versionCache: (path: String, info: JSON)?

    static let ecosystemTools = ["helm", "k9s", "stern", "kubectx", "kubens", "kind", "k3d", "minikube", "kustomize", "popeye", "kube-bench"]

    static let noAccess = "This cluster isn't letting you in yet — you may need to request access to it, or log in to its Teleport cluster again."

    static func candidates() -> [String] {
        let home = NSHomeDirectory()
        return [
            ProcessInfo.processInfo.environment["KUBECTL_PATH"],
            "/usr/local/bin/kubectl",
            "/opt/homebrew/bin/kubectl",
            "/opt/local/bin/kubectl", // MacPorts
            home + "/.nix-profile/bin/kubectl", // per-user Nix profile
            "/nix/var/nix/profiles/default/bin/kubectl", // system-wide Nix profile
            "/home/linuxbrew/.linuxbrew/bin/kubectl",
            "/snap/bin/kubectl",
            "/usr/bin/kubectl",
            "kubectl",
        ].compactMap { $0?.nilIfEmpty }
    }

    /// `setKubectlPath(p)`: an explicit kubectl; empty clears it.
    @discardableResult
    static func setKubectlPath(_ p: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        overridePath = (p ?? "").trimmed.nilIfEmpty
        cache = nil
        versionCache = nil
        return overridePath
    }

    private static func which(_ name: String) -> String? {
        let r = Proc.runSync("/usr/bin/which", [name], timeout: 5)
        guard r.ok else { return nil }
        let first = r.out.components(separatedBy: .newlines).map(\.trimmed).first { !$0.isEmpty }
        if let first, FileManager.default.fileExists(atPath: first) { return first }
        return nil
    }

    /// The kubectl to spawn. Always returns something runnable-looking.
    static func findKubectl() -> String {
        lock.lock()
        if let c = cache { lock.unlock(); return c }
        if let o = overridePath { cache = o; lock.unlock(); return o }
        searchedList = candidates()
        for p in searchedList where p != "kubectl" {
            if FileManager.default.fileExists(atPath: p) { cache = p; lock.unlock(); return p }
        }
        lock.unlock()
        let found = which("kubectl") ?? "kubectl"
        lock.lock(); cache = found; lock.unlock()
        return found
    }

    /// Is there really a kubectl here?
    static func kubectlAvailable() -> Bool {
        let resolved = findKubectl()
        if resolved == "kubectl" { return which("kubectl") != nil }
        return FileManager.default.fileExists(atPath: resolved)
    }

    static func kubectlStatus() -> JSON {
        let path = findKubectl()
        lock.lock(); let o = overridePath; let s = searchedList; lock.unlock()
        return ["path": .string(path), "found": .bool(kubectlAvailable()), "override": JSON(o),
                "searched": JSON(s), "version": kubectlVersion()]
    }

    /// `kubectl version --client` output → `{raw, major, minor, patch}`.
    static func parseKubectlVersion(_ text: String) -> JSON {
        let raw = text.trimmed
        let m = TPText.match(#"Client Version:\s*v?(\d+)\.(\d+)\.(\d+)"#, raw, .caseInsensitive)
            ?? TPText.match(#"v(\d+)\.(\d+)\.(\d+)"#, raw)
        guard let m else { return ["raw": .string(raw), "major": .null, "minor": .null, "patch": .null] }
        func n(_ i: Int) -> JSON { .number(Double(m[i] ?? "") ?? 0) }
        return ["raw": .string(raw), "major": n(1), "minor": n(2), "patch": n(3)]
    }

    static func kubectlVersion() -> JSON {
        let resolved = findKubectl()
        lock.lock()
        if let v = versionCache, v.path == resolved { lock.unlock(); return v.info }
        lock.unlock()
        let r = Proc.runSync(resolved, ["version", "--client"], env: kubectlEnv(), timeout: 5)
        let text = r.out.isEmpty ? r.err : r.out
        let info: JSON = text.trimmed.isEmpty ? .null : parseKubectlVersion(text)
        lock.lock(); versionCache = (resolved, info); lock.unlock()
        return info
    }

    /// The directories worth looking in for a tool that is not beside kubectl.
    static func toolDirs() -> [String] {
        var dirs = candidates().filter { $0.contains("/") }.map { ($0 as NSString).deletingLastPathComponent }
        dirs.append(NSHomeDirectory() + "/.local/bin")
        dirs.append(NSHomeDirectory() + "/bin")
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    static func findTool(_ name: String) -> String {
        let beside = ((findKubectl() as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        if beside.contains("/"), FileManager.default.fileExists(atPath: beside) { return beside }
        for dir in toolDirs() {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return which(name) ?? name
    }

    /// Whether `name` is really there (not just the bare name to go on).
    static func toolAvailable(_ name: String) -> Bool {
        let resolved = findTool(name)
        if resolved == name { return false }
        return FileManager.default.fileExists(atPath: resolved)
    }

    /// Every ecosystem tool's status in one call, for a Settings/status row.
    static func ecosystemStatus() -> JSON {
        var out: [String: JSON] = [:]
        for name in ecosystemTools { out[name] = ["path": .string(findTool(name)), "found": .bool(toolAvailable(name))] }
        return .object(out)
    }

    /// Environment for a spawned kubectl (or a sibling tool): the binary's own directory has to be findable.
    static func kubectlEnv(_ extra: [String: String?] = [:]) -> [String: String?] {
        var env = extra
        let dir = (findKubectl() as NSString).deletingLastPathComponent
        let current = Proc.path
        if !dir.isEmpty, dir != ".", !current.split(separator: ":").map(String.init).contains(dir) {
            env["PATH"] = [current, dir].filter { !$0.isEmpty }.joined(separator: ":")
        }
        return env
    }

    static func kubectlMissingMessage() -> String {
        "kubectl was not found (looked for \(findKubectl())). Install it — brew install kubectl — and reopen ServerLife."
    }

    /// kubectl's (and its exec plugin's) errors, said for people.
    static func humanizeKubectlError(_ text: String) -> String {
        let raw = text.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
        if raw.trimmed.isEmpty { return raw }
        if TPText.test(#"server API group list: unknown|Error from server \(Forbidden\): unknown\b|^panic: |\bgoroutine \d+ \[|the server has asked for the client to provide credentials|\bUnauthorized\b"#, raw, .anchorsMatchLines) {
            return noAccess
        }
        if TPText.test(#"certificate (has )?expired|x509: certificate|relogin|tsh login|ssh: cert has expired"#, raw, .caseInsensitive) {
            return "Your login to this cluster has expired — log in to its Teleport cluster again."
        }
        if let m = TPText.match(#"cannot (\w+) resource "([^"]+)"(?: in API group "([^"]*)")?(?: in the namespace "([^"]+)"| at the cluster scope)?"#, raw) {
            let ns = m[4] ?? nil
            return "Not allowed: your role can't \(m[1] ?? "") \(m[2] ?? "")\(ns.map { " in \($0)" } ?? "")."
        }
        if TPText.test(#"Unable to connect to the server|connection refused|no such host|i/o timeout|context deadline exceeded|TLS handshake timeout"#, raw, .caseInsensitive) {
            let why = TPText.match(#"(dial tcp [^:]*:\d+: [^\n]+|no such host|i/o timeout|connection refused|TLS handshake timeout)"#, raw, .caseInsensitive)?[1] ?? nil
            return "Can't reach the cluster\(why.map { " (\($0.trimmed))" } ?? "")."
        }
        var lines: [String] = []
        for line in raw.components(separatedBy: "\n") {
            if TPText.test(#"^panic: |^goroutine \d+|^\s+\S+\.go:\d+|^\S+\(0x[0-9a-f]+"#, line) { break }
            var cleaned = line.replacingOccurrences(of: #"^[EWIF]\d{4} \d{2}:\d{2}:\d{2}\.\d+\s+\d+\s+\S+:\d+\]\s*"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "^error: ", with: "", options: [.regularExpression, .caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: #"^Error from server \((\w+)\): "#, with: "$1: ", options: .regularExpression)
            cleaned = cleaned.trimmed
            if !cleaned.isEmpty && !cleaned.hasPrefix("Unhandled Error") { lines.append(cleaned) }
            if lines.count >= 2 { break }
        }
        return lines.isEmpty ? (raw.trimmed.components(separatedBy: "\n").first ?? "") : lines.joined(separator: "\n")
    }
}

/// One finished kubectl/helm/tsh run, already through `explainMissing`.
struct KubeRun: Sendable {
    var ok: Bool
    var stdout: String
    var stderr: String
    /// kubectl's own words, when `stderr` was rewritten for people.
    var rawStderr: String?
    /// Exit status (nil when it never started or timed out).
    var code: Int32?
    var noAccess = false
    var timedOut = false
    var spawnError: String?

    init(ok: Bool, stdout: String = "", stderr: String = "", rawStderr: String? = nil, code: Int32? = nil,
         noAccess: Bool = false, timedOut: Bool = false, spawnError: String? = nil) {
        self.ok = ok; self.stdout = stdout; self.stderr = stderr; self.rawStderr = rawStderr; self.code = code
        self.noAccess = noAccess; self.timedOut = timedOut; self.spawnError = spawnError
    }

    init(_ r: ProcResult) {
        ok = r.ok; stdout = r.out; stderr = r.err
        code = (r.spawnError == nil && !r.timedOut) ? r.code : nil
        timedOut = r.timedOut; spawnError = r.spawnError
    }

    /// `err.message` in execFile's callback, roughly.
    var errMessage: String? {
        if ok { return nil }
        if let s = spawnError { return s }
        if timedOut { return "timed out" }
        return "Command failed with exit code \(code ?? -1)"
    }
}

extension KubeBin {
    /// A finished kubectl run's result: a missing binary spelled out, and any other failure said plainly.
    static func explainMissing(_ r: KubeRun) -> KubeRun {
        var r = r
        if !r.ok, r.spawnError != nil { r.stderr = kubectlMissingMessage(); return r }
        if !r.ok, !r.stderr.isEmpty {
            let said = humanizeKubectlError(r.stderr)
            r.rawStderr = r.stderr
            r.stderr = said
            r.noAccess = said == noAccess
        }
        return r
    }

    /// `execFile(bin, args, {timeout, env})` + explainMissing. `stdin` is fed and closed.
    static func run(_ bin: String, _ args: [String], env: [String: String?], timeout: TimeInterval = 20,
                    stdin: String? = nil, explain: Bool = true) async -> KubeRun {
        let r = await Proc.run(bin, args, env: env, stdin: stdin.map { Data($0.utf8) }, timeout: timeout)
        let k = KubeRun(r)
        return explain ? explainMissing(k) : k
    }
}

/// `plain()` in the kube modules: no colour codes, trimmed.
func kubePlain(_ s: String?) -> String { TPText.plain(s) }
