import SwiftUI

/*
 * Choosing a Phase (phasepicker.js): a search box over your Phases as the
 * Phases tab files them — the same folders, opened and closed here, then the
 * unfiled ones — rather than one long dropdown of names. Typing narrows it
 * across every folder and opens the ones with a match.
 *
 * Two ways to hold a value. By default a Phase is picked from the list (and
 * `standard`, when given, is a first row meaning "no Phase"). With `typed`,
 * the box *is* the value as well — for --from and --fork-from, which take
 * any upstream image (default:v1) or an exact name@sha256:… snapshot too —
 * and the list below narrows to what it matches.
 */
@MainActor
final class PhasePickerModel: ObservableObject {
    let profile: TeleportProfile
    let phases: [BeamPhase]
    let standard: String?
    let typed: Bool
    let placeholder: String?
    var onChange: (String) -> Void
    @Published var current: String
    @Published var search: String
    @Published var open: Set<String> = []

    init(profile: TeleportProfile, phases: [BeamPhase], value: String = "", standard: String? = nil, typed: Bool = false,
         placeholder: String? = nil, onChange: @escaping (String) -> Void = { _ in }) {
        self.profile = profile; self.phases = phases; self.standard = standard; self.typed = typed
        self.placeholder = placeholder; self.onChange = onChange
        current = value
        search = typed ? value : ""
        openTo(value)
    }

    var groupKey: String { phaseGroupKey(profile) }
    var hosts: [(Host, BeamPhase)] { phases.map { (phaseHost(profile, $0), $0) } }

    /// The folder holding what is chosen starts open, so the choice is in view.
    func openTo(_ name: String) {
        guard let h = hosts.first(where: { $0.0.name == name })?.0 else { return }
        func walk(_ parent: String?) {
            for f in FolderModel.folders(in: groupKey, parent: parent) where !FolderModel.hostsInTree(f, [h]).isEmpty {
                open.insert(f.id); walk(f.id)
            }
        }
        walk(nil)
    }

    var value: String {
        get { current }
        set { current = newValue; if typed { search = newValue }; openTo(newValue) }
    }

    var query: String { search.trimmed.lowercased() }
    private var exact: Bool { typed && hosts.contains { $0.0.name.lowercased() == query } }

    func matches(_ ph: BeamPhase) -> Bool {
        let q = query
        // A typed value that is exactly a Phase still lists everything: it was picked, not searched for.
        if q.isEmpty || exact { return true }
        return [ph.name, ph.parent, ph.strategy, ph.state, ph.region].contains { $0.lowercased().contains(q) }
    }

    func choose(_ name: String) {
        current = name
        if typed { search = name }
        onChange(name)
    }

    func typedChanged() {
        if typed { current = search.trimmed; onChange(current) }
    }

    enum Row: Identifiable {
        case standard(String), folder(HostFolder, Int, Int, Bool), phase(BeamPhase, Int), empty(String)
        var id: String {
            switch self {
            case .standard: return "std"
            case .folder(let f, _, _, _): return "f:" + f.id
            case .phase(let p, let d): return "p:\(d):" + p.name
            case .empty: return "empty"
            }
        }
    }

    var rows: [Row] {
        let searching = !query.isEmpty && !exact
        var rows: [Row] = []
        if let standard, !searching || standard.lowercased().contains(query) { rows.append(.standard(standard)) }
        let shown = hosts.filter { matches($0.1) }
        let byId = Dictionary(shown.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        let shownHosts = shown.map(\.0)
        func walk(_ parent: String?, _ depth: Int) {
            for f in FolderModel.folders(in: groupKey, parent: parent) {
                let inside = FolderModel.hostsInTree(f, shownHosts)
                if inside.isEmpty { continue }   // nothing of what is shown lives here
                let shut = !searching && !open.contains(f.id)
                rows.append(.folder(f, inside.count, depth, shut))
                if shut { continue }
                walk(f.id, depth + 1)
                for h in FolderModel.hostsInFolder(f, shownHosts) { if let ph = byId[h.id] { rows.append(.phase(ph, depth + 1)) } }
            }
        }
        walk(nil, 0)
        for (h, ph) in shown where !FolderModel.isFiled(h, groupKey) { rows.append(.phase(ph, 0)) }
        if rows.isEmpty {
            rows.append(.empty(typed && !query.isEmpty ? "No Phase by that name — it is used as typed." : "No Phase matches."))
        }
        return rows
    }
}

struct PhasePickerView: View {
    @ObservedObject var m: PhasePickerModel

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 5) {
            TextField(m.placeholder ?? (m.typed ? "A Phase, default:v1 or name@sha256:… — or type to search" : "Search Phases…"),
                      text: $m.search)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                .onChange(of: m.search) { _, _ in m.typedChanged() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(m.rows) { row in rowView(row) }
                }.padding(.vertical, 3)
            }
            .frame(maxHeight: 210)
            .background(p.panel2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
        }
    }

    @ViewBuilder private func rowView(_ row: PhasePickerModel.Row) -> some View {
        let p = Theme.shared.p
        switch row {
        case .standard(let s):
            item(s, active: m.current.isEmpty, depth: 0) { m.choose("") }
        case .folder(let f, let n, let depth, let shut):
            HStack(spacing: 5) {
                Text(shut ? "▸" : "▾").foregroundStyle(p.muted)
                Text("\u{1F4C1} \(f.name)").lineLimit(1)
                Spacer(minLength: 0)
                Text(String(n)).font(.system(size: 10)).foregroundStyle(p.muted)
            }
            .font(.system(size: 12)).foregroundStyle(p.textDim)
            .padding(.leading, 6 + CGFloat(depth) * 14).padding(.trailing, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { if m.open.contains(f.id) { m.open.remove(f.id) } else { m.open.insert(f.id) } }
        case .phase(let ph, let depth):
            item(ph.name, active: ph.name == m.current, depth: depth, ph: ph) { m.choose(ph.name) }
                .help([ph.name, ph.parent.isEmpty ? "" : "from " + ph.parent, ph.state, ph.region]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
        case .empty(let s):
            Text(s).font(.system(size: 11.5)).foregroundStyle(p.muted).padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func item(_ name: String, active: Bool, depth: Int, ph: BeamPhase? = nil, _ tap: @escaping () -> Void) -> some View {
        let p = Theme.shared.p
        return HStack(spacing: 5) {
            Text(name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            if let ph {
                if !ph.strategy.isEmpty { PhaseTag(text: ph.strategy) }
                if !ph.state.isEmpty && ph.state != "ready" { PhaseTag(text: ph.state, kind: .stale) }
                if let at = ph.publishedAt {
                    PhaseTag(text: DateFormatter.localizedString(from: Date(timeIntervalSince1970: at / 1000), dateStyle: .short, timeStyle: .none))
                }
            }
        }
        .foregroundStyle(active ? p.text : p.textDim)
        .padding(.leading, 10 + CGFloat(depth) * 14).padding(.trailing, 8).padding(.vertical, 3)
        .background(active ? p.accentDim : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }
}

/// The original's `.tag` / `.tag.stale` / `.tag.gone` chips.
struct PhaseTag: View {
    enum Kind { case plain, stale, gone }
    let text: String
    var kind: Kind = .plain
    var body: some View {
        let p = Theme.shared.p
        let c = kind == .gone ? p.red : kind == .stale ? p.amber : p.muted
        Text(text).font(.system(size: 10)).foregroundStyle(c).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(p.panel3))
    }
}
