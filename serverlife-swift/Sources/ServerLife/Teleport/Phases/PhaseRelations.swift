import Foundation

/// One step of a Phase's lineage (beams.js `phaseRelations().chain`): a
/// listed Phase, or the root it hangs from — a base image, or a Phase no
/// longer listed.
struct PhaseStep: Identifiable {
    var phase: BeamPhase?
    var name: String
    /// "fork" or "from": how it came from the step before.
    var how = "from"
    var base = false
    var gone = false
    var origin: PhaseBuildEntry?
    var id: String { name }
}

struct PhaseChild: Identifiable {
    var phase: BeamPhase
    var how: String
    var id: String { phase.name }
}

struct PhaseRelationsInfo {
    var chain: [PhaseStep]
    var children: [PhaseChild]
    var beams: [Beam]
    var builds: [PhaseBuildEntry]
}

@MainActor
enum PhaseRelations {
    /**
     * A Phase's history and what depends on it.
     *
     * From the cluster's list, the chain of parents back to the base image; from
     * this app's own record of the builds it ran, the fork that made it, which the
     * list does not keep (see the journal). `how` on each step says how it
     * came from the one before: built on it, forked from it, or the base image.
     */
    static func of(_ proxy: String, _ name: String, phases: [BeamPhase]? = nil,
                   journal: [PhaseBuildEntry]? = nil, beams: [Beam]? = nil) -> PhaseRelationsInfo {
        let all = phases ?? BeamPhaseLists.shared.phaseList(proxy)?.phases ?? []
        let entries = journal ?? PhaseJournal.entries
        let pn = BeamsUI.phaseName
        func buildsOf(_ n: String) -> [PhaseBuildEntry] { entries.filter { $0.proxy == proxy && $0.name == pn(n) } }
        func originOf(_ n: String) -> PhaseBuildEntry? {
            buildsOf(n).filter { $0.kind == "add" && $0.result != "failed" }.last
        }
        var byName: [String: BeamPhase] = [:]
        for p in all { byName[p.name] = p }
        var chain: [PhaseStep] = []
        var seen = Set<String>()
        var at = byName[pn(name)]
        while let cur = at, !seen.contains(cur.name) {
            seen.insert(cur.name)
            let origin = originOf(cur.name)
            let forked = origin?.mode == "fork" && !(origin?.source.isEmpty ?? true)
            chain.insert(PhaseStep(phase: cur, name: cur.name, how: forked ? "fork" : "from", origin: origin), at: 0)
            let up = forked ? pn(origin!.source) : pn(cur.parent)
            let next = byName[up]
            if next == nil && !up.isEmpty {
                // The root: a base image, or a Phase no longer listed.
                chain.insert(PhaseStep(name: forked ? origin!.source : cur.parent, base: !forked, gone: forked), at: 0)
                break
            }
            at = next
        }
        let mine = pn(name)
        let forksOf = Set(entries.filter {
            $0.proxy == proxy && $0.kind == "add" && $0.result != "failed" && $0.mode == "fork" && pn($0.source) == mine
        }.map(\.name))
        let children = all.filter { p in
            if p.name == mine { return false }
            if forksOf.contains(p.name) { return true }
            let o = originOf(p.name)
            if o == nil && pn(p.parent) == mine { return true }
            return o?.mode == "from" && pn(o!.source) == mine
        }.map { PhaseChild(phase: $0, how: forksOf.contains($0.name) ? "fork" : "from") }
        let running = (beams ?? Inventory.shared.beamsFor(proxy)).filter { !$0.phase.isEmpty && pn($0.phase) == mine }
        return PhaseRelationsInfo(chain: chain, children: children, beams: running, builds: buildsOf(mine))
    }

    /// `default:v1 → sage-garden ⑂ my-fork`, for a menu line: ⑂ marks a fork.
    nonisolated static func lineageText(_ chain: [(name: String, how: String)], fallback: String) -> String {
        if chain.isEmpty { return fallback }
        return chain.enumerated().map { i, p in (i > 0 ? (p.how == "fork" ? " ⑂ " : " → ") : "") + p.name }.joined()
    }

    static func lineageText(_ rel: PhaseRelationsInfo, fallback: String) -> String {
        lineageText(rel.chain.map { ($0.name, $0.how) }, fallback: fallback)
    }

    /// The menu's "History and beams…" second line.
    static func menuSub(_ rel: PhaseRelationsInfo, _ phase: BeamPhase) -> String {
        var first = ""
        if rel.chain.count >= 2 {
            let prev = rel.chain[rel.chain.count - 2], me = rel.chain[rel.chain.count - 1]
            first = (me.how == "fork" ? "forked from " : "from ") + prev.name
        } else if !phase.parent.isEmpty {
            first = "from " + phase.parent
        }
        return [first,
                "\(rel.beams.count) beam\(rel.beams.count == 1 ? "" : "s") running it",
                "\(rel.children.count) built on it"].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
