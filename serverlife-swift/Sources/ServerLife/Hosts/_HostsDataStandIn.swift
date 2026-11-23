import Foundation

// Stand-in for the store.js record methods the hosts feature needs —
// profiles, profile folders and session history — until Data/ publishes its
// own. Same keys, caps and ordering as store.js; works on `Store.shared`
// directly, as JSON, so a record round-trips with every field it had.
// Swap each function for Data's when it lands.

/// JavaScript `a || b` for JSON values.
func hostsOr(_ a: JSON, _ b: JSON) -> JSON { a.truthy ? a : b }

@MainActor
enum HostsData {
    // MARK: Profiles (store.js listProfiles / getProfile / upsertProfile / deleteProfile / markUsed)

    static var profiles: [JSON] { Store.shared["profiles"].items }

    static func profile(_ id: String?) -> JSON? {
        guard let id, !id.isEmpty else { return nil }
        return profiles.first { $0["id"].string == id }
    }

    /// `upsertProfile`: an existing id is merged over (and `updatedAt`
    /// stamped); anything else is created with the store's full record shape.
    @discardableResult
    static func upsertProfile(_ profile: JSON) -> JSON {
        let now = JSON.number(nowMs())
        if let id = profile["id"].string, !id.isEmpty {
            var list = profiles
            if let i = list.firstIndex(where: { $0["id"].string == id }) {
                var merged = list[i]
                merged.merge(profile)
                merged["updatedAt"] = now
                list[i] = merged
                Store.shared["profiles"] = .array(list)
                return merged
            }
        }
        let p = profile
        func orNull(_ k: String) -> JSON { p[k].truthy ? p[k] : .null }
        var rec: JSON = [:]
        rec["id"] = .string(newId())
        rec["name"] = hostsOr(p["name"], hostsOr(p["alias"], hostsOr(p["node"], "Untitled")))
        rec["folderId"] = orNull("folderId")
        rec["type"] = hostsOr(p["type"], "ssh")
        for k in ["alias", "hostname", "user", "port", "identityFile", "proxyJump", "direct",
                  "proxy", "cluster", "home", "node", "login",
                  "path", "baudRate", "dataBits", "parity", "stopBits"] { rec[k] = orNull(k) }
        rec["rtscts"] = .bool(p["rtscts"].truthy)
        rec["xon"] = .bool(p["xon"].truthy)
        rec["xoff"] = .bool(p["xoff"].truthy)
        rec["host"] = orNull("host")
        rec["devicePort"] = orNull("devicePort")
        rec["newline"] = orNull("newline")
        rec["localEcho"] = .bool(p["localEcho"].truthy)
        rec["viewOnly"] = .bool(p["viewOnly"].truthy)
        rec["scaling"] = orNull("scaling")
        rec["quality"] = p["quality"]            // `?? null`: 0 is kept
        rec["username"] = orNull("username")
        rec["domain"] = orNull("domain")
        rec["fullscreen"] = .bool(p["fullscreen"].truthy)
        rec["width"] = orNull("width")
        rec["height"] = orNull("height")
        rec["clipboard"] = .bool(p["clipboard"] != .bool(false))
        rec["drives"] = .bool(p["drives"].truthy)
        rec["gateway"] = orNull("gateway")
        rec["color"] = orNull("color")
        rec["tags"] = hostsOr(p["tags"], .array([]))
        rec["startupCommand"] = hostsOr(p["startupCommand"], "")
        rec["remoteStartPath"] = hostsOr(p["remoteStartPath"], "")
        rec["localStartPath"] = hostsOr(p["localStartPath"], "")
        rec["notes"] = hostsOr(p["notes"], "")
        rec["createdAt"] = now
        rec["updatedAt"] = now
        rec["lastUsed"] = .null
        rec["useCount"] = 0
        Store.shared["profiles"] = .array(profiles + [rec])
        return rec
    }

    static func deleteProfile(_ id: String) {
        let before = profiles
        let after = before.filter { $0["id"].string != id }
        if after.count != before.count { Store.shared["profiles"] = .array(after) }
    }

    static func markUsed(_ id: String?) {
        guard let id else { return }
        var list = profiles
        guard let i = list.firstIndex(where: { $0["id"].string == id }) else { return }
        list[i]["lastUsed"] = .number(nowMs())
        list[i]["useCount"] = .number(Double((list[i]["useCount"].int ?? 0) + 1))
        Store.shared["profiles"] = .array(list)
    }

    // MARK: Profile folders (listFolders / upsertFolder / deleteFolder)

    static var profileFolders: [JSON] { Store.shared["folders"].items }

    @discardableResult
    static func upsertProfileFolder(_ folder: JSON) -> JSON {
        var list = profileFolders
        if let id = folder["id"].string, !id.isEmpty, let i = list.firstIndex(where: { $0["id"].string == id }) {
            list[i].merge(folder)
            Store.shared["folders"] = .array(list)
            return list[i]
        }
        let rec: JSON = ["id": .string(newId("f")), "name": hostsOr(folder["name"], "New folder"),
                         "parentId": hostsOr(folder["parentId"], .null)]
        Store.shared["folders"] = .array(list + [rec])
        return rec
    }

    static func deleteProfileFolder(_ id: String) {
        Store.shared["folders"] = .array(profileFolders.filter { $0["id"].string != id })
        var list = profiles
        for i in list.indices where list[i]["folderId"].string == id { list[i]["folderId"] = .null }
        Store.shared["profiles"] = .array(list)
    }

    // MARK: Session history (listHistory / listRecent / clearHistory)

    static func listHistory(limit: Int = 200) -> [JSON] {
        Array(Store.shared["history"].items.prefix(max(0, limit)))
    }

    /// `listRecent`: the last few distinct places connected to, newest
    /// first, one entry per destination (the port is part of a direct host's
    /// identity), remembering whether one has ever worked.
    static func listRecent(limit: Int = 20) -> [JSON] {
        listRecent(Store.shared["history"].items, limit: limit)
    }

    nonisolated static func listRecent(_ history: [JSON], limit: Int) -> [JSON] {
        if limit <= 0 { return [] }
        var order: [String] = []
        var seen: [String: JSON] = [:]
        func s(_ v: JSON) -> String { v.truthy ? (v.stringish ?? "") : "" }
        for h in history {
            let key = [s(h["type"]), s(h["cluster"]), s(hostsOr(h["node"], hostsOr(h["target"], h["label"]))),
                       s(h["login"]), s(h["home"]), s(h["direct"]["port"])].joined(separator: "\u{0}")
            if var rec = seen[key] {
                if rec["error"].truthy && !h["error"].truthy { rec["error"] = .null; rec["lastOkAt"] = h["startedAt"] }
                rec["count"] = .number(Double((rec["count"].int ?? 1) + 1))
                seen[key] = rec
                continue
            }
            var rec: JSON = [:]
            rec["key"] = .string(key)
            rec["type"] = h["type"]
            rec["label"] = h["label"]
            for k in ["target", "cluster", "proxy", "node", "home", "login", "user", "hostname", "direct"] {
                rec[k] = h[k].truthy ? h[k] : .null
            }
            rec["at"] = h["startedAt"]
            rec["lastOkAt"] = h["error"].truthy ? .null : h["startedAt"]
            rec["error"] = h["error"].truthy ? h["error"] : .null
            rec["count"] = 1
            seen[key] = rec
            order.append(key)
            if seen.count >= limit { break }
        }
        return order.compactMap { seen[$0] }
    }

    static func clearHistory() {
        Store.shared["history"] = .array([])
    }
}
