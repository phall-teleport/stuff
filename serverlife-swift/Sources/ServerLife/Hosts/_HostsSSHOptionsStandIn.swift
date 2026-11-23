import Foundation

// Stand-in for the main-process half of SSH options (src/main/sshoptions.js
// and main.js `sshOptionsRecord` / `sshopts:*`), which belongs to
// connections. The dialog and menu in this directory need it now: checking,
// summarising, building the command line, and keeping a host's default and
// named presets in settings.sshOptionsHosts[hostPrefKey]. Pure (apart from
// the record helpers), so it is tested here. When connections publishes its
// own (and applies the default when a session is dialled), point these at it
// and delete this file.

enum HostsSSHOpts {
    static let x11Modes = ["off", "untrusted", "trusted"]
    static let requestModes = ["", "off", "resource", "role"]

    /// Options as stored: every field present, every value checked.
    struct Options: Equatable, Sendable {
        var x11 = "off"
        var localForwards: [String] = []
        var remoteForwards: [String] = []
        var dynamicForwards: [String] = []
        var jumpHost = ""
        var reason = ""
        var invite: [String] = []
        var requestMode = ""
        var requestReason = ""
        var noResume = false
        /// -N: forwards only, no shell — a tunnel rather than a session.
        var noShell = false
        var extraOptions: [String] = []

        var json: JSON {
            ["x11": .string(x11),
             "localForwards": .array(localForwards.map { .string($0) }),
             "remoteForwards": .array(remoteForwards.map { .string($0) }),
             "dynamicForwards": .array(dynamicForwards.map { .string($0) }),
             "jumpHost": .string(jumpHost), "reason": .string(reason),
             "invite": .array(invite.map { .string($0) }),
             "requestMode": .string(requestMode), "requestReason": .string(requestReason),
             "noResume": .bool(noResume), "noShell": .bool(noShell),
             "extraOptions": .array(extraOptions.map { .string($0) })]
        }
    }

    struct Checked: Sendable {
        var options: Options
        var errors: [String]
        var warnings: [String]
    }

    // MARK: Forwards

    /*
     * A forward as ssh writes it. Local and remote have four shapes:
     *   [bind:]port:host:hostport            a classic network forward
     *   [bind:]port:local_socket             a port bridged to a Unix-domain socket
     *   local_socket:host:hostport           a Unix-domain socket bridged to a network target
     *   local_socket:remote_socket           socket to socket
     * `bind` may be a literal host/IP, `*` for every interface, or omitted (a
     * leading bare `:` also means "every interface"). Dynamic (SOCKS)
     * forwards are just `[bind:]port`.
     */
    private static let port = "[0-9]{1,5}"
    private static let host = #"(?:\[[0-9a-fA-F:.]+\]|[A-Za-z0-9._-]+)"#
    // '*', a literal host/IP, or nothing at all — ":9000:host:port" is fine by ssh.
    private static let bind = #"(?:\*|"# + host + ")?"
    // An absolute Unix-domain socket path, no colon or whitespace.
    private static let sock = #"(?:/[^:\s]+)"#

    private static func re(_ s: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: s)
    }

    private static let fwdForms: [NSRegularExpression] = [
        re("^(?:\(bind):)?(\(port)):\(host):(\(port))$"),
        re("^(?:\(bind):)?(\(port)):\(sock)$"),
        re("^\(sock):\(host):(\(port))$"),
        re("^\(sock):\(sock)$"),
    ]
    private static let dynRe = re("^(?:\(bind):)?(\(port))$")
    // One -J hop: [user@]host[:port]. A chain is these, comma-separated.
    private static let jumpHopRe = re(#"^(?:[^@,\s]+@)?(?:\[[0-9a-fA-F:.]+\]|[^,:\s]+)(?::"# + port + ")?$")
    private static let extraRe = re(#"^([A-Za-z][A-Za-z0-9]*)\s*[= ]\s*(\S.*)$"#)

    /// The capture groups of a whole-string match, nil when it does not match.
    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<max(1, m.numberOfRanges)).compactMap { i in
            let rg = m.range(at: i)
            return rg.location == NSNotFound ? nil : ns.substring(with: rg)
        }
    }

    private static func portOk(_ p: String) -> Bool {
        guard let n = Int(p) else { return false }
        return n >= 1 && n <= 65535
    }

    static func checkForward(_ spec: String, kind: String) -> String? {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if kind == "dynamic" {
            guard let g = groups(dynRe, s) else {
                return "\"\(s)\" is not a SOCKS port — write 1080, 127.0.0.1:1080, or *:1080 for every interface"
            }
            return g.allSatisfy(portOk) ? nil : "\"\(s)\": port must be 1-65535"
        }
        for r in fwdForms {
            guard let g = groups(r, s) else { continue }
            return g.filter { !$0.isEmpty }.allSatisfy(portOk) ? nil : "\"\(s)\": port must be 1-65535"
        }
        return "\"\(s)\" is not a forward — write port:host:port (8080:localhost:80), *:port:host:port to bind every interface, or a path for a Unix-domain socket"
    }

    /// One hop or a comma-separated chain, as OpenSSH's -J accepts.
    static func checkJumpHost(_ spec: String) -> String? {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let hops = s.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if hops.contains(where: { $0.isEmpty }) { return "Jump host: remove the empty hop — check for a stray comma" }
        if hops.contains(where: { groups(jumpHopRe, $0) == nil }) {
            return "Jump host: one or more hops as user@host[:port] — comma-separated for a chain, e.g. bastion1,user@bastion2:2222"
        }
        return nil
    }

    /// ssh_config directive names (KNOWN_SSH_OPTIONS); an unknown one is a warning, not an error.
    static let knownOptions: Set<String> = [
        "addkeystoagent", "addressfamily", "batchmode", "bindaddress", "bindinterface",
        "canonicaldomains", "canonicalizefallbacklocal", "canonicalizehostname",
        "canonicalizemaxdots", "canonicalizepermittedcnames", "casignaturealgorithms",
        "certificatefile", "channeltimeout", "checkhostip", "ciphers", "clearallforwardings",
        "compression", "connectionattempts", "connecttimeout", "controlmaster", "controlpath",
        "controlpersist", "dynamicforward", "enableescapecommandline", "enablesshkeysign",
        "escapechar", "exitonforwardfailure", "fingerprinthash", "forkafterauthentication",
        "forwardagent", "forwardx11", "forwardx11timeout", "forwardx11trusted", "gatewayports",
        "globalknownhostsfile", "gssapiauthentication", "gssapidelegatecredentials",
        "hashknownhosts", "hostbasedacceptedalgorithms", "hostbasedauthentication",
        "hostkeyalgorithms", "hostkeyalias", "hostname", "identitiesonly", "identityagent",
        "identityfile", "ignoreunknown", "include", "ipqos", "kbdinteractiveauthentication",
        "kbdinteractivedevices", "kexalgorithms", "knownhostscommand", "localcommand",
        "localforward", "loglevel", "logverbose", "macs", "match", "nohostauthenticationforlocalhost",
        "numberofpasswordprompts", "obscurekeystroketiming", "passwordauthentication",
        "permitlocalcommand", "permitremoteopen", "pkcs11provider", "port",
        "preferredauthentications", "proxycommand", "proxyjump", "proxyusefdpass",
        "pubkeyacceptedalgorithms", "pubkeyacceptedkeytypes", "pubkeyauthentication",
        "rekeylimit", "remotecommand", "remoteforward", "requesttty", "requiredrsasize",
        "revokedhostkeys", "securitykeyprovider", "sendenv", "serveralivecountmax",
        "serveraliveinterval", "sessiontype", "setenv", "stdinnull", "streamlocalbindmask",
        "streamlocalbindunlink", "stricthostkeychecking", "syslogfacility", "tcpkeepalive",
        "tunnel", "tunneldevice", "updatehostkeys", "user", "userknownhostsfile",
        "verifyhostkeydns", "visualhostkey", "xauthlocation",
    ]

    /// `list`: an array as is, or text split on newlines and commas.
    static func list(_ v: JSON) -> [String] {
        let raw: [String]
        if case .array(let a) = v {
            raw = a.map { $0.stringish ?? "" }
        } else {
            let s = v.truthy ? (v.stringish ?? "") : ""
            raw = s.components(separatedBy: CharacterSet(charactersIn: "\n,"))
        }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func str(_ v: JSON) -> String {
        (v.truthy ? (v.stringish ?? "") : "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalize(_ raw: JSON) -> Checked {
        var errors: [String] = []
        var warnings: [String] = []
        var o = Options()
        if let x = raw["x11"].string, x11Modes.contains(x) { o.x11 = x }
        o.localForwards = list(raw["localForwards"])
        o.remoteForwards = list(raw["remoteForwards"])
        o.dynamicForwards = list(raw["dynamicForwards"])
        o.jumpHost = str(raw["jumpHost"])
        o.reason = str(raw["reason"])
        o.invite = list(raw["invite"])
        if let m = raw["requestMode"].string, requestModes.contains(m) { o.requestMode = m }
        o.requestReason = str(raw["requestReason"])
        o.noResume = raw["noResume"].truthy
        o.noShell = raw["noShell"].truthy
        o.extraOptions = list(raw["extraOptions"])
        for f in o.localForwards { if let e = checkForward(f, kind: "local") { errors.append("Local forward: \(e)") } }
        for f in o.remoteForwards { if let e = checkForward(f, kind: "remote") { errors.append("Remote forward: \(e)") } }
        for f in o.dynamicForwards { if let e = checkForward(f, kind: "dynamic") { errors.append("SOCKS proxy: \(e)") } }
        if let e = checkJumpHost(o.jumpHost) { errors.append(e) }
        for x in o.extraOptions {
            guard let g = groups(extraRe, x), let name = g.first else {
                errors.append("Option \"\(x)\": write Name=value, for example ServerAliveInterval=30")
                continue
            }
            if !knownOptions.contains(name.lowercased()) {
                warnings.append("Option \"\(name)\" is not a recognized ssh_config directive — check for a typo")
            }
        }
        for u in o.invite where u.contains(where: { $0.isWhitespace }) {
            errors.append("Invite \"\(u)\": one Teleport user per entry")
        }
        return Checked(options: o, errors: errors, warnings: warnings)
    }

    /// Whether anything differs from a plain session.
    static func isEmpty(_ raw: JSON) -> Bool {
        let n = normalize(raw).options
        return n.x11 == "off" && n.localForwards.isEmpty && n.remoteForwards.isEmpty && n.dynamicForwards.isEmpty
            && n.jumpHost.isEmpty && n.reason.isEmpty && n.invite.isEmpty && n.requestMode.isEmpty
            && n.requestReason.isEmpty && !n.noResume && !n.noShell && n.extraOptions.isEmpty
    }

    /// Options only `tsh ssh` understands; a Teleport host with any of these is opened over tsh.
    static func needsTsh(_ raw: JSON) -> Bool {
        let n = normalize(raw).options
        return !n.reason.isEmpty || !n.invite.isEmpty || !n.requestMode.isEmpty || !n.requestReason.isEmpty || n.noResume
    }

    private static func commonArgs(_ n: Options) -> [String] {
        var args: [String] = []
        for f in n.localForwards { args += ["-L", f] }
        for f in n.remoteForwards { args += ["-R", f] }
        for f in n.dynamicForwards { args += ["-D", f] }
        if !n.jumpHost.isEmpty { args += ["-J", n.jumpHost] }
        for x in n.extraOptions {
            // `x.replace(/\s*[= ]\s*/, '=')` — the first separator only.
            let r = re(#"\s*[= ]\s*"#)
            let ns = x as NSString
            if let m = r.firstMatch(in: x, range: NSRange(location: 0, length: ns.length)) {
                args += ["-o", ns.replacingCharacters(in: m.range, with: "=")]
            } else {
                args += ["-o", x]
            }
        }
        return args
    }

    /// Flags for the OpenSSH master. X11 is added by the connection itself.
    static func opensshArgs(_ raw: JSON) -> [String] { commonArgs(normalize(raw).options) }

    /// Flags for `tsh ssh`, before the target. X11 is added by the connection.
    static func tshArgs(_ raw: JSON) -> [String] {
        let n = normalize(raw).options
        var args = commonArgs(n)
        if !n.reason.isEmpty { args.append("--reason=" + n.reason) }
        if !n.invite.isEmpty { args.append("--invite=" + n.invite.joined(separator: ",")) }
        if !n.requestMode.isEmpty { args.append("--request-mode=" + n.requestMode) }
        if !n.requestReason.isEmpty { args.append("--request-reason=" + n.requestReason) }
        if n.noResume { args.append("--no-resume") }
        return args
    }

    /// Short lines saying what is set, for a menu.
    static func summary(_ raw: JSON) -> [String] {
        let n = normalize(raw).options
        var out: [String] = []
        if n.x11 != "off" { out.append("X11 \(n.x11)") }
        for f in n.localForwards { out.append("-L \(f)") }
        for f in n.remoteForwards { out.append("-R \(f)") }
        for f in n.dynamicForwards { out.append("SOCKS \(f)") }
        if !n.jumpHost.isEmpty { out.append("via \(n.jumpHost)") }
        if !n.reason.isEmpty { out.append("reason: \(n.reason)") }
        if !n.invite.isEmpty { out.append("invites \(n.invite.joined(separator: ", "))") }
        if !n.requestMode.isEmpty { out.append("auto request: \(n.requestMode)") }
        if n.noResume { out.append("no resume") }
        if n.noShell { out.append("no shell (-N)") }
        for x in n.extraOptions { out.append("-o \(x)") }
        return out
    }

    /// One argument for a POSIX shell, quoted only when it needs it.
    static func shq(_ v: String) -> String {
        if !v.isEmpty, v.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-").contains($0) }) {
            return v
        }
        return "'" + v.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `commandLine`: the command a person would type for this host with these options.
    static func commandLine(host: JSON, login: String?, options: JSON) -> String {
        let n = normalize(options).options
        let x11 = n.x11 == "trusted" ? ["-Y"] : n.x11 == "untrusted" ? ["-X"] : []
        let nj = n.json
        let at = login?.nilIfEmpty.map { $0 + "@" } ?? ""
        func s(_ k: String) -> String? { host[k].truthy ? host[k].stringish : nil }
        if host["type"].string == "teleport" {
            var args = ["tsh"]
            if let p = s("proxy") { args.append("--proxy=" + p) }
            args.append("ssh")
            if let c = s("cluster") { args.append("--cluster=" + c) }
            args += x11 + tshArgs(nj) + (n.noShell ? ["-N"] : [])
            args.append(at + (s("hostname") ?? s("name") ?? "undefined"))
            return args.map(shq).joined(separator: " ")
        }
        var args = ["ssh"]
        if let f = s("configFile") { args += ["-F", f] }
        args += x11 + opensshArgs(nj) + (n.noShell ? ["-N"] : [])
        let name = s("alias") ?? (host["direct"]["hostname"].truthy ? host["direct"]["hostname"].stringish : nil) ?? s("name") ?? "undefined"
        args.append(at + name)
        return args.map(shq).joined(separator: " ")
    }

    // MARK: The saved record (settings.sshOptionsHosts)

    struct Preset: Sendable {
        var name: String
        var options: JSON
    }

    struct Record: Sendable {
        var defaultOptions: JSON?
        var presets: [Preset]
    }

    /// `sshOptionsRecord` / renderer `savedFor`.
    @MainActor
    static func record(_ host: Host) -> Record {
        let rec = Store.shared.settingJSON("sshOptionsHosts")[host.prefKey]
        let def = rec["default"].truthy ? rec["default"] : nil
        var presets: [Preset] = []
        if case .array(let a) = rec["presets"] {
            presets = a.map { Preset(name: $0["name"].stringish ?? "", options: $0["options"]) }
        }
        return Record(defaultOptions: def, presets: presets)
    }

    /// `sshopts:save`. Returns the errors that stopped it, empty when saved.
    @MainActor @discardableResult
    static func save(_ host: Host, asDefault: Bool = false, presetName: String? = nil, options: JSON? = nil,
                     clearDefault: Bool = false, deletePreset: String? = nil) throws -> [String] {
        let key = host.prefKey
        if key.isEmpty { throw AppError("This host cannot have saved options") }
        var all = Store.shared.settingJSON("sshOptionsHosts").entries
        var rec = all[key] ?? [:]
        if !rec["default"].truthy { rec["default"] = .null }
        var presets = rec["presets"].items
        if clearDefault { rec["default"] = .null }
        if let d = deletePreset { presets = presets.filter { $0["name"].string != d } }
        if let options {
            let c = normalize(options)
            if !c.errors.isEmpty { return c.errors }
            let o = c.options.json
            if asDefault { rec["default"] = isEmpty(o) ? .null : o }
            if let presetName {
                let name = String(presetName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                presets = presets.filter { $0["name"].string != name } + [["name": .string(name), "options": o]]
            }
        }
        rec["presets"] = .array(presets)
        if !rec["default"].truthy && presets.isEmpty { all[key] = nil } else { all[key] = rec }
        Store.shared.updateSettings(["sshOptionsHosts": .object(all)])
        return []
    }
}
