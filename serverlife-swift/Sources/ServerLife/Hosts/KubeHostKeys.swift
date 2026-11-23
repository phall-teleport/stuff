import Foundation

/// folders.js `migrateKubeHostKeys(hosts)` (0.39).
///
/// A Kubernetes cluster used to be keyed by its row's id — the context's id
/// once logged in, `avail:…` before — so a cluster watched, coloured or filed
/// under one came back bare as the other, and every one of those settings was
/// written under the old ids. Each is moved to the cluster's key the first
/// time its row is drawn. Exact matches only, and an entry already under the
/// new key wins: nothing is overwritten.
///
/// Called by kube-ui as its cluster rows are drawn (kubepanel.js), through
/// the `hosts-migrate-kube-keys` action (args `hosts` [JSON]) or directly.
@MainActor
enum KubeHostKeys {
    private static var migrated = Set<String>()

    /// `renameKey(v, from, to)`: arrays have the string replaced (or dropped
    /// when `to` is already there); objects have the key moved, recursively.
    nonisolated static func renameKey(_ v: JSON, from: String, to: String) -> JSON {
        if case .array(let a) = v {
            guard a.contains(.string(from)) else { return v }
            return a.contains(.string(to)) ? .array(a.filter { $0 != .string(from) })
                                            : .array(a.map { $0 == .string(from) ? .string(to) : $0 })
        }
        guard case .object(let o) = v else { return v }
        var out = o
        if let moved = o[from] {
            if o[to] == nil {
                var m = moved
                if case .object = moved, moved["key"].string == from { m["key"] = .string(to) }
                out[to] = m
            }
            out.removeValue(forKey: from)
        }
        for (k, child) in out {
            let next = renameKey(child, from: from, to: to)
            if next != child { out[k] = next }
        }
        return .object(out)
    }

    /// The (from, to) pairs for these rows not yet migrated in this run.
    static func pairs(_ hosts: [JSON]) -> [(String, String)] {
        var pairs: [(String, String)] = []
        for h in hosts {
            guard h["kind"].string == "kube", let id = h["id"].string, !id.isEmpty else { continue }
            let to = Store.hostPrefKey(h)
            // Two legacy forms to move off of: the row's own raw id, and the
            // groupKey-based key hostKey() used before it preferred the
            // Teleport cluster's name.
            var legacy: [String] = [id]
            if let g = h["groupKey"].string, !g.isEmpty, h["name"].truthy {
                legacy.append("kube:\(g):\(h["name"].stringish ?? "")")
            }
            for from in legacy where from != to {
                if migrated.contains(from) { continue }
                migrated.insert(from)
                pairs.append((from, to))
            }
        }
        return pairs
    }

    /// The settings patch for these pairs (`phaseJournal` is never touched).
    nonisolated static func patch(settings: [String: JSON], pairs: [(String, String)]) -> [String: JSON] {
        var patch: [String: JSON] = [:]
        for (name, value) in settings {
            if name == "phaseJournal" || !value.truthy { continue }
            switch value { case .object, .array: break; default: continue }
            var next = value
            for (from, to) in pairs { next = renameKey(next, from: from, to: to) }
            if next != value { patch[name] = next }
        }
        return patch
    }

    static func migrate(_ hosts: [JSON]) {
        let ps = pairs(hosts)
        guard !ps.isEmpty, let settings = Store.shared.settings.object else { return }
        let p = patch(settings: settings, pairs: ps)
        if !p.isEmpty { Store.shared.updateSettings(p) }
    }
}
