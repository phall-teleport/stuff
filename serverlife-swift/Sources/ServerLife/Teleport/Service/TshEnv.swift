import Foundation

/// Variables for tsh — the port of teleport.js's `parseEnvText`,
/// `setEnvSettings`, `envFor`, `envForShells`, the variable half of
/// `tshEnv(home, proxy)`, `chosenTsh`, `bareProxy`, `proxyInArgs`, `$VAR`
/// expansion in `expandHome`, and main.js's `applyTshEnv`,
/// `teleport:parseEnv` and `teleport:resolveHome`.
///
/// Environment variables to run tsh with, set in Settings: for every cluster,
/// and per cluster on top of that. TELEPORT_TOOLS_VERSION is the reason — one
/// cluster wants its tsh fetched at a particular version, the others do not —
/// but any variable tsh reads can be set this way.
///
/// `Teleport.run` (and everything in Teleport/Service) merges these itself.
/// Other owners starting tsh (Core's `Tools.runTsh`, Connections, Sessions'
/// tsh tabs) should merge `TshEnv.vars(home:proxy:)` into the environment
/// they pass — see the README.
enum TshEnv {
    struct Parsed: Equatable, Sendable {
        /// In the order written; a later line for the same name wins.
        var vars: [String: String]
        var order: [String]
        var errors: [String]
    }

    private struct State {
        var global: [String: String] = [:]
        var byCluster: [String: [String: String]] = [:]   // bare proxy → vars
        var byHome: [String: [String: String]] = [:]      // expanded home → vars
        var inShells = false
    }
    private static let state = TPLocked(State())

    // MARK: - Parsing

    /// `NAME=value` lines — `export NAME="value"` pasted from a shell profile
    /// too. Blank lines and # comments are skipped; anything else that is not
    /// a valid assignment is reported by line rather than half-applied.
    static func parse(_ text: String?) -> Parsed {
        var vars: [String: String] = [:]
        var order: [String] = []
        var errors: [String] = []
        let lines = (text ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmed
            if line.isEmpty || line.hasPrefix("#") { continue }
            let body = line.replacingOccurrences(of: #"^export\s+"#, with: "", options: .regularExpression)
            guard let m = TPText.match(#"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$"#, body), let name = m[1] else {
                errors.append("line \(i + 1): not NAME=value — \(TPText.clip(line, 60))")
                continue
            }
            var v = (m[2] ?? "").trimmed
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if vars[name] == nil { order.append(name) }
            vars[name] = v
        }
        return Parsed(vars: vars, order: order, errors: errors)
    }

    /// `teleport:parseEnv` as JSON: `{ vars, errors }`.
    static func parseJSON(_ text: String?) -> JSON {
        let p = parse(text)
        return ["vars": .object(p.vars.mapValues { .string($0) }), "errors": JSON(p.errors)]
    }

    /// `corp.example.com:443`, `https://corp.example.com/web` → `corp.example.com`.
    static func bareProxy(_ p: String?) -> String {
        (p ?? "").trimmed.lowercased()
            .replacingOccurrences(of: #"^[a-z][a-z0-9+.-]*://"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":443$"#, with: "", options: .regularExpression)
    }

    /// The `--proxy=` a set of arguments carries, if any.
    static func proxyInArgs(_ args: [String]) -> String? {
        for a in args {
            if let m = TPText.match(#"^--proxy[=\s](.+)$"#, a), let v = m[1] { return v }
        }
        return nil
    }

    // MARK: - Settings

    /// From settings: `tshEnvText`, `clusterTshEnv` (proxy → text),
    /// `tshHomeEnv` (home → text) and `tshEnvInShells`.
    static func setSettings(global: String, clusters: [String: String], homesEnv: [String: String], inShells: Bool) {
        var s = State()
        s.global = parse(global).vars
        // Keyed by the path as written; matched by where it points now.
        for (home, text) in homesEnv {
            let vars = parse(text).vars
            let h = expandHome(home)
            if !h.isEmpty, !vars.isEmpty { s.byHome[h] = vars }
        }
        for (proxy, text) in clusters {
            let vars = parse(text).vars
            if !vars.isEmpty { s.byCluster[bareProxy(proxy)] = vars }
        }
        s.inShells = inShells
        state.set(s)
    }

    /// `applyTshEnv(store.settings)`.
    @MainActor
    static func applySettings() {
        let st = Store.shared
        func map(_ key: String) -> [String: String] {
            (st.settings[key].object ?? [:]).compactMapValues { $0.stringish }
        }
        setSettings(global: st.setting("tshEnvText", ""), clusters: map("clusterTshEnv"),
                    homesEnv: map("tshHomeEnv"), inShells: st.setting("tshEnvInShells", false))
    }

    /// A fingerprint of the settings `applySettings` reads, to notice a change.
    @MainActor
    static func settingsFingerprint() -> String {
        let s = Store.shared.settings
        return ["tshEnvText", "clusterTshEnv", "tshHomeEnv", "tshEnvInShells", "tshHomes"]
            .map { s[$0].text() }.joined(separator: "\u{1}")
    }

    // MARK: - Reading

    /// `envFor(proxy)`: the variables a tsh for this cluster runs with:
    /// everyone's, then the cluster's own.
    static func envFor(_ proxy: String?) -> [String: String] {
        let s = state.get()
        var out = s.global
        if let p = proxy?.nilIfEmpty, let c = s.byCluster[bareProxy(p)] { out.merge(c) { $1 } }
        return out
    }

    /// `envForShells()`: what a plain local shell gets — the global variables,
    /// only when Settings says so.
    static func envForShells() -> [String: String] {
        let s = state.get()
        return s.inShells ? s.global : [:]
    }

    /// Stable text for an env, as `JSON.stringify(envFor(proxy))` was used as a cache key.
    static func key(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\u{1}")
    }

    /// The variable half of `tshEnv(home, proxy)`: what to add to the
    /// environment of a tsh run for `home` (nil: the first configured home,
    /// else the default) and `proxy`.
    ///
    /// For every cluster, then this home's, then this cluster's. Then: a tsh
    /// that was chosen — Path to tsh in Settings, or TSH_PATH — is the tsh that
    /// runs. Client-tools managed updates otherwise hand the command to
    /// whichever version they have installed for the cluster: another
    /// version's build called `tsh` reported itself as 18.11.7 and behaved as
    /// it, so picking it changed nothing — Phases never appeared — with no sign
    /// why. Only for a chosen binary: one the app found on its own keeps the
    /// updates, and anyone who sets TELEPORT_TOOLS_VERSION themselves keeps
    /// their own value.
    static func vars(home: String?, proxy: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                     chosen: String? = chosenTsh()) -> [String: String] {
        let s = state.get()
        let h = expandHome(home)
        let effective = !h.isEmpty ? h : (Tools.homes.first ?? TeleportHomes.defaultHome)
        var out = s.global
        if let v = s.byHome[effective] { out.merge(v) { $1 } }
        if let p = proxy?.nilIfEmpty, let v = s.byCluster[bareProxy(p)] { out.merge(v) { $1 } }
        // A chosen tsh runs as itself — unless a tools version was asked for, by
        // the person's environment or by the variables above, which then decides.
        if chosen != nil, out["TELEPORT_TOOLS_VERSION"] == nil, environment["TELEPORT_TOOLS_VERSION"] == nil {
            out["TELEPORT_TOOLS_VERSION"] = "off"
        }
        return out
    }

    /// The whole extra environment for a tsh run: `TELEPORT_HOME` as Core sets
    /// it, plus `vars(home:proxy:)`.
    static func overrides(home: String?, proxy: String?) -> [String: String?] {
        var env = Tools.tshEnv(home: home)
        for (k, v) in vars(home: home, proxy: proxy) { env[k] = .some(v) }
        return env
    }

    // MARK: - The chosen tsh

    /// `chosenTsh()`: the tsh named by Settings or TSH_PATH, if one was — not
    /// one found by searching.
    static func chosenTsh(settingsPath: String? = currentSettingsPath(),
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let p = settingsPath?.trimmed.nilIfEmpty { return p }
        if let p = environment["TSH_PATH"]?.trimmed.nilIfEmpty { return p }
        return nil
    }

    /// `tshChosenFrom`: "settings", "TSH_PATH", or nil — for the reminder at launch.
    static func chosenFrom(settingsPath: String? = currentSettingsPath(),
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if settingsPath?.trimmed.nilIfEmpty != nil { return "settings" }
        if environment["TSH_PATH"]?.trimmed.nilIfEmpty != nil { return "TSH_PATH" }
        return nil
    }

    /// The Settings override as Core holds it (`Tools.tshStatus.override`).
    static func currentSettingsPath() -> String? {
        Tools.tshStatus["override"].string?.nilIfEmpty
    }

    // MARK: - Homes with variables

    /// The `$NAME` / `${NAME}` pattern a home may use.
    static let varPattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#

    /// A home as written in Settings, made a real path: `~`, and `$NAME` or
    /// `${NAME}` from the app's environment — `$TELEPORT_HOME`,
    /// `${WORK}/.tsh` — read each time, so a variable that changes moves the
    /// home with it. One that names an unset variable is no path at all ("")
    /// rather than wherever the leftover text happens to resolve.
    static func expandHome(_ p: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var raw = (p ?? "").trimmed
        if raw.isEmpty { return "" }
        if raw.contains("$") {
            guard let re = try? NSRegularExpression(pattern: varPattern) else { return "" }
            let ns = raw as NSString
            var out = ""
            var last = 0
            var missing = false
            for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let r1 = m.range(at: 1), r2 = m.range(at: 2)
                let name = ns.substring(with: r1.location != NSNotFound ? r1 : r2)
                let v = environment[name] ?? ""
                if v.isEmpty { missing = true }
                out += v
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            if missing { return "" }
            raw = out.trimmed
            if raw.isEmpty { return "" }
        }
        return TeleportSSH.expandHome(raw)
    }

    /// The names a home refers to that are not set now.
    static func unsetVars(_ text: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        TPText.matches(varPattern, text).compactMap { $0[1] ?? $0[2] }
            .filter { (environment[$0] ?? "").isEmpty }
    }

    /// `teleport:resolveHome`: a tsh home as typed — ~, $VAR, ${VAR} — and
    /// where it points now, for the Add a tsh home dialog.
    struct ResolvedHome: Equatable, Sendable {
        var raw: String
        var resolved: String
        var exists: Bool
        var profiles: Int
        var unset: [String]
    }

    static func resolveHome(_ text: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedHome {
        let raw = (text ?? "").trimmed
        let resolved = expandHome(raw, environment: environment)
        var exists = false
        var profiles = 0
        if !resolved.isEmpty {
            var dir: ObjCBool = false
            exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &dir) && dir.boolValue
            profiles = ((try? FileManager.default.contentsOfDirectory(atPath: resolved)) ?? [])
                .filter { $0.hasSuffix(".yaml") }.count
        }
        return ResolvedHome(raw: raw, resolved: resolved, exists: exists, profiles: profiles,
                            unset: unsetVars(raw, environment: environment))
    }
}
