import SwiftUI

/*
 * The Phases tab in Relationship view (sidebar.js `phaseRelationRows`): not
 * folders — the build lineage `PhaseRelations.of` already works out for a
 * Phase's own menu, drawn here for all of them at once. Phases sharing an
 * upstream image this app has no record of — the base image, or a fork whose
 * source Phase no longer exists — are grouped under it as a plain label, not
 * a Phase of its own; everything else nests under whatever it was built on or
 * forked from.
 */
enum PhaseRelRow: Identifiable {
    case base(name: String, shut: Bool, count: Int)
    case phase(BeamPhase, depth: Int, via: String?, kids: Int, hidden: Int)
    var id: String {
        switch self {
        case .base(let n, _, _): return "b:" + n
        case .phase(let p, _, _, _, _): return "p:" + p.name
        }
    }
}

@MainActor
enum PhaseRelLayout {
    /// The rows, in order. `shut` holds `<proxy>|<name>` (and `<proxy>|base:<image>`).
    static func rows(proxy: String, list: [BeamPhase], shut: Set<String>,
                     relOf: [String: PhaseRelationsInfo]) -> [PhaseRelRow] {
        var childNames = Set<String>()
        for rel in relOf.values { for c in rel.children { childNames.insert(c.phase.name) } }
        let roots = list.filter { !childNames.contains($0.name) }
        var byBase: [String: [BeamPhase]] = [:]
        for ph in roots {
            let chain = relOf[ph.name]?.chain ?? []
            let base = chain.first.map { $0.base || $0.gone ? $0.name : "" } ?? ""
            byBase[base, default: []].append(ph)
        }
        let byName = Set(list.map(\.name))
        let sortName: (BeamPhase, BeamPhase) -> Bool = { $0.name.localizedCompare($1.name) == .orderedAscending }
        func shutKey(_ n: String) -> String { "\(proxy)|\(n)" }
        func kidsOf(_ ph: BeamPhase) -> [PhaseChild] {
            (relOf[ph.name]?.children ?? []).filter { byName.contains($0.phase.name) }
                .sorted { $0.phase.name.localizedCompare($1.phase.name) == .orderedAscending }
        }
        let phaseOf = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [PhaseRelRow] = []
        /*
         * Each Phase is drawn once. The lineage comes from this app's own build
         * history, which can loop — a name deleted and reused for a Phase built
         * on its old namesake's child — and following a loop never ends.
         */
        var drawn = Set<String>()
        // Everything under a shut one: counted, and kept out of the loop catch-all below.
        func hideUnder(_ ph: BeamPhase) -> Int {
            var n = 0
            for c in kidsOf(ph) where !drawn.contains(c.phase.name) {
                drawn.insert(c.phase.name)
                n += 1 + hideUnder(phaseOf[c.phase.name] ?? c.phase)
            }
            return n
        }
        func draw(_ ph: BeamPhase, _ depth: Int, from: String? = nil, how: String = "from") {
            if drawn.contains(ph.name) { return }
            drawn.insert(ph.name)
            // Under its base image's label, the base image again is only noise.
            let via: String? = from.map { "\(how == "fork" ? "\u{2442} fork of" : "on") \($0)" } ?? (depth > 0 ? "" : nil)
            let kids = kidsOf(ph).filter { !drawn.contains($0.phase.name) }
            let at = rows.count
            rows.append(.phase(ph, depth: depth, via: via, kids: kids.count, hidden: 0))
            if shut.contains(shutKey(ph.name)) {
                let n = hideUnder(ph)
                rows[at] = .phase(ph, depth: depth, via: via, kids: kids.count, hidden: n)
                return
            }
            for c in kids { draw(phaseOf[c.phase.name] ?? c.phase, depth + 1, from: ph.name, how: c.how) }
        }
        for base in byBase.keys.sorted(by: { $0.localizedCompare($1) == .orderedAscending }) {
            let sorted = byBase[base]!.sorted(by: sortName)
            if !base.isEmpty {
                let isShut = shut.contains(shutKey("base:" + base))
                rows.append(.base(name: base, shut: isShut, count: sorted.count))
                if isShut {
                    for ph in sorted where !drawn.contains(ph.name) { drawn.insert(ph.name); _ = hideUnder(ph) }
                    continue
                }
            }
            for ph in sorted { draw(ph, base.isEmpty ? 0 : 1) }
        }
        // A loop has no top to hang from: whatever it left out is still listed.
        for ph in list.sorted(by: sortName) { draw(ph, 0) }
        return rows
    }
}

struct PhaseRelationRows: View {
    let profile: TeleportProfile
    let list: [BeamPhase]
    weak var window: WindowModel?

    /// Open and shut, like folders: what was shut stays shut (kept per cluster, by name).
    private var shut: Set<String> { Set(Store.shared.setting("phaseRelShut", [String]())) }

    private func toggle(_ name: String) {
        let key = "\(profile.proxy)|\(name)"
        var next = Store.shared.setting("phaseRelShut", [String]())
        if let i = next.firstIndex(of: key) { next.remove(at: i) } else { next.append(key) }
        Store.shared.setSetting("phaseRelShut", next)
    }

    var body: some View {
        let p = Theme.shared.p
        let gk = phaseGroupKey(profile)
        let relOf = Dictionary(list.map { ($0.name, PhaseRelations.of(profile.proxy, $0.name, phases: list)) },
                               uniquingKeysWith: { a, _ in a })
        let shutNow = shut
        ForEach(PhaseRelLayout.rows(proxy: profile.proxy, list: list, shut: shutNow, relOf: relOf)) { row in
            switch row {
            case .base(let name, let isShut, let count):
                HStack(spacing: 6) {
                    Text(isShut ? "\u{25B6}" : "\u{25BC}").font(.system(size: 8)).foregroundStyle(p.muted).frame(width: 9)
                    Text(name).font(.system(size: 12)).foregroundStyle(p.textDim).lineLimit(1)
                    if isShut { Text(String(count)).font(.system(size: 10)).foregroundStyle(p.muted) }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3).padding(.leading, 14)
                .contentShape(Rectangle())
                .help("Not one of your Phases — the image these were built on")
                .onTapGesture { toggle("base:" + name) }
            case .phase(let ph, let depth, let via, let kids, let hidden):
                PhaseListRow(profile: profile, phase: ph, groupKey: gk, depth: depth, via: via,
                             chevron: AnyView(chev(ph.name, kids, shutNow.contains("\(profile.proxy)|\(ph.name)"))),
                             count: hidden > 0 ? "+\(hidden)" : nil, window: window)
            }
        }
        PhaseAddTrailer(profile: profile, folders: false, window: window)
    }

    /// ▼ on anything with Phases under it.
    @ViewBuilder private func chev(_ name: String, _ count: Int, _ isShut: Bool) -> some View {
        if count == 0 { Color.clear.frame(width: 9, height: 9) }
        else {
            Text(isShut ? "\u{25B6}" : "\u{25BC}").font(.system(size: 8)).foregroundStyle(Theme.shared.p.muted).frame(width: 9)
                .contentShape(Rectangle())
                .help(isShut ? "Show the \(count) built on it" : "Hide what was built on it")
                .onTapGesture { toggle(name) }
        }
    }
}
