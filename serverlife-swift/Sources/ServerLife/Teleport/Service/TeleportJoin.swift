import Foundation

/// teleport.js `findTctl`, `tctlRun`, `nodeInstallCommand`, `createJoinToken`:
/// what the install wizards (an SSH host or a Kubernetes cluster lacking
/// Teleport) need to put something behind a cluster.
extension Teleport {
    private static let tctlCache = TPLocked<String?>(nil)

    /// `tctl` — beside `tsh` first, the layout the standard Teleport package
    /// (not Teleport Connect, which is tsh-only) actually installs, then PATH.
    /// Used only for generating a join token for the install wizards —
    /// everything else here is `tsh`.
    static func findTctl() -> String {
        if let c = tctlCache.get() { return c }
        let fm = FileManager.default
        let beside = ((Tools.tsh as NSString).deletingLastPathComponent as NSString).appendingPathComponent("tctl")
        var found = "tctl"
        if Tools.tsh.contains("/"), fm.fileExists(atPath: beside) { found = beside }
        else if let w = Proc.which("tctl"), fm.fileExists(atPath: w) { found = w }
        tctlCache.set(found)
        return found
    }

    /// Forget where tctl was (a different tsh was chosen).
    static func forgetTctl() { tctlCache.set(nil) }

    struct TctlResult: Sendable { var ok: Bool; var stdout: String; var stderr: String }

    /// `tctlRun`. Which cluster it runs on is said outright:
    /// `--auth-server=<proxy>` makes tctl use that proxy's own tsh login.
    /// Without it tctl took the *current* tsh profile, whatever that was — a
    /// token for the cluster picked in the wizard was minted on another one,
    /// and the agent was then told "token expired or not found" by the
    /// cluster it actually joined. TELEPORT_PROXY is dropped for the same
    /// reason: a value from the person's own shell must not be what decides.
    static func tctlRun(_ args: [String], proxy: String?, home: String? = nil, timeout: Double = 30) async -> TctlResult {
        let h = home ?? Tools.home(forProxy: proxy)
        var env = TshEnv.overrides(home: h, proxy: proxy)
        env["TELEPORT_PROXY"] = .some(nil)
        var target: [String] = []
        if let p = proxy?.nilIfEmpty {
            target = ["--auth-server=" + (TPText.test(#":\d+$"#, p) ? p : p + ":443")]
        }
        let r = await Proc.run(findTctl(), target + args, env: env, timeout: timeout)
        return TctlResult(ok: r.ok, stdout: TPText.plain(r.out),
                          stderr: TPText.plain(r.err.isEmpty ? (r.spawnError ?? "") : r.err))
    }

    struct NodeInstall: Equatable, Sendable {
        var ok: Bool
        var command = ""
        var oneLine = ""
        var error: String?
    }

    static let nodeLabelKey = #"^[A-Za-z0-9][A-Za-z0-9_./-]{0,62}$"#
    static let nodeLabelValue = #"^[A-Za-z0-9_.:/@-]{0,63}$"#
    static let nodeNamePattern = #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$"#

    /// `nodeInstallCommand`: the commands that put an SSH host behind
    /// Teleport, for the cluster picked:
    ///
    ///   1. https://<proxy>/scripts/install.sh — the cluster's own installer,
    ///      with that cluster's exact version and edition written into it,
    ///      which installs Teleport through teleport-update;
    ///   2. `teleport node configure` — --proxy, --token, --node-name, --labels;
    ///   3. starting the service.
    ///
    /// Not the per-token install-node.sh join script: that may go away, and it
    /// ignores both the token's labels and any node name. Labels and the name
    /// are checked to be plain characters first, so nothing in them can break
    /// the command. `labels` keeps its order (pairs).
    static func nodeInstallCommand(proxy: String?, token: String?, labels: [(String, String)] = [],
                                   nodeName: String = "") -> NodeInstall {
        guard let proxy = proxy?.nilIfEmpty else { return NodeInstall(ok: false, error: "Pick the Teleport cluster to join.") }
        let host = proxy.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":443$"#, with: "", options: .regularExpression)
        let proxyAddr = TPText.test(#":\d+$"#, host) ? host : "\(host):443"
        var errors: [String] = []
        let pairs = labels.filter { !$0.0.isEmpty }
        for (k, v) in pairs {
            if !TPText.test(nodeLabelKey, k) { errors.append("Label key \"\(k)\": letters, digits, \"_\", \".\", \"/\" and \"-\" only") }
            if !TPText.test(nodeLabelValue, v) { errors.append("Label \"\(k)\" value \"\(v)\": letters, digits and _ . : / @ - only") }
        }
        let name = nodeName.trimmed
        if !name.isEmpty && !TPText.test(nodeNamePattern, name) {
            errors.append("Node name \"\(name)\": letters, digits, \"_\", \".\" and \"-\" only")
        }
        if !errors.isEmpty { return NodeInstall(ok: false, error: errors.joined(separator: "\n")) }
        var configure = ["sudo teleport node configure", "--output=file:///etc/teleport.yaml",
                         "--proxy=\(proxyAddr)", "--token=\(token?.nilIfEmpty ?? "<join-token>")"]
        if !name.isEmpty { configure.append("--node-name=\(name)") }
        if !pairs.isEmpty { configure.append("--labels=" + pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ",")) }
        let lines = ["curl -fsSL https://\(host)/scripts/install.sh | sudo sh",
                     configure.joined(separator: " "),
                     "sudo systemctl enable --now teleport"]
        return NodeInstall(ok: true, command: lines.joined(separator: "\n"), oneLine: lines.joined(separator: " && "))
    }

    struct JoinToken: Equatable, Sendable {
        var ok: Bool
        var token = ""
        var cluster = ""
        var error: String?
    }

    /// The cluster `tctl status` says answered.
    static func tctlStatusCluster(_ out: String) -> String {
        (TPText.match(#"^Cluster:\s*(\S+)"#, out, .anchorsMatchLines)?[1] ?? nil) ?? ""
    }

    /// tctl's text format is a short paragraph of instructions ending in the
    /// token itself — the last non-blank line, not the whole paragraph.
    static func tokenFrom(_ out: String) -> String? {
        out.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }.last
    }

    /// `createJoinToken`: `tctl tokens add --type=<type> --ttl=<ttl>`, checked
    /// before anything is created: `tctl status` names the cluster that
    /// answered, and a token is only made when that is the one asked for
    /// (`cluster`, the profile's own cluster name — not always the proxy's
    /// host). The cluster that issued it comes back with the token.
    static func createJoinToken(type: String, ttl: String = "1h", proxy: String?, home: String? = nil,
                                cluster: String? = nil) async -> JoinToken {
        guard let proxy = proxy?.nilIfEmpty else { return JoinToken(ok: false, error: "No Teleport proxy given to make the token on.") }
        let st = await tctlRun(["status"], proxy: proxy, home: home)
        if !st.ok { return JoinToken(ok: false, error: st.stderr.nilIfEmpty ?? st.stdout.nilIfEmpty ?? "tctl status failed") }
        let answered = tctlStatusCluster(st.stdout)
        if let c = cluster?.nilIfEmpty, !answered.isEmpty, answered != c {
            return JoinToken(ok: false, error: "tctl reached cluster \"\(answered)\", not \"\(c)\" \u{2014} no token was made.")
        }
        let r = await tctlRun(["tokens", "add", "--type=" + type, "--ttl=" + ttl, "--format=text"], proxy: proxy, home: home)
        if !r.ok { return JoinToken(ok: false, error: r.stderr.nilIfEmpty ?? r.stdout.nilIfEmpty ?? "tctl tokens add failed") }
        guard let token = tokenFrom(r.stdout) else { return JoinToken(ok: false, error: "tctl printed no token") }
        return JoinToken(ok: true, token: token, cluster: answered)
    }
}
