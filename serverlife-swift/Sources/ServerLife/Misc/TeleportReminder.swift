import Foundation

/// index.js `remindCustomTeleport`: say so at launch when this is not the
/// usual Teleport set-up — a tsh picked by hand, extra tsh homes, variables
/// set for tsh. Each is easy to set for an afternoon's testing and forget,
/// and changes what every cluster in the list is read through. A picked tsh
/// that will not even run (macOS kills a tsh copied out of its tsh.app) says
/// that instead, since otherwise the list is just empty with no reason given.
@MainActor
enum MiscTeleportReminder {
    /// main.js `tshChosen`/`tshChosenFrom`: Settings' path first, then TSH_PATH.
    static func chosen(_ s: JSON, env: [String: String] = ProcessInfo.processInfo.environment) -> (path: String, from: String)? {
        if let p = s["tshPath"].string?.trimmed, !p.isEmpty { return (p, "settings") }
        if let p = env["TSH_PATH"]?.trimmed, !p.isEmpty { return (p, "TSH_PATH") }
        return nil
    }

    /// The message's lines and kind, or nil when there is nothing to say.
    static func message(settings s: JSON, chosen: (path: String, from: String)?, version: String?) -> (text: String, kind: StatusBus.Kind)? {
        let homes = s["tshHomes"].stringArray.filter { !$0.isEmpty }
        var lines: [String] = []
        var kind = StatusBus.Kind.info
        if let c = chosen {
            let whereText = c.from == "TSH_PATH" ? "TSH_PATH" : "Settings"
            if let v = version {
                lines.append("Using a custom tsh (\(whereText)): \(c.path) — v\(v).")
            } else {
                kind = .error
                lines.append("The custom tsh (\(whereText)) at \(c.path) did not run — nothing can be read through it. "
                             + "On a Mac a tsh copied out of tsh.app is stopped by macOS; use tsh.app/Contents/MacOS/tsh.")
            }
        }
        if !homes.isEmpty { lines.append("Reading Teleport homes: \(homes.joined(separator: ", ")).") }
        // Variables set for tsh: for every cluster, and the clusters with their own.
        let globalVars = MiscTshEnv.names(s["tshEnvText"].string)
        if !globalVars.isEmpty { lines.append("tsh runs with \(globalVars.joined(separator: ", ")) for every cluster.") }
        let perCluster = s["clusterTshEnv"].entries.sorted { $0.key < $1.key }
            .compactMap { k, v -> String? in
                let n = MiscTshEnv.names(v.string)
                return n.isEmpty ? nil : "\(k) (\(n.joined(separator: ", ")))"
            }
        if !perCluster.isEmpty { lines.append("…and its own for \(perCluster.joined(separator: "; ")).") }
        if lines.isEmpty { return nil }
        lines.append("Settings → Teleport homes → Locate tsh / ssh… to change.")
        return (lines.joined(separator: "\n"), kind)
    }

    /// Once, at launch, after the settings are loaded.
    static func run() {
        if CommandLine.arguments.contains("--snapshot") { return }
        let s = Store.shared.settings
        let c = chosen(s)
        Task {
            var version: String?
            if c != nil {
                let r = await Tools.runTsh(["version", "--client"], timeout: 10)
                if let m = r.out.range(of: #"Teleport\s+v([0-9][0-9A-Za-z.\-]*)"#, options: .regularExpression) {
                    version = String(r.out[m]).replacingOccurrences(of: #"Teleport\s+v"#, with: "", options: .regularExpression)
                }
            }
            await MainActor.run {
                guard let m = message(settings: s, chosen: c, version: version) else { return }
                StatusBus.shared.toast(m.text, kind: m.kind, seconds: m.kind == .error ? 20 : 12)
            }
        }
    }
}
