import Foundation

// STAND-IN for the data owner's store.js methods that automation needs.
//
// Data/ has not published `extension Store` record methods yet, so the ones the
// control socket and S3 use are written here, working on `Store.shared` with
// exactly store.js's keys, shapes, caps and ordering. When Data/ publishes,
// each of these should forward to (or be replaced by) theirs. Everything is
// prefixed `auto` so nothing clashes with the real methods.

@MainActor
extension Store {
    // MARK: S3 buckets (store.js listS3Targets / getS3Target / upsertS3Target / deleteS3Target)

    func autoListS3Targets() -> [JSON] { self["s3Targets"].items }

    func autoGetS3Target(_ id: String) -> JSON? {
        self["s3Targets"].items.first { $0["id"].string == id }
    }

    /// `upsertS3Target`: the record exactly as store.js writes it.
    @discardableResult
    func autoUpsertS3Target(_ t: JSON) -> JSON {
        let now = nowMs()
        var list = self["s3Targets"].items
        let id = t["id"].string?.nilIfEmpty
        let i = id.flatMap { want in list.firstIndex { $0["id"].string == want } }
        let rec: JSON = [
            "id": .string(id ?? newId("s3")),
            "name": .string(t["name"].string?.nilIfEmpty ?? t["bucket"].string?.nilIfEmpty ?? "S3"),
            "bucket": .string(t["bucket"].string ?? ""),
            "region": .string(t["region"].string ?? ""),
            "prefix": .string(t["prefix"].string ?? ""),
            "endpoint": .string(t["endpoint"].string ?? ""),
            "pathStyle": .bool(t["pathStyle"].truthy),
            "defaultStorageClass": .string(t["defaultStorageClass"].string?.nilIfEmpty ?? "STANDARD"),
            "credentials": t["credentials"].truthy ? t["credentials"] : ["mode": "env"],
            "createdAt": i.map { list[$0]["createdAt"] } ?? .number(now),
            "updatedAt": .number(now),
        ]
        if let i { list[i] = rec } else { list.append(rec) }
        self["s3Targets"] = .array(list)
        return rec
    }

    func autoDeleteS3Target(_ id: String) {
        self["s3Targets"] = .array(self["s3Targets"].items.filter { $0["id"].string != id })
    }

    // MARK: layouts (store.js listLayouts / saveLayout)

    func autoListLayouts() -> [JSON] {
        let def = self["defaultLayoutId"].string
        return self["layouts"].items.map { l in
            var o = l
            o["isDefault"] = .bool(def != nil && l["id"].string == def)
            return o
        }
    }

    /// `saveLayout({id, name, workspace})`: overwrite by id, or by name
    /// (case-insensitive), else add.
    @discardableResult
    func autoSaveLayout(id: String? = nil, name: String, workspace: JSON) -> JSON {
        let now = nowMs()
        var list = self["layouts"].items
        let def = self["defaultLayoutId"].string
        let at: Int? = id.map { want in list.firstIndex { $0["id"].string == want } }
            ?? list.firstIndex { ($0["name"].string ?? "").lowercased() == name.lowercased() }
        if let at {
            var e = list[at]
            if !name.isEmpty { e["name"] = .string(name) }
            e["workspace"] = workspace
            e["updatedAt"] = .number(now)
            list[at] = e
            self["layouts"] = .array(list)
            var out = e
            out["isDefault"] = .bool(def != nil && e["id"].string == def)
            return out
        }
        let rec: JSON = ["id": .string(newId("l")), "name": .string(name.isEmpty ? "Layout" : name),
                         "workspace": workspace, "createdAt": .number(now), "updatedAt": .number(now)]
        list.append(rec)
        self["layouts"] = .array(list)
        var out = rec
        out["isDefault"] = false
        return out
    }

    // MARK: forward favourites (listForwardFavorites / markForwardFavoriteUsed)

    func autoListForwardFavorites() -> [JSON] { self["forwardFavorites"].items }

    func autoMarkForwardFavoriteUsed(_ id: String) {
        mutate("forwardFavorites") { list in
            list = .array(list.items.map { f in
                guard f["id"].string == id else { return f }
                var g = f
                g["lastUsedAt"] = .number(nowMs())
                return g
            })
        }
    }

    // MARK: saved HTTP requests (listNetRequests / saveNetRequest)

    /// Newest first, by last run, else when saved.
    func autoListNetRequests() -> [JSON] {
        self["netRequests"].items.sorted {
            ($0["lastRunAt"].double ?? $0["savedAt"].double ?? 0) > ($1["lastRunAt"].double ?? $1["savedAt"].double ?? 0)
        }
    }

    /// The part of `saveNetRequest` run_request needs: stamp `lastRunAt`
    /// (store.js rewrites the row and refreshes `savedAt`, keeping the first).
    func autoMarkNetRequestRun(_ rec: JSON) {
        guard let id = rec["id"].string else { return }
        mutate("netRequests") { list in
            list = .array(list.items.map { r in
                guard r["id"].string == id else { return r }
                var o = r
                o["lastRunAt"] = .number(nowMs())
                if o["savedAt"].isNull { o["savedAt"] = .number(nowMs()) }
                return o
            })
        }
    }

    // MARK: saved cluster logins (listTshLogins)

    func autoListTshLogins() -> [JSON] {
        self["tshLogins"].items.sorted {
            ($0["lastUsed"].double ?? $0["updatedAt"].double ?? 0) > ($1["lastUsed"].double ?? $1["updatedAt"].double ?? 0)
        }
    }

    // MARK: profiles (listProfiles)

    func autoListProfiles() -> [JSON] { self["profiles"].items }
}
