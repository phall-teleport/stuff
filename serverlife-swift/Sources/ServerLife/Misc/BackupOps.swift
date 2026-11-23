import Foundation

/// The envelope behind the backup dialogs (main/backup.js: exportAll,
/// exportMacros, parse, describe, applyImport).
///
/// These belong to the data owner. They were not published when the dialogs
/// were written, so this is a faithful stand-in over `Store.shared`; once
/// Data/ publishes its own, each function here should become a one-line call
/// to it (see Misc/README.md → Backup).
@MainActor
enum BackupOps {
    static let format = "serverlife.backup"
    static let version = 1

    /// What "everything" means. History is left out: it is a log, not a setting.
    static let fullKeys = ["profiles", "folders", "snippets", "macros", "hiddenMacros", "macroCategoryOrder",
                           "requestTemplates", "layouts", "defaultLayoutId", "settings"]
    /// Keys that are lists of records, and so can be merged rather than replaced.
    static let listKeys = ["profiles", "folders", "snippets", "macros", "requestTemplates", "layouts"]

    static func envelope(_ kind: String, _ data: JSON, _ meta: [String: JSON] = [:]) -> JSON {
        var e: JSON = ["format": .string(format), "version": JSON(version), "kind": .string(kind),
                       "exportedAt": .string(isoNow()), "app": "ServerLife"]
        for (k, v) in meta { e[k] = v }
        e["data"] = data
        return e
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Everything (`what == all`), or macros only — the user's own (built-ins
    /// exist on the other machine already), plus hidden built-in ids and the
    /// category order unless only some ids were asked for.
    static func export(_ macrosOnly: Bool, _ ids: [String]?) throws -> JSON {
        let store = Store.shared
        if macrosOnly {
            let all = store["macros"].items
            let picked = (ids?.isEmpty == false) ? all.filter { ids!.contains($0["id"].string ?? "") } : all
            let some = ids?.isEmpty == false
            return envelope("macros", ["macros": .array(picked),
                                       "hiddenMacros": some ? [] : .array(store["hiddenMacros"].items),
                                       "macroCategoryOrder": some ? [] : .array(store["macroCategoryOrder"].items)],
                            ["counts": ["macros": JSON(picked.count)]])
        }
        var data: JSON = .object([:])
        for k in fullKeys {
            let v = k == "settings" ? store.settings : store[k]
            if !(k != "settings" && store.data.entries[k] == nil) { data[k] = v }
        }
        var counts: JSON = .object([:])
        for k in listKeys { counts[k] = JSON(data[k].items.count) }
        return envelope("settings", data, ["counts": counts])
    }

    static func parse(_ text: String) throws -> JSON {
        guard let doc = try? JSON.parse(text) else { throw AppError("That file is not JSON.") }
        guard doc["format"].string == format else { throw AppError("That is not a ServerLife export.") }
        if let v = doc["version"].double, v > Double(version) {
            throw AppError("That file was written by a newer ServerLife (format \(doc["version"].stringish ?? "")).")
        }
        guard doc["data"].object != nil else { throw AppError("The export has no data in it.") }
        return doc
    }

    /// What an import would do, without doing it.
    static func describe(_ doc: JSON) -> JSON {
        let d = doc["data"]
        var counts: JSON = .object([:])
        for k in listKeys + ["hiddenMacros"] { if let a = d[k].array { counts[k] = JSON(a.count) } }
        return ["kind": doc["kind"], "exportedAt": doc["exportedAt"].string.map { .string($0) } ?? .null,
                "hasSettings": .bool(d["settings"].truthy), "counts": counts]
    }

    /// Merge keeps what is here and adds what is not (matched on id); replace
    /// makes this machine look like the file. Settings always merge over the
    /// top: a file from an older build must not remove settings this one has.
    static func apply(_ doc: JSON, _ mode: String) throws -> JSON {
        let store = Store.shared
        let d = doc["data"]
        var added: JSON = .object([:])
        for k in listKeys {
            guard let incoming = d[k].array else { continue }
            if mode == "replace" {
                store[k] = .array(incoming)
                added[k] = JSON(incoming.count)
                continue
            }
            let existing = store[k].items
            let seen = Set(existing.compactMap { $0["id"].string }.filter { !$0.isEmpty })
            let fresh = incoming.filter { x in
                guard x.truthy else { return false }
                let id = x["id"].string ?? ""
                return id.isEmpty || !seen.contains(id)
            }
            store[k] = .array(existing + fresh)
            added[k] = JSON(fresh.count)
        }
        for k in ["hiddenMacros", "macroCategoryOrder"] {
            guard let incoming = d[k].array else { continue }
            if mode == "replace" { store[k] = .array(incoming); continue }
            var out = store[k].items
            for x in incoming where !out.contains(x) { out.append(x) }
            store[k] = .array(out)
        }
        if let s = d["settings"].object {
            Store.shared.updateSettings(s)
        }
        if mode == "replace", d.entries["defaultLayoutId"] != nil {
            store["defaultLayoutId"] = d["defaultLayoutId"]
        }
        store.save()
        return ["mode": .string(mode), "added": added]
    }
}
