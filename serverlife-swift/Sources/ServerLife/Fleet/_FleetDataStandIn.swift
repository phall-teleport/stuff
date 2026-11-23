import Foundation

// STAND-IN — a private port of store.js's record methods for snippets,
// macros (pins, hidden built-ins, category order), multi-exec history and
// favourite tunnels. These belong to the data owner; once Data/ publishes
// them as `extension Store`, each body here becomes a one-line call to
// theirs. Same keys, record shapes, caps and ordering as the original, so
// sessions.json stays interchangeable with the Electron app's.

@MainActor
enum FleetStore {
    /// Tests point this at a throwaway store so they never write the real one.
    static var storeOverride: Store?
    static var store: Store { storeOverride ?? Store.shared }

    private static func list(_ key: String) -> [JSON] { store[key].items }
    private static func setList(_ key: String, _ items: [JSON]) { store[key] = .array(items) }

    /// `x || ''` for a free-text field.
    private static func str(_ v: JSON) -> String { v.truthy ? (v.stringish ?? "") : "" }

    /// First line of a command, 40 characters (UTF-16, as `.slice(0, 40)`).
    static func firstLine(_ command: String, max: Int = 40) -> String {
        let line = command.components(separatedBy: "\n").first ?? ""
        let u = Array(line.utf16)
        return u.count > max ? String(decoding: u[0..<max], as: UTF16.self) : line
    }

    // MARK: Command snippets

    static func snippets() -> [JSON] { list("snippets") }

    @discardableResult
    static func upsertSnippet(_ sn: JSON) -> JSON {
        let now = nowMs()
        var all = list("snippets")
        if let id = sn["id"].string, !id.isEmpty, let i = all.firstIndex(where: { $0["id"].string == id }) {
            var rec = all[i]
            rec.merge(sn)
            rec["updatedAt"] = .number(now)
            all[i] = rec
            setList("snippets", all)
            return rec
        }
        let command = str(sn["command"])
        let rec: JSON = [
            "id": .string(newId("s")),
            "name": .string(str(sn["name"]).nilIfEmpty ?? firstLine(command).nilIfEmpty ?? "Snippet"),
            "command": .string(command),
            "tags": sn["tags"].array.map { .array($0) } ?? [],
            "runOnOpen": .bool(sn["runOnOpen"].truthy),
            "createdAt": .number(now),
            "updatedAt": .number(now),
            "useCount": 0,
        ]
        all.append(rec)
        setList("snippets", all)
        return rec
    }

    static func deleteSnippet(_ id: String) {
        setList("snippets", list("snippets").filter { $0["id"].string != id })
    }

    static func markSnippetUsed(_ id: String) {
        var all = list("snippets")
        guard let i = all.firstIndex(where: { $0["id"].string == id }) else { return }
        all[i]["useCount"] = .number((all[i]["useCount"].double ?? 0) + 1)
        all[i]["lastUsed"] = .number(nowMs())
        setList("snippets", all)
    }

    // MARK: Macros

    static func savedMacros() -> [JSON] { list("macros") }
    static func hiddenMacros() -> [String] { list("hiddenMacros").compactMap(\.string) }
    static func macroCategoryOrder() -> [String] { list("macroCategoryOrder").compactMap(\.string) }
    static func macroPins() -> [JSON] { list("macroPins") }
    /// Macro ids in the order they were dragged into, built-ins included.
    static func macroOrder() -> [String] { list("macroOrder").compactMap(\.string) }

    @discardableResult
    static func setMacroOrder(_ ids: [String]) -> [String] { store.setMacroOrder(ids) }

    /**
     * Pin a macro as a session-header button, or unpin it.
     *
     * Order is append: a new button lands on the end rather than reshuffling
     * the ones already in muscle memory. Re-pinning something already pinned
     * only changes its icon (and scope), and keeps its place for the same reason.
     *
     * A pin saved before scopes existed has none and keeps the behaviour it
     * had: hosts only.
     */
    @discardableResult
    static func setMacroPin(_ id: String, pinned: Bool = true, icon: String = "", where scopeIn: String? = nil) -> [JSON] {
        guard !id.isEmpty else { return macroPins() }
        let scope = ["all", "hosts", "local"].contains(scopeIn ?? "") ? scopeIn : nil
        var pins = macroPins()
        let at = pins.firstIndex { $0["id"].string == id }
        let iconCut: String = {
            let u = Array(icon.utf16)
            return u.count > 8 ? String(decoding: u[0..<8], as: UTF16.self) : icon
        }()
        if !pinned {
            if let at { pins.remove(at: at) }
        } else if let at {
            var p = pins[at]
            p["icon"] = .string(iconCut)
            p["where"] = .string(scope ?? p["where"].string?.nilIfEmpty ?? "hosts")
            pins[at] = p
        } else {
            pins.append(["id": .string(id), "icon": .string(iconCut), "where": .string(scope ?? "hosts")])
        }
        setList("macroPins", pins)
        return pins
    }

    @discardableResult
    static func setMacroCategoryOrder(_ order: [String]) -> [String] {
        var out: [String] = []
        for c in order where !c.isEmpty && !out.contains(c) { out.append(c) }
        setList("macroCategoryOrder", out.map { .string($0) })
        return out
    }

    @discardableResult
    static func upsertMacro(_ m: JSON) -> JSON {
        let now = nowMs()
        var all = list("macros")
        if let id = m["id"].string, !id.isEmpty, let i = all.firstIndex(where: { $0["id"].string == id }) {
            var rec = all[i]
            rec.merge(m)
            rec["updatedAt"] = .number(now)
            all[i] = rec
            setList("macros", all)
            return rec
        }
        let command = str(m["command"])
        let whereV = m["where"].string ?? ""
        let rec: JSON = [
            "id": .string(newId("m")),
            "name": .string(str(m["name"]).nilIfEmpty ?? firstLine(command).nilIfEmpty ?? "Macro"),
            "command": .string(command),
            "description": .string(str(m["description"])),
            "category": .string(str(m["category"]).nilIfEmpty ?? "Custom"),
            // Commands that restart things or delete things ask first.
            "confirm": .bool(m["confirm"].truthy),
            // Does not end on its own; only ever sent to a terminal.
            "interactive": .bool(m["interactive"].truthy),
            // Pasted at the prompt without a newline, to be finished by hand.
            "noEnter": .bool(m["noEnter"].truthy),
            "where": .string(["all", "hosts", "local"].contains(whereV) ? whereV : "all"),
            "variables": m["variables"].array.map { .array($0) } ?? [],
            "variableSpec": .string(str(m["variableSpec"])),
            // Seconds between automatic runs; 0 is the normal "run when asked".
            "repeatSeconds": .number(max(0, (m["repeatSeconds"].double ?? 0).isFinite ? (m["repeatSeconds"].double ?? 0).rounded() : 0)),
            "createdAt": .number(now),
            "updatedAt": .number(now),
            "useCount": 0,
        ]
        all.append(rec)
        setList("macros", all)
        return rec
    }

    static func deleteMacro(_ id: String) {
        setList("macros", list("macros").filter { $0["id"].string != id })
        // Drop the pin when its macro is deleted, so no button points at nothing.
        let pins = macroPins()
        if pins.contains(where: { $0["id"].string == id }) {
            setList("macroPins", pins.filter { $0["id"].string != id })
        }
    }

    /// Dismiss (or restore) one of the built-ins, which cannot be deleted.
    @discardableResult
    static func setMacroHidden(_ id: String, _ hidden: Bool) -> [String] {
        var set = hiddenMacros()
        if hidden { if !set.contains(id) { set.append(id) } } else { set.removeAll { $0 == id } }
        setList("hiddenMacros", set.map { .string($0) })
        return set
    }

    static func markMacroUsed(_ id: String) {
        var all = list("macros")
        guard let i = all.firstIndex(where: { $0["id"].string == id }) else { return }
        all[i]["useCount"] = .number((all[i]["useCount"].double ?? 0) + 1)
        all[i]["lastUsed"] = .number(nowMs())
        setList("macros", all)
    }

    // MARK: Multi-exec history

    /// Remember a run. The same command on the same hosts replaces its earlier
    /// entry rather than filling the list with one command repeated.
    @discardableResult
    static func addExecRun(_ rec: JSON) -> JSON? {
        let command = str(rec["command"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        let hostIds = rec["hostIds"].items.filter(\.truthy).compactMap(\.stringish)
        func key(_ cmd: String, _ ids: [String]) -> String { cmd + "\u{0}" + ids.sorted().joined(separator: ",") }
        let k = key(command, hostIds)
        let sel = rec["selector"]
        let row: JSON = [
            "id": .string(newId("mx")),
            "command": .string(command),
            "label": .string(rec["label"].stringish ?? ""),
            "runAs": rec["runAs"].truthy ? rec["runAs"] : .null,
            "hosts": .array(Array(rec["hosts"].items.prefix(60))),
            "hostIds": .array(hostIds.prefix(60).map { .string($0) }),
            // A tag run is defined by its query; the host list above is only
            // the set it matched at the time.
            "selector": sel.object != nil
                ? ["proxy": .string(str(sel["proxy"])), "query": .string(sel["query"].truthy ? (sel["query"].stringish ?? "") : "")]
                : .null,
            "ok": .number(rec["ok"].double.flatMap { $0.isFinite ? $0 : nil } ?? 0),
            "failed": .number(rec["failed"].double.flatMap { $0.isFinite ? $0 : nil } ?? 0),
            "at": .number(nowMs()),
        ]
        var runs = list("execRuns").filter { key($0["command"].stringish ?? "", $0["hostIds"].items.compactMap(\.stringish)) != k }
        runs.insert(row, at: 0)
        if runs.count > 40 { runs = Array(runs.prefix(40)) }
        setList("execRuns", runs)
        return row
    }

    static func execRuns() -> [JSON] { list("execRuns") }

    static func deleteExecRun(_ id: String) {
        setList("execRuns", list("execRuns").filter { $0["id"].string != id })
    }

    static func clearExecRuns() { setList("execRuns", []) }

    // MARK: Favourite tunnels

    static func forwardFavorites() -> [JSON] { list("forwardFavorites") }

    /// Keep a forward. An existing favourite for the same host and the same
    /// listen port is updated rather than duplicated — starring the same
    /// tunnel twice is the same intention said twice.
    @discardableResult
    static func addForwardFavorite(_ rec: JSON) throws -> JSON {
        let kindIn = rec["kind"].string ?? ""
        let kind = ["L", "R", "D"].contains(kindIn) ? kindIn : "L"
        let bindPort = Int(rec["bindPort"].double ?? 0)
        guard bindPort != 0 else { throw AppError("A favourite needs a listen port") }
        guard rec["host"].object != nil else { throw AppError("A favourite needs the host to open it on") }
        let host = rec["host"]
        var row: JSON = [
            "id": .string(newId("fwd")),
            "name": .string(str(rec["name"]).trimmingCharacters(in: .whitespacesAndNewlines)),
            "kind": .string(kind),
            "bindPort": .number(Double(bindPort)),
            "bindAddr": .string(str(rec["bindAddr"]).trimmingCharacters(in: .whitespacesAndNewlines)),
            "destHost": .string(kind == "D" ? "" : str(rec["destHost"]).trimmingCharacters(in: .whitespacesAndNewlines)),
            "destPort": .number(kind == "D" ? 0 : (rec["destPort"].double ?? 0)),
            "host": host,
            "login": rec["login"].truthy ? rec["login"] : .null,
            "createdAt": .number(nowMs()),
            "lastUsedAt": .null,
        ]
        var favs = list("forwardFavorites")
        if let at = favs.firstIndex(where: { $0["host"]["id"] == host["id"] && $0["bindPort"].int == bindPort && $0["kind"].string == kind }) {
            row["id"] = favs[at]["id"]
            if favs[at]["createdAt"].truthy { row["createdAt"] = favs[at]["createdAt"] }
            row["lastUsedAt"] = favs[at]["lastUsedAt"].truthy ? favs[at]["lastUsedAt"] : .null
            favs[at] = row
        } else {
            favs.append(row)
        }
        setList("forwardFavorites", favs)
        return row
    }

    @discardableResult
    static func updateForwardFavorite(_ id: String, _ patch: JSON) -> JSON? {
        var favs = list("forwardFavorites")
        guard let at = favs.firstIndex(where: { $0["id"].string == id }) else { return nil }
        var row = favs[at]
        row.merge(patch)
        row["id"] = .string(id)
        favs[at] = row
        setList("forwardFavorites", favs)
        return row
    }

    static func markForwardFavoriteUsed(_ id: String) {
        updateForwardFavorite(id, ["lastUsedAt": .number(nowMs())])
    }

    static func deleteForwardFavorite(_ id: String) {
        setList("forwardFavorites", list("forwardFavorites").filter { $0["id"].string != id })
    }
}
