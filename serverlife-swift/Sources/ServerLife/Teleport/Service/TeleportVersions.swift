import Foundation

/// Client and cluster versions, the login-page methods of a proxy, the
/// deliberate-logout registry, and the inventory ids of requestable
/// resources: teleport.js's `majorOf`, `compatibility`,
/// `parseVersionWarning`, `versionInfo`, `compatFor`, `inventoryNodeIds`,
/// `kubeInventoryId`, `inventoryKubeIds`, main.js's `teleport:loginMethods`,
/// and teleportpanel.js's `deliberateLogouts`.
extension Teleport {
    // MARK: - Versions

    static func majorOf(_ v: String?) -> Int? {
        guard let v, let m = TPText.match(#"^v?(\d+)\."#, v), let s = m[1] else { return nil }
        return Int(s)
    }

    struct Compatibility: Equatable, Sendable {
        /// "ok" | "warn" (works, unsupported) | "error" (expected to fail) |
        /// "unknown" (either version could not be read).
        var level: String
        var client: String?
        var server: String?
        var message: String?
        var json: JSON {
            ["level": .string(level), "client": JSON(client), "server": JSON(server), "message": JSON(message)]
        }
    }

    /// Whether this tsh is one the cluster supports, in Teleport's own terms.
    ///
    /// A cluster supports clients of its own major version and of the one
    /// before it — nothing newer, nothing older. tsh only says so once, as a
    /// warning during `tsh login`, and then carries on; every later command is
    /// silent. A client a major ahead works today but tsh announces that future
    /// versions will refuse, and one two majors ahead already cannot log in
    /// (seen: 18 against 16 fails with "ssh: no key found", which says nothing
    /// about versions). So the verdict has to be worked out here, where it can
    /// be shown.
    static func compatibility(client: String?, server: String?) -> Compatibility {
        guard let c = majorOf(client), let s = majorOf(server) else {
            return Compatibility(level: "unknown", client: client, server: server, message: nil)
        }
        let cl = client ?? "", sv = server ?? ""
        if c == s || c == s - 1 { return Compatibility(level: "ok", client: client, server: server, message: nil) }
        let fix = "Install tsh \(s).x, or turn on managed client updates for the cluster."
        if c == s + 1 {
            return Compatibility(level: "warn", client: client, server: server, message:
                "tsh \(cl) is newer than this cluster (Teleport \(sv)), which supports clients up to \(s).x. "
                + "It works for now, but tsh warns that future versions will refuse. \(fix)")
        }
        return Compatibility(level: "error", client: client, server: server, message: c > s
            ? "tsh \(cl) is \(c - s) major versions ahead of this cluster (Teleport \(sv)); logins and sessions are expected to fail. \(fix)"
            : "tsh \(cl) is too old for this cluster (Teleport \(sv)), which needs \(s - 1).x or newer. \(fix)")
    }

    struct VersionWarning: Equatable, Sendable {
        /// "client-newer" | "client-older" | "unknown".
        var direction: String
        var serverLimit: String?
        var client: String?
        var text: String
        var json: JSON {
            ["direction": .string(direction), "serverLimit": JSON(serverLimit), "client": JSON(client), "text": .string(text)]
        }
    }

    /// The incompatibility warning tsh prints during login, if it printed one.
    ///
    /// Kept alongside `compatibility` rather than instead of it: this is tsh's
    /// own word, so it is shown as tsh said it.
    static func parseVersionWarning(_ text: String) -> VersionWarning? {
        let t = TPText.plain(text)
        guard TPText.test("incompatible client and server versions", t, .caseInsensitive) else { return nil }
        let max = TPText.match(#"Maximum client version supported by the server is (\S+) but you are using (\S+?)\.?\s"#, t, .caseInsensitive)
        let min = TPText.match(#"Minimum client version supported by the server is (\S+) but you are using (\S+?)\.?\s"#, t, .caseInsensitive)
        let m = max ?? min
        var tail = t
        if let r = t.range(of: "Detected potentially incompatible", options: .caseInsensitive) {
            tail = String(t[r.lowerBound...])
        } else {
            // JS `slice(search(...))` with -1 is slice(-1): the last character.
            tail = t.isEmpty ? "" : String(t.suffix(1))
        }
        let first = tail.range(of: #"\n\s*\n"#, options: .regularExpression).map { String(tail[..<$0.lowerBound]) } ?? tail
        return VersionWarning(direction: max != nil ? "client-newer" : (min != nil ? "client-older" : "unknown"),
                              serverLimit: m?[1] ?? nil, client: m?[2] ?? nil, text: first.trimmed)
    }

    /// Both sides of it for one profile: `tsh version` reports the proxy's
    /// version alongside its own when it can reach one.
    static func versionInfo(proxy: String?, home: String?) async -> (client: String?, server: String?) {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["version", "--format=json"]
        // Short: this is asked on the way to reporting a failure, and an
        // unreachable proxy must not hold that failure up for long.
        let r = await run(args, home: home, timeout: 8)
        guard let j = try? JSON.parse(r.out.trimmed.isEmpty ? "{}" : r.out) else { return (nil, nil) }
        return (j["version"].string?.nilIfEmpty, j["proxyVersion"].string?.nilIfEmpty)
    }

    private static let compatCache = TPLocked([String: (at: Double, value: Compatibility)]())
    private static let compatTTL: Double = 10 * 60 * 1000

    /// `compatibility` for a profile, remembered for ten minutes per proxy and
    /// home: the cluster's version changes on upgrade day, not between two
    /// clicks. An unreadable server version is not cached: it is usually "not
    /// logged in yet", which the next call after a login should not be stuck with.
    static func compatFor(proxy: String?, home: String?, refresh: Bool = false) async -> Compatibility {
        let key = "\(home ?? "")|\(proxy ?? "")"
        if !refresh, let hit = compatCache.get()[key], nowMs() - hit.at < compatTTL { return hit.value }
        let (client, server) = await versionInfo(proxy: proxy, home: home)
        let value = compatibility(client: client, server: server)
        if value.level != "unknown" { compatCache.mutate { $0[key] = (nowMs(), value) } }
        return value
    }

    // MARK: - Login with its verdict

    struct LoginResult: Sendable {
        var result: ProcResult
        /// tsh's own incompatibility warning, which it prints only to a terminal.
        var versionWarning: VersionWarning?
        var compat: Compatibility?
        var ok: Bool { result.ok }
    }

    /// `login` as teleport.js now returns it: tsh's version warning goes to
    /// the terminal and nowhere else, and a login run here has no terminal —
    /// so both the warning and the verdict travel with the result; on a failed
    /// login the verdict is the likeliest explanation the caller has.
    static func loginChecked(_ o: LoginOptions) async -> LoginResult {
        let r = await login(o)
        let warning = parseVersionWarning("\(r.out)\n\(r.err)")
        let compat = await compatFor(proxy: o.proxy, home: o.home, refresh: true)
        return LoginResult(result: r, versionWarning: warning, compat: compat)
    }

    // MARK: - Deliberate logouts

    private static let deliberateLogouts = TPLocked(Set<String>())

    private static func logoutKey(_ proxy: String?, _ home: String?) -> String {
        var h = TeleportHomes.expand(home)
        if h.isEmpty { h = TeleportHomes.expand(TeleportHomes.home(forProxy: proxy)) }
        if h.isEmpty { h = TeleportHomes.defaultHome }
        return "\(proxyAddress(proxy))|\(h)"
    }

    /// A cluster just told to log out of, so the one *background* caller of
    /// the sessions relogin (a still-attached tmux pane quietly healing its
    /// file channel on a timer) does not immediately log straight back in and
    /// undo it. Every other caller — a double-click on a host, "Reconnect",
    /// opening a tmux session — is a person asking to connect right now, which
    /// outranks this. Cleared the moment this exact proxy/home is logged into
    /// again.
    static func wasLoggedOutDeliberately(proxy: String?, home: String?) -> Bool {
        deliberateLogouts.get().contains(logoutKey(proxy, home))
    }

    static func noteDeliberateLogout(proxy: String?, home: String?) {
        let k = logoutKey(proxy, home)
        deliberateLogouts.mutate { _ = $0.insert(k) }
    }

    static func noteLoggedIn(proxy: String?, home: String?) {
        let k = logoutKey(proxy, home)
        deliberateLogouts.mutate { _ = $0.remove(k) }
    }

    // MARK: - Login methods

    struct LoginMethods: Equatable, Sendable {
        struct Provider: Equatable, Sendable { var name: String; var type: String; var display: String }
        var ok: Bool
        var error: String?
        var authType: String?
        var defaultConnector = ""
        var local = true
        var passwordless = false
        var secondFactors: [String] = []
        var providers: [Provider] = []
    }

    /// The pure half of `teleport:loginMethods`: the web UI's `config.js`.
    static func parseLoginMethods(_ text: String) -> LoginMethods {
        var auth = JSON.object([:])
        if let m = TPText.match(#"GRV_CONFIG\s*=\s*(\{[\s\S]*?\});?\s*$"#, text, .anchorsMatchLines), let body = m[1],
           let j = try? JSON.parse(body) {
            auth = j["auth"].object != nil ? j["auth"] : .object([:])
        }
        return LoginMethods(
            ok: true, error: nil, authType: auth["authType"].string?.nilIfEmpty,
            defaultConnector: auth["defaultConnectorName"].string ?? "",
            local: auth["localAuthEnabled"] != .bool(false),
            passwordless: auth["allowPasswordless"].truthy,
            secondFactors: auth["second_factors"].items.compactMap(\.stringish),
            providers: auth["providers"].items.map {
                let name = $0["name"].stringish ?? ""
                return LoginMethods.Provider(name: name, type: $0["type"].stringish ?? "",
                                             display: $0["displayName"].string?.nilIfEmpty ?? name)
            })
    }

    /// `teleport:loginMethods`: how a proxy can be logged into, as its own
    /// login page knows it: the SSO providers, whether local users and
    /// passwordless are allowed, the default. Read from the web UI's config —
    /// public, no certificate needed — so a cluster can be set up before
    /// anyone has logged into it.
    static func loginMethods(proxy: String?) async -> LoginMethods {
        let host = (proxy ?? "").trimmed
            .replacingOccurrences(of: #"^[a-z][a-z0-9+.-]*://"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
        if host.isEmpty { return LoginMethods(ok: false, error: "No proxy") }
        guard let url = URL(string: "https://\(host)/web/config.js") else { return LoginMethods(ok: false, error: "Invalid URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return parseLoginMethods(String(decoding: data, as: UTF8.self))
        } catch {
            return LoginMethods(ok: false, error: error.localizedDescription)
        }
    }

    // MARK: - Inventory ids of requestable resources

    /// The id a requestable node will carry once it is granted and shows up in
    /// `listNodes`'s inventory — worked out ahead of the grant from the
    /// cluster + uuid a search result already carries, so a node can be marked
    /// "needs MFA" before access even exists. Keyed by the search result's own
    /// `id` (its ResourceID).
    static func inventoryNodeIds(_ items: [(id: String, cluster: String, uuid: String)], home: String?) -> [String: String] {
        var out: [String: String] = [:]
        let def = TeleportHomes.isDefault(home), name = TeleportHomes.name(home)
        for it in items where !it.id.isEmpty && !it.uuid.isEmpty {
            out[it.id] = def ? "tsh:\(it.cluster):\(it.uuid)" : "tsh:\(name.isEmpty ? (home ?? "") : name):\(it.cluster):\(it.uuid)"
        }
        return out
    }

    /// The id a requestable kube cluster will carry once granted — keyed by
    /// name, not uuid, because a kube_cluster resource has no uuid. A distinct
    /// `tsh-kube:` prefix means this can never collide with a node id.
    static func kubeInventoryId(cluster: String?, name: String, home: String?) -> String {
        TeleportHomes.isDefault(home)
            ? "tsh-kube:\(cluster ?? ""):\(name)"
            : "tsh-kube:\(TeleportHomes.name(home).nilIfEmpty ?? home ?? ""):\(cluster ?? ""):\(name)"
    }

    static func inventoryKubeIds(_ items: [(id: String, cluster: String, name: String)], home: String?) -> [String: String] {
        var out: [String: String] = [:]
        for it in items where !it.id.isEmpty && !it.name.isEmpty {
            out[it.id] = kubeInventoryId(cluster: it.cluster, name: it.name, home: home)
        }
        return out
    }
}
