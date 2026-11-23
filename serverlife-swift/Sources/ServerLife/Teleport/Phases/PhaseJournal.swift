import Foundation

/// One build recorded in `settings.phaseJournal` (beams.js), kept as the
/// JSON the original writes so either app reads the other's records.
struct PhaseBuildEntry: Identifiable, Equatable {
    var raw: JSON
    var id: String { raw["id"].stringish ?? "" }
    var proxy: String { raw["proxy"].stringish ?? "" }
    var name: String { raw["name"].stringish ?? "" }
    var kind: String { raw["kind"].stringish ?? "" }
    var mode: String { raw["mode"].stringish ?? "" }
    var source: String { raw["source"].stringish ?? "" }
    var result: String { raw["result"].stringish ?? "" }
    var commandsFile: String { raw["commandsFile"].stringish ?? "" }
    var copies: [PhaseCopy] { raw["copies"].items.map { PhaseCopy(from: $0["from"].stringish ?? "", to: $0["to"].stringish ?? "") } }
    var roles: [String] { raw["roles"].items.compactMap(\.stringish) }
    var region: String { raw["region"].stringish ?? "" }
    var digest: String { raw["digest"].stringish ?? "" }
    var error: String { raw["error"].stringish ?? "" }
    var startedAt: Double { raw["startedAt"].double ?? 0 }
    var endedAt: Double? { raw["endedAt"].double }
    var exitCode: Int? { raw["exitCode"].int }
}

/// What a build is recorded with (the `meta` beams.js spreads into the entry).
typealias PhaseBuildMeta = [String: JSON]

extension Dictionary where Key == String, Value == JSON {
    static func strs(_ a: [String]) -> JSON { .array(a.map { .string($0) }) }
    static func copies(_ c: [PhaseCopy]) -> JSON { .array(c.map { .object(["from": .string($0.from), "to": .string($0.to)]) }) }
}

@MainActor
enum PhaseJournal {
    static let max = 200

    static var entries: [PhaseBuildEntry] {
        Store.shared.settingJSON("phaseJournal").items.map(PhaseBuildEntry.init(raw:))
    }
    static func save(_ next: [PhaseBuildEntry]) {
        Store.shared.setSettingJSON("phaseJournal", .array(next.prefix(max).map(\.raw)))
        PhaseStore.shared.journalGeneration += 1
    }

    static func newEntry(proxy: String, _ meta: PhaseBuildMeta) -> PhaseBuildEntry {
        let id = String(Int64(nowMs()), radix: 36) + String(UInt32.random(in: 0..<UInt32.max), radix: 36).prefix(4)
        var o: [String: JSON] = ["id": .string(id), "proxy": .string(proxy), "startedAt": .number(nowMs()), "result": .string("running")]
        for (k, v) in meta { o[k] = v }
        return PhaseBuildEntry(raw: .object(o))
    }

    /// Settled by the Phase itself: saved since the build began, or marked failed.
    static func judge(_ e: PhaseBuildEntry, _ ph: BeamPhase?) -> String? {
        guard let ph else { return nil }
        if ph.state == "ready" && (ph.publishedAt ?? 0) >= e.startedAt - 60000 { return "saved" }
        if ph.state.range(of: "fail|error", options: [.regularExpression, .caseInsensitive]) != nil { return "failed" }
        return nil
    }

    /*
     * A build whose ending was not known when its tab closed — the cluster can
     * take a moment to list a snapshot it has just saved — is settled the next
     * time the list is read, so its record, and the history built from it, says
     * what really happened.
     */
    static func settle(proxy: String, phases: [BeamPhase]) {
        var byName: [String: BeamPhase] = [:]
        for p in phases { byName[p.name] = p }
        var changed = false
        let next = entries.map { e -> PhaseBuildEntry in
            if e.proxy != proxy || e.name.isEmpty || !["running", "unknown"].contains(e.result) { return e }
            let ph = byName[e.name]
            guard let result = judge(e, ph), let ph else { return e }
            changed = true
            var r = e.raw
            r["result"] = .string(result)
            r["digest"] = .string(ph.digest.nilIfEmpty ?? e.digest)
            r["error"] = .string(result == "failed" ? ph.lastError : "")
            return PhaseBuildEntry(raw: r)
        }
        if changed { save(next) }
    }

    /// The builds recorded for one Phase on one cluster, newest first.
    static func buildsOf(_ proxy: String, _ name: String) -> [PhaseBuildEntry] {
        let n = BeamsUI.phaseName(name)
        return entries.filter { $0.proxy == proxy && $0.name == n }
    }

    /*
     * How a Phase was first made, if it was made from here: the build that saved it.
     * Not `result === 'saved'`: a build still shows as "building" in `tsh phase
     * ls` long before settle() can call it saved, and a fork's lineage is
     * known the moment the build starts, not once it finishes — waiting for
     * "saved" left every build-in-progress looking parentless until it published.
     * Only a build recorded as failed is excluded.
     */
    static func originOf(_ proxy: String, _ name: String) -> PhaseBuildEntry? {
        buildsOf(proxy, name).filter { $0.kind == "add" && $0.result != "failed" }.last
    }

    static func update(_ id: String, _ patch: [String: JSON]) {
        save(entries.map { e in
            guard e.id == id else { return e }
            var r = e.raw
            for (k, v) in patch { r[k] = v }
            return PhaseBuildEntry(raw: r)
        })
    }
}
