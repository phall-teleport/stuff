import Foundation
import Security
import CryptoKit

// kuberesources.js, second half: heartbeats (readyz, a Teleport kube login of
// the app's own, kube_servers via tctl), provider detection and the Cloud view.

extension KubeResources {
    /// What went wrong, told apart: login, MFA, no access, timeout, agent, not ready.
    static func heartbeatState(ok: Bool, stdout: String?, stderr: String?) -> (state: String, detail: String) {
        let err = stderr ?? ""
        let ci = NSRegularExpression.Options.caseInsensitive
        if ok { return ("ok", kubeOr(String((stdout ?? "").trimmed.prefix(80)), "ok")) }
        // Refused by a server that answered: alive. 403 is this role; 401 is these credentials.
        if TPText.test(#"\b401\b|Unauthorized|must be logged in"#, err, ci) { return ("login", "answering, but it refused these credentials — log in again") }
        if TPText.test(#"\b403\b|forbidden"#, err, ci) { return ("ok", "answering — /readyz is not open to this role") }
        // The kubeconfig's credential plugin is not installed: no request was made at all.
        if let plugin = TPText.match(#"executable (\S+) (?:not found|failed)|Install (\S+) for use with kubectl"#, err, ci) {
            let p1 = plugin.count > 1 ? plugin[1] : nil
            let p2 = plugin.count > 2 ? plugin[2] : nil
            if !TPText.test("tsh", p1 ?? "") {
                let tool = (p1?.nilIfEmpty ?? p2 ?? "").components(separatedBy: "/").last ?? ""
                return ("login", "can't sign in: \(tool) is not installed or failed")
            }
        }
        if TPText.test(#"mfa|multi-factor|second factor|webauthn|touch id|hardware key"#, err, ci) { return ("mfa", "needs per-session MFA — not checked") }
        if TPText.test(#"role does not allow Kubernetes access|kubernetes_groups and kubernetes_users"#, err, ci) {
            return ("noaccess", "Teleport answered, but your role gives no Kubernetes access to it (no kubernetes_groups or kubernetes_users)")
        }
        if TPText.test(#"expired|not logged in|tsh login|relogin|credentials.*(expired|invalid)|sso|token has expired"#, err, ci) { return ("login", "its login has lapsed") }
        if TPText.test(#"timeout|deadline exceeded|timed out|Client\.Timeout"#, err, ci) { return ("timeout", "no answer within 10 s") }
        if TPText.test(#"tunnel|no.*(agent|kube_server)|kubernetes cluster.*not found|not found.*kubernetes cluster|connection reset|EOF|no such host|connection refused|unreachable"#, err, ci) {
            return ("agent", "not reachable — the Teleport agent or the network to the cluster")
        }
        if TPText.test(#"unable to handle the request|readyz check failed|is not ready|InternalError|ServiceUnavailable|503"#, err, ci) {
            return ("notready", "the API server answered that it is not ready")
        }
        let first = err.components(separatedBy: "\n").first { !$0.trimmed.isEmpty }
        return ("error", first.map { String($0.prefix(200)) } ?? "kubectl failed")
    }

    static func heartbeatStateJSON(ok: Bool, stdout: String?, stderr: String?) -> JSON {
        let s = heartbeatState(ok: ok, stdout: stdout, stderr: stderr)
        return ["state": .string(s.state), "detail": .string(s.detail)]
    }

    // MARK: - Certificates on disk

    /// notAfter of the first certificate in PEM text, or of a DER blob.
    static func certNotAfter(_ data: Data) -> Date? {
        var der = data
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            guard let m = TPText.match(#"-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----"#, text),
                  m.count > 1, let body = m[1],
                  let d = Data(base64Encoded: body.components(separatedBy: .whitespacesAndNewlines).joined()) else { return nil }
            der = d
        }
        guard let c = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return NetTLS.values(c).notAfter
    }

    private static func bareHost(_ proxy: String?) -> String {
        (proxy ?? "").replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
    }

    private static func fileNames(_ dir: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: dir)
    }

    /// Whether a context reached through Teleport can be asked without tsh
    /// logging in again: its cached kube certificate (`keys/<proxy>/<user>-kube/
    /// <cluster>/<kube>.cred`, or the older `-x509.pem`), in the one home tsh
    /// will use for it. `{teleport, home, validUntil, good, cluster, kubeCluster}`.
    static func teleportCredFor(_ spec: KubeSpec) async -> JSON {
        let k = clusterArgs(spec)
        let r = await run(k, ["config", "view", "-o", "json", "--minify"], timeout: 10)
        guard let view = try? JSON.parse(r.stdout.isEmpty ? "{}" : r.stdout) else { return ["teleport": false] }
        let user = view["users"].items.first?["user"] ?? .null
        guard let origin = Kube.teleportOriginOf(user) else { return ["teleport": false] }
        let host = bareHost(origin.proxy)
        // TELEPORT_HOME from the exec entry, else the one kubectl passes down, else ~/.tsh.
        let homeEnv = user["exec"]["env"].items.first { $0["name"].string == "TELEPORT_HOME" }?["value"].string?.nilIfEmpty
        let envHome = (k.env["TELEPORT_HOME"] ?? nil)?.nilIfEmpty
        let home = TeleportHomes.expand(homeEnv ?? envHome ?? ProcessInfo.processInfo.environment["TELEPORT_HOME"]?.nilIfEmpty ?? "~/.tsh")
        var best = 0.0
        let base = (home as NSString).appendingPathComponent("keys/" + host)
        for u in (fileNames(base) ?? []).filter({ $0.hasSuffix("-kube") }) {
            for name in ["\(origin.kubeCluster).cred", "\(origin.kubeCluster)-x509.pem"] {
                let p = [base, u, origin.cluster, name].joined(separator: "/")
                guard let d = FileManager.default.contents(atPath: p), let na = certNotAfter(d) else { continue }
                best = max(best, na.timeIntervalSince1970 * 1000)
            }
        }
        return [
            "teleport": true, "home": .string(home), "validUntil": best > 0 ? .number(best) : .null,
            "good": .bool(best > Double(nowMs()) + 60_000),
            "cluster": .string(origin.cluster), "kubeCluster": .string(origin.kubeCluster),
        ]
    }

    /// Whether this home's Teleport login (keys/<proxy>/<user>.crt) has at least
    /// two minutes left — read from disk, never by running tsh.
    static func teleportLoginGood(home: String?, proxy: String?) -> Bool {
        let h = TeleportHomes.expand(home?.nilIfEmpty ?? ProcessInfo.processInfo.environment["TELEPORT_HOME"]?.nilIfEmpty ?? "~/.tsh")
        let dir = (h as NSString).appendingPathComponent("keys/" + bareHost(proxy))
        guard let names = fileNames(dir) else { return false }
        var best = 0.0
        for n in names where n.hasSuffix(".crt") {
            guard let d = FileManager.default.contents(atPath: dir + "/" + n), let na = certNotAfter(d) else { continue }
            best = max(best, na.timeIntervalSince1970 * 1000)
        }
        return best > Double(nowMs()) + 120_000
    }

    /// teleport.js `kubeInventoryId`: the id an inventory kube row (and the MFA mark) uses.
    static func kubeInventoryId(cluster: String?, name: String, home: String? = nil) -> String {
        TeleportHomes.isDefault(home)
            ? "tsh-kube:\(cluster ?? ""):\(name)"
            : "tsh-kube:\(kubeOr(TeleportHomes.name(home), home ?? "")):\(cluster ?? ""):\(name)"
    }

    // MARK: - Heartbeats

    /// A Kubernetes cluster's heartbeat: `GET /readyz`, through the same
    /// kubeconfig and Teleport path as everything else. `gate` reads the
    /// cached Teleport certificate first, so nothing here ever logs in.
    static func heartbeat(_ spec: KubeSpec, gate: Bool = true, mfaHosts: [String] = []) async -> JSON {
        let cred: JSON = gate ? await teleportCredFor(spec) : ["teleport": false]
        if cred["teleport"].truthy && !cred["good"].truthy {
            return ["ok": false, "state": "idle", "ms": 0, "at": .number(Double(nowMs())),
                    "detail": .string(cred["validUntil"].isNull
                        ? "not checked — no Teleport certificate for it yet; open it to log in"
                        : "not checked — its Teleport certificate has expired; open it to log in again")]
        }
        // Per-session MFA: every fresh `tsh kube credentials` is its own ceremony.
        if cred["teleport"].truthy && !mfaHosts.isEmpty {
            let mfaId = kubeInventoryId(cluster: cred["cluster"].string, name: cred["kubeCluster"].kStr)
            if mfaHosts.contains(mfaId) {
                return ["ok": false, "state": "mfa", "ms": 0, "at": .number(Double(nowMs())), "detail": "needs per-session MFA — not checked"]
            }
        }
        let t = nowMs()
        let r = await run(clusterArgs(spec), ["get", "--raw=/readyz", "--request-timeout=10s"], timeout: 20)
        let ms = nowMs() - t
        // kubectl's own words to classify; the rewrite as the fallback detail.
        var s = heartbeatState(ok: r.ok, stdout: r.stdout, stderr: kubePlain(kubeOr(r.rawStderr, r.stderr)))
        if s.state == "error" && !r.stderr.isEmpty {
            s.detail = String((kubePlain(r.stderr).components(separatedBy: "\n").first ?? "").prefix(200))
        }
        return ["ok": .bool(s.state == "ok"), "ms": .number(Double(ms)), "at": .number(Double(nowMs())),
                "state": .string(s.state), "detail": .string(s.detail)]
    }

    /// One login in flight per private kubeconfig file.
    private actor LoginGate {
        var inFlight: [String: Task<(ok: Bool, stderr: String), Never>] = [:]
        func login(_ file: String, _ make: @escaping @Sendable () async -> (ok: Bool, stderr: String)) async -> (ok: Bool, stderr: String) {
            if let t = inFlight[file] { return await t.value }
            let t = Task { await make() }
            inFlight[file] = t
            let v = await t.value
            inFlight[file] = nil
            return v
        }
    }
    private static let kubeLogins = LoginGate()

    /// A heartbeat for a cluster you can use but have not logged in to: the
    /// same `tsh kube login`, into a kubeconfig of the app's own (one per
    /// cluster and tsh home — yours is never touched), then /readyz through it.
    static func heartbeatTeleport(proxy: String?, kubeCluster: String?, home: String? = nil, teleportCluster: String? = nil,
                                  mfaHosts: [String] = []) async -> JSON {
        func at() -> JSON { .number(Double(nowMs())) }
        guard let proxy = proxy?.nilIfEmpty, let kubeCluster = kubeCluster?.nilIfEmpty else {
            return ["ok": false, "state": "error", "detail": "Which cluster?", "ms": 0, "at": at()]
        }
        if !mfaHosts.isEmpty, mfaHosts.contains(kubeInventoryId(cluster: teleportCluster, name: kubeCluster)) {
            return ["ok": false, "state": "mfa", "ms": 0, "at": at(), "detail": "needs per-session MFA — not checked"]
        }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("serverlife-kube-beat-\(getuid())")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var tshEnv = Tools.tshEnv(home: home?.nilIfEmpty ?? Tools.home(forProxy: proxy))
        let effectiveHome = TeleportHomes.expand((tshEnv["TELEPORT_HOME"] ?? nil)?.nilIfEmpty
            ?? ProcessInfo.processInfo.environment["TELEPORT_HOME"]?.nilIfEmpty ?? "~/.tsh")
        let bare = proxy.hasSuffix(":443") ? String(proxy.dropLast(4)) : proxy
        let digest = Insecure.SHA1.hash(data: Data("\(bare)\u{0}\(kubeCluster)\u{0}\(effectiveHome)".utf8))
        let id = String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
        if !teleportLoginGood(home: effectiveHome, proxy: proxy) {
            return ["ok": false, "state": "idle", "detail": "not checked — the Teleport login has expired", "ms": 0, "at": at()]
        }
        let file = (dir as NSString).appendingPathComponent("\(id).yaml")
        tshEnv["TELEPORT_HOME"] = effectiveHome
        tshEnv["KUBECONFIG"] = file
        let env = tshEnv
        func contextOf() -> String {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8),
                  let m = TPText.match(#"^current-context:\s*(\S+)"#, text, .anchorsMatchLines), m.count > 1 else { return "" }
            return m[1] ?? ""
        }
        var fresh = false
        if contextOf().isEmpty {
            let r = await kubeLogins.login(file) {
                let p = await Proc.run(Tools.tsh, ["--proxy=\(proxy)", "kube", "login", kubeCluster], env: env, timeout: 45)
                return (p.ok, kubePlain(p.err))
            }
            if !r.ok {
                let s = heartbeatState(ok: false, stdout: "", stderr: r.stderr)
                return ["ok": false, "state": .string(s.state), "detail": .string(s.detail), "ms": 0, "at": at()]
            }
            fresh = true
        }
        let spec = KubeSpec(contextName: contextOf(), kubeconfigPaths: [file])
        // The first ask also fetches the cluster's certificate; ask once more so the time is the cluster's.
        if fresh { _ = await heartbeat(spec, gate: false) }
        return await heartbeat(KubeSpec(contextName: contextOf(), kubeconfigPaths: [file]), gate: false)
    }

    // MARK: - tctl

    nonisolated(unsafe) private static var tctlPathCache: String?

    /// teleport.js `findTctl`: beside tsh, then PATH, else the bare name.
    static func findTctl() -> String {
        if let c = tctlPathCache { return c }
        let beside = ((Tools.tsh as NSString).deletingLastPathComponent as NSString).appendingPathComponent("tctl")
        if Tools.tsh.contains("/"), FileManager.default.fileExists(atPath: beside) { tctlPathCache = beside; return beside }
        if let w = Proc.which("tctl"), FileManager.default.fileExists(atPath: w) { tctlPathCache = w; return w }
        tctlPathCache = "tctl"
        return "tctl"
    }

    /// teleport.js `tctlRun`: with your own login, on the cluster said outright.
    static func tctlRun(_ args: [String], proxy: String?, home: String?, timeout: TimeInterval = 30) async -> (ok: Bool, stdout: String, stderr: String) {
        let h = home ?? Tools.home(forProxy: proxy)
        var env = Tools.tshEnv(home: h)
        env["TELEPORT_PROXY"] = .some(nil)
        var target: [String] = []
        if let p = proxy?.nilIfEmpty { target = ["--auth-server=" + (TPText.test(#":\d+$"#, p) ? p : p + ":443")] }
        let r = await Proc.run(findTctl(), target + args, env: env, timeout: timeout)
        // A tctl that never started says so (Node's execFile left stderr empty; its error read ENOENT).
        let stderr = r.spawnError.map { "spawn tctl ENOENT: \($0)" } ?? r.err
        return (r.ok, kubePlain(r.out), kubePlain(stderr))
    }

    /// Teleport's own heartbeats for its Kubernetes agents (`tctl get kube_servers`),
    /// one call per Teleport cluster. Age = TTL − time left, the TTL read off the
    /// freshest agent and rounded up to whole five minutes (as for SSH nodes).
    static func kubeAgents(proxy: String?, home: String? = nil) async -> JSON {
        let env = Tools.tshEnv(home: home?.nilIfEmpty ?? Tools.home(forProxy: proxy))
        let effectiveHome = TeleportHomes.expand((env["TELEPORT_HOME"] ?? nil)?.nilIfEmpty
            ?? ProcessInfo.processInfo.environment["TELEPORT_HOME"]?.nilIfEmpty ?? "~/.tsh")
        if !teleportLoginGood(home: effectiveHome, proxy: proxy) { return ["ok": false, "state": "idle", "error": "the Teleport login has expired"] }
        let r = await tctlRun(["get", "kube_servers", "--format=json"], proxy: proxy, home: effectiveHome, timeout: 30)
        if !r.ok {
            if TPText.test(#"ENOENT|not found|command not found"#, r.stderr, .caseInsensitive) && !TPText.test("kube_server", r.stderr, .caseInsensitive) {
                return ["ok": false, "state": "notctl", "error": "tctl is not installed beside tsh"]
            }
            return ["ok": false, "state": "error",
                    "error": .string(r.stderr.components(separatedBy: "\n").first { !$0.trimmed.isEmpty } ?? "tctl get kube_servers failed")]
        }
        guard let list = try? JSON.parse(r.stdout.isEmpty ? "[]" : r.stdout) else {
            return ["ok": false, "state": "error", "error": "Unexpected output from tctl"]
        }
        let now = Double(nowMs())
        struct Agent { var cluster, hostname, hostId, version: String; var leftMs: Double? }
        let agents: [Agent] = list.items.map { s in
            let exp = s["metadata"]["expires"].string?.nilIfEmpty
            return Agent(cluster: kubeOr(s["spec"]["cluster"]["metadata"]["name"].string, s["metadata"]["name"].kStr),
                         hostname: s["spec"]["hostname"].kStr, hostId: s["spec"]["host_id"].kStr, version: s["spec"]["version"].kStr,
                         leftMs: exp.map { (kubeParseDate($0) ?? .nan) - now })
        }.filter { !$0.cluster.isEmpty }
        let maxLeft = agents.map { a -> Double in let l = a.leftMs ?? 0; return l.isNaN ? 0 : l }.reduce(0, max)
        let ttlMs = max(600_000, (maxLeft / 300_000).rounded(.up) * 300_000)
        var clusters: [String: JSON] = [:]
        for a in agents {
            let left: JSON = a.leftMs.map { $0.isNaN ? .null : .number($0) } ?? .null
            let age: JSON = left.double.map { .number(max(0, ttlMs - $0)) } ?? .null
            var arr = clusters[a.cluster]?.array ?? []
            arr.append(["hostname": .string(a.hostname), "hostId": .string(a.hostId), "version": .string(a.version), "ageMs": age, "leftMs": left])
            clusters[a.cluster] = .array(arr)
        }
        return ["ok": true, "at": .number(now), "ttlMs": .number(ttlMs), "clusters": .object(clusters)]
    }

    // MARK: - Provider / Cloud

    /// Which cloud, from the cluster itself, as cheaply as it can be asked:
    /// the server version first, the nodes only when that is not enough.
    static func detectProvider(_ spec: KubeSpec) async -> JSON {
        let ver = await run(clusterArgs(spec), ["version", "-o", "json", "--request-timeout=15s"], timeout: 25)
        let version = (try? JSON.parse(ver.stdout.isEmpty ? "{}" : ver.stdout))?["serverVersion"]["gitVersion"].string ?? ""
        if version.isEmpty { return ["ok": false, "provider": .null, "error": .string(kubeOr(kubePlain(ver.stderr), "Could not reach the cluster"))] }
        var provider = KubeProvider.fromCluster(version: version)
        if provider == nil {
            let nodes = await getRawList(spec, name: "nodes")
            provider = KubeProvider.fromCluster(nodes: nodes["items"].items, version: version)
        }
        return ["ok": true, "provider": provider ?? .null, "version": .string(version)]
    }

    /// What the Cloud view shows: nodes, service accounts, EKS's aws-auth and
    /// the server version — each that the role may not read is said, not fatal.
    static func cloudInfo(_ spec: KubeSpec, provider: JSON? = nil) async -> JSON {
        let k = clusterArgs(spec)
        async let nodesR = getRawList(spec, name: "nodes")
        async let sasR = getRawList(spec, name: "serviceaccounts", namespaced: true)
        async let authR = run(k, ["-n", "kube-system", "get", "configmap", "aws-auth", "-o", "json"], timeout: 20)
        async let verR = run(k, ["version", "-o", "json"], timeout: 20)
        let (nodes, sas, auth, ver) = await (nodesR, sasR, authR, verR)
        let awsAuth: JSON = auth.ok ? ((try? JSON.parse(auth.stdout)) ?? .null) : .null
        let version = (try? JSON.parse(ver.stdout.isEmpty ? "{}" : ver.stdout))?["serverVersion"]["gitVersion"].string ?? ""
        var out = KubeProvider.summarize(provider: provider, nodes: nodes["items"].items, serviceAccounts: sas["items"].items,
                                         awsAuth: awsAuth, version: version)
        out["ok"] = .bool(nodes["ok"].truthy || sas["ok"].truthy)
        out["consoleUrl"] = .string(KubeProvider.consoleUrl(out["provider"], clusterName: spec.kubeClusterName ?? ""))
        out["problems"] = [
            "nodes": nodes["ok"].truthy ? "" : nodes["error"],
            "serviceAccounts": sas["ok"].truthy ? "" : sas["error"],
            // Most EKS clusters now use access entries; a missing aws-auth is ordinary.
            "awsAuth": .string(auth.ok ? "" : (TPText.test(#"NotFound|not found"#, auth.stderr, .caseInsensitive) ? "none" : kubePlain(auth.stderr))),
        ]
        return out
    }
}
