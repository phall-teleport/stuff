import AppKit
import SwiftUI

/// beams.js (0.28 → 0.38.1), the parts beside the beams that are not the
/// Phase builder, picker or add-ins (owner `phases`): which tab a beams
/// cluster shows (beams | phases | failed), the Phase and failed-build lists
/// read for it, the name rule, a beam's Services…, and the hooks into the
/// `phase-*` actions. The Phase list views themselves (Folders / List /
/// Relationships), a Phase's history and menu, and New Phase are the phases
/// owner's — `BeamsPhasesPane` hosts them, with a flat list standing in
/// until those actions are registered.
///
/// Action contract used here (registered by phases):
/// - `phase-new-build` — args `profileKey`, `mode` ("base"/"from"/"fork"), `source`.
/// - `phase-builder` — args `profileKey`, `from`.
/// - `phase-picker` — args `profileKey`, `phases` [BeamPhase], `value`,
///   `standard` (label for "no Phase"), `typed` Bool, `onChange` (String) -> Void;
///   `reply` an `AnyView`.
/// - `phase-list-view` — args `profileKey`, `mode` ("folders"/"list"/"relationship");
///   `reply` an `AnyView` (the rows, with their menus and the add trailer).
/// - `phase-details` — args `profileKey` (or `proxy`/`home`), `name`.
/// - `phase-edit` — args `profileKey`, `name`.
@MainActor
@Observable
final class BeamPhaseLists {
    static let shared = BeamPhaseLists()

    struct PhaseList: Equatable {
        var ok = true
        var phases: [BeamPhase] = []
        var error: String?
        var loading = false
        var at: Double?
    }

    struct FailedList: Equatable {
        var ok = true
        var failed: [FailedPhase] = []
        var error: String?
        var loading = false
        var at: Double?
    }

    enum Tab: String { case beams, phases, failed }

    private(set) var phaseLists: [String: PhaseList] = [:]
    private(set) var failedLists: [String: FailedList] = [:]
    /// For this run only, as the original's `beamTabs` Map.
    private(set) var tabs: [String: Tab] = [:]
    @ObservationIgnored private var hooked = false

    /// A list already read stays current with the beams around it.
    func hookBeams() {
        if hooked { return }
        hooked = true
        Inventory.shared.onBeams.append { [weak self] in
            guard let self else { return }
            for (proxy, _) in self.phaseLists where Inventory.shared.phasesSupported(proxy) {
                if let p = Inventory.shared.profiles.first(where: { $0.proxy == proxy }) {
                    Task { await self.refreshPhases(p) }
                }
            }
        }
    }

    func phasesSupported(_ proxy: String) -> Bool { Inventory.shared.phasesSupported(proxy) }
    func phaseList(_ proxy: String) -> PhaseList? { phaseLists[proxy] }
    func failedList(_ proxy: String) -> FailedList? { failedLists[proxy] }

    /// `beamTabFor`.
    func tab(for proxy: String) -> Tab { phasesSupported(proxy) ? (tabs[proxy] ?? .beams) : .beams }

    /// `setBeamTab`: the Phase list is read the first time it is looked at,
    /// not for every cluster at launch.
    func setTab(_ p: TeleportProfile, _ tab: Tab) {
        tabs[p.proxy] = tab
        if tab == .phases && phaseLists[p.proxy] == nil { Task { await refreshPhases(p) } }
        if tab == .failed { Task { await refreshFailed(p) } }
    }

    /// `refreshPhases`: `tsh phase ls`, for one cluster.
    func refreshPhases(_ p: TeleportProfile) async {
        let proxy = p.proxy
        guard phasesSupported(proxy) else { return }
        var cur = phaseLists[proxy] ?? PhaseList()
        cur.loading = true
        phaseLists[proxy] = cur
        let r = await Beams.phases(proxy: proxy, home: p.homeDir)
        phaseLists[proxy] = PhaseList(ok: r.ok, phases: r.ok ? r.items : (r.items.isEmpty ? cur.phases : r.items),
                                      error: r.error, loading: false, at: nowMs())
        if !r.ok { phaseLists[proxy]?.phases = [] }
        // A refreshed Phase list may have new failures behind it — the
        // Failed tab only shows when there are some.
        await refreshFailed(p)
        Actions.shared.perform("phase-list-read", args: ["proxy": proxy, "phases": r.items])
    }

    /// `refreshFailedPhases`: `tsh phase ls-failed`, for one cluster.
    func refreshFailed(_ p: TeleportProfile) async {
        let proxy = p.proxy
        guard phasesSupported(proxy) else { return }
        var cur = failedLists[proxy] ?? FailedList()
        cur.loading = true
        failedLists[proxy] = cur
        let r = await Beams.failedPhases(proxy: proxy, home: p.homeDir)
        failedLists[proxy] = FailedList(ok: r.ok, failed: r.ok ? r.items : [], error: r.error, loading: false, at: nowMs())
    }

    /// `removePhase`: after saying what that does and does not take with it.
    @discardableResult
    func removePhase(_ p: TeleportProfile, _ phase: BeamPhase, window: WindowModel?) async -> Bool {
        guard await MiscUI.confirm(window, title: "Delete Phase \(phase.name)?",
                                   message: "The saved image goes, and nothing new can start from it.",
                                   detail: "Beams already started from it keep running. Phases forked from it may stop rebuilding.",
                                   confirmLabel: "Delete it", danger: true) else { return false }
        TUIStatus.show("Deleting Phase \(phase.name)…", ms: 0)
        let r: TshOutput
        do { r = try await Beams.removePhase(name: phase.name, proxy: p.proxy, home: p.homeDir) }
        catch { r = TshOutput(ok: false, output: error.localizedDescription) }
        TUIStatus.clear()
        if !r.ok { TUIStatus.toast(r.output.nilIfEmpty ?? "Could not delete \(phase.name)", "error", ms: 9000) }
        else { TUIStatus.toast("Deleted Phase \(phase.name)", "success") }
        await refreshPhases(p)
        return r.ok
    }

    #if DEBUG
    func _setForTests(proxy: String, phases: PhaseList? = nil, failed: FailedList? = nil, tab: Tab? = nil) {
        if let phases { phaseLists[proxy] = phases }
        if let failed { failedLists[proxy] = failed }
        if let tab { tabs[proxy] = tab }
    }
    #endif
}

extension BeamsUI {
    // MARK: Phase names

    /// What tsh accepts as a Phase name — a DNS label, the same rule
    /// phasesetup.js enforces for a setup stage's name.
    static let phaseNameMax = 54

    /// `phaseNameProblem`: why a name would not be accepted, or "" if it
    /// would be (empty included — tsh picks one then).
    nonisolated static func phaseNameProblem(_ name: String) -> String {
        if name.isEmpty { return "" }
        let ok = name.range(of: #"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"#, options: .regularExpression) != nil
        if !ok || name.count > 54 {
            return "\"\(name)\" is not a valid Phase name — lowercase letters, digits and hyphens, "
                + "starting and ending with a letter or digit, up to 54 characters"
        }
        return ""
    }

    /// `name@sha256:…` and `name` both name the Phase `name`.
    nonisolated static func phaseName(_ ref: String) -> String {
        String(ref.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The cluster a beam belongs to, as a profile (for its Phase list).
    static func profile(of b: Beam) -> TeleportProfile? {
        Inventory.shared.profiles.first { $0.proxy == b.proxy && ($0.homeDir ?? nil) == (b.home ?? nil) }
            ?? Inventory.shared.profiles.first { $0.proxy == b.proxy }
    }

    /// The beam menu's Phase line: which image it is (beams.js `beamMenu`).
    static func phaseMenuItems(_ b: Beam, window: WindowModel?) -> [CtxItem] {
        let supported = Inventory.shared.phasesSupported(b.proxy)
        if !b.phase.isEmpty {
            if supported, BeamPhaseLists.shared.phaseList(b.proxy) == nil, let p = profile(of: b) {
                Task { await BeamPhaseLists.shared.refreshPhases(p) }
            }
            let name = phaseName(b.phase)
            let parts = b.phase.split(separator: "@", maxSplits: 1).map(String.init)
            var lineage = name
            Actions.shared.perform("phase-lineage", window: window,
                                   args: ["proxy": b.proxy, "name": b.phase, "reply": { (v: Any?) in
                                       if let s = v as? String, !s.isEmpty { lineage = s }
                                   }])
            let snap = parts.count > 1 ? "snapshot " + String(parts[1].prefix(19)) : "latest snapshot when started"
            return [CtxItem("From Phase \(name)…", icon: "\u{2630}", sub: lineage + " \u{00B7} " + snap) {
                showPhaseDetails(proxy: b.proxy, home: b.home, name: b.phase, window: window)
            }, .sep]
        }
        // Said only where tsh reports a beam's Phase; an older one cannot tell.
        if supported { return [CtxItem("Standard image (no Phase)", disabled: true, title: "Started without --phase"), .sep] }
        return [.sep]
    }

    static func showPhaseDetails(proxy: String, home: String?, name: String, window: WindowModel?) {
        var args: [String: Any] = ["proxy": proxy, "name": name]
        if let home { args["home"] = home }
        if let p = Inventory.shared.profiles.first(where: { $0.proxy == proxy }) { args["profileKey"] = p.key }
        Actions.shared.perform("phase-details", window: window, args: args)
    }

    // MARK: Services…

    /// `showBeamServices`: the services running in a Beam — from its Phase's
    /// `services:` — and each one's log.
    static func showServices(_ b: Beam, window: WindowModel? = nil) async {
        let r: TshList<BeamService>
        do { r = try await Beams.beamServices(name: b.id, proxy: b.proxy, home: b.home) }
        catch { r = .failed(error.localizedDescription) }
        guard r.ok else {
            TUIStatus.toast(r.error ?? "Could not read its services", "error", ms: 9000)
            return
        }
        let m = BeamServicesModel(b, services: r.items)
        TUIModal.show(window, title: "Services in \(b.id)", width: 760) { handle in BeamServicesView(m: m, handle: handle) }
    }

    // MARK: Into the phases owner's actions

    static func newPhase(_ p: TeleportProfile, mode: String = "base", source: String = "", window: WindowModel?) {
        Actions.shared.perform("phase-new-build", window: window, args: ["profileKey": p.key, "mode": mode, "source": source])
    }

    static func phaseBuilder(_ p: TeleportProfile, from: String = "", window: WindowModel?) {
        Actions.shared.perform("phase-builder", window: window, args: ["profileKey": p.key, "from": from])
    }
}

// MARK: - Services dialog

@MainActor
final class BeamServicesModel: ObservableObject {
    let b: Beam
    let services: [BeamService]
    @Published var log = "Pick a service to read its log."
    init(_ b: Beam, services: [BeamService]) { self.b = b; self.services = services }

    func show(_ svc: String) {
        log = "Reading \(svc)…"
        Task { @MainActor in
            let l: TshOutput
            do { l = try await Beams.beamServiceLogs(name: b.id, service: svc, proxy: b.proxy, home: b.home) }
            catch { l = TshOutput(ok: false, output: error.localizedDescription) }
            log = l.output.nilIfEmpty ?? "(no output yet)"
        }
    }
}

private struct BeamServicesView: View {
    @ObservedObject var m: BeamServicesModel
    let handle: ModalHandle
    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Services in \(m.b.id)", subtitle: "beam-init, from the Phase\u{2019}s services", scroll: true) {
            VStack(alignment: .leading, spacing: 4) {
                if m.services.isEmpty {
                    MiscHint(text: "No services — its Phase declares none.")
                } else {
                    ForEach(m.services, id: \.name) { s in
                        HStack(spacing: 8) {
                            Text(s.name).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            TUITag(text: s.status)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { m.show(s.name) }
                    }
                }
                ScrollView {
                    Text(m.log).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 360)
                .background(p.panel2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                .padding(.top, 8)
            }
        } footer: {
            Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
        .frame(width: 760)
    }
}

// MARK: - The tabs beside a cluster's beams (sidebar.js beamSection)

/// "beams | phases | failed" for a beams cluster whose tsh can do Phases;
/// the sidebar draws it in place of its plain "beams" heading.
struct BeamTabsHeader: View {
    let profile: TeleportProfile
    let beamCount: Int

    var body: some View {
        let st = BeamPhaseLists.shared
        let tab = st.tab(for: profile.proxy)
        let failed = st.failedList(profile.proxy)
        HStack(spacing: 6) {
            tabButton(.beams, "beams", beamCount, tab)
            tabButton(.phases, "phases", st.phaseList(profile.proxy)?.phases.count ?? 0, tab)
            // Only when there are any (or while it is the tab being looked at).
            if (failed?.failed.count ?? 0) > 0 || tab == .failed {
                tabButton(.failed, "failed", failed?.failed.count ?? 0, tab)
            }
            Spacer(minLength: 0)
            if tab != .beams {
                Button("\u{27F3}") {
                    Task {
                        if tab == .failed { await st.refreshFailed(profile) } else { await st.refreshPhases(profile) }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.shared.p.muted)
                .help(tab == .failed ? "Read the failed builds again (tsh phase ls-failed)" : "Read the Phases again (tsh phase ls)")
            }
        }
        .onAppear {
            st.hookBeams()
            // Whether the Failed tab shows depends on there being any.
            if st.phasesSupported(profile.proxy) && st.failedList(profile.proxy) == nil {
                Task { await st.refreshFailed(profile) }
            }
        }
    }

    private func tabButton(_ id: BeamPhaseLists.Tab, _ label: String, _ n: Int, _ cur: BeamPhaseLists.Tab) -> some View {
        let p = Theme.shared.p
        return Button { BeamPhaseLists.shared.setTab(profile, id) } label: {
            HStack(spacing: 4) {
                Text(label.uppercased()).kerning(0.8).font(.system(size: 10, weight: .semibold))
                if n > 0 { Text(String(n)).font(.system(size: 10)).foregroundStyle(p.muted) }
            }
            .foregroundStyle(cur == id ? p.text : p.muted)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(cur == id ? p.panel3 : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

/// The phases / failed tab's body. Phases: the phases owner's view
/// (`phase-list-view`), Folders / List / Relationships; until that exists, a
/// flat list. Failed: `tsh phase ls-failed`, one row per failed snapshot.
struct BeamsPhasesPane: View {
    let profile: TeleportProfile
    weak var window: WindowModel?

    var body: some View {
        let st = BeamPhaseLists.shared
        switch st.tab(for: profile.proxy) {
        case .beams: EmptyView()
        case .failed: failedRows(st.failedList(profile.proxy))
        case .phases:
            VStack(alignment: .leading, spacing: 2) {
                modeTabs
                phaseRows(st.phaseList(profile.proxy))
            }
        }
    }

    /// `phasesViewMode`: Folders (the default), a flat list, or the build lineage.
    private var mode: String { Store.shared.setting("phasesView", "folders") }

    private var modeTabs: some View {
        let p = Theme.shared.p
        let cur = mode
        return HStack(spacing: 6) {
            ForEach([("folders", "Folders"), ("list", "List"), ("relationship", "Relationships")], id: \.0) { id, label in
                Button { Store.shared.setSetting("phasesView", id) } label: {
                    Text(label).font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(cur == id ? p.text : p.muted)
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(cur == id ? p.panel3 : Color.clear))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }.padding(.leading, 14)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.shared.p.muted)
            .padding(.leading, 20).padding(.vertical, 3)
    }

    @ViewBuilder private func phaseRows(_ info: BeamPhaseLists.PhaseList?) -> some View {
        if let hosted = hostedView() {
            hosted
        } else if info == nil || (info!.loading && info!.phases.isEmpty) {
            note("Reading Phases (tsh phase ls)…")
        } else if let info, !info.ok {
            note(info.error ?? "Could not read the Phases"); trailer(first: true)
        } else if let info {
            let filter = (window.map { $0.feature(SidebarWindow.self).filterText.trimmed } ?? "").lowercased()
            let list = filter.isEmpty ? info.phases
                : info.phases.filter { "\($0)".lowercased().contains(filter) }
            if info.phases.isEmpty { note("No Phases yet."); trailer(first: true) }
            else if list.isEmpty { note("No Phase matches the filter.") }
            else {
                ForEach(list) { ph in BeamsPhaseRow(profile: profile, phase: ph, window: window) }
                trailer(first: false)
            }
        }
    }

    private func hostedView() -> AnyView? {
        var v: AnyView?
        Actions.shared.perform("phase-list-view", window: window,
                               args: ["profileKey": profile.key, "mode": mode, "reply": { (x: Any?) in v = x as? AnyView }])
        return v
    }

    /// "+ New Phase…" and "+ From setups…" (sidebar.js `phaseAddTrailer`).
    private func trailer(first: Bool) -> some View {
        HStack(spacing: 6) {
            addRow(first ? "+  Build the first Phase…" : "+  New Phase…",
                   help: "tsh phase add: a build console on a build beam, from the default image, on top of a Phase, or forked from one") {
                BeamsUI.newPhase(profile, window: window)
            }
            addRow("+  From setups…",
                   help: "Pick setups — Go, Postgres, the AWS CLI, your dotfiles, a repo to clone — into a phase.yaml, and build it with tsh phase apply") {
                BeamsUI.phaseBuilder(profile, window: window)
            }
        }
    }

    private func addRow(_ text: String, help: String, _ action: @escaping () -> Void) -> some View {
        let p = Theme.shared.p
        return HStack(spacing: 6) {
            Circle().fill(p.accent).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(p.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.leading, 14)
        .contentShape(Rectangle())
        .help(help)
        .onTapGesture(perform: action)
    }

    @ViewBuilder private func failedRows(_ info: BeamPhaseLists.FailedList?) -> some View {
        if info == nil || (info!.loading && info!.failed.isEmpty) {
            note("Reading failed builds (tsh phase ls-failed)\u{2026}")
        } else if let info, !info.ok {
            note(info.error ?? "Could not read the failed builds")
        } else if let info, info.failed.isEmpty {
            note("No failed builds.")
        } else if let info {
            ForEach(Array(info.failed.enumerated()), id: \.offset) { _, f in
                BeamsFailedRow(profile: profile, f: f, window: window)
            }
        }
    }
}

/// The stand-in Phase row (sidebar.js `phaseRow`, without folders).
private struct BeamsPhaseRow: View {
    let profile: TeleportProfile
    let phase: BeamPhase
    weak var window: WindowModel?

    var body: some View {
        let p = Theme.shared.p
        let ready = phase.state == "ready"
        let failed = phase.state.range(of: "fail|error", options: [.regularExpression, .caseInsensitive]) != nil
        HStack(spacing: 6) {
            Circle().fill(ready ? p.green : failed ? p.red : p.amber).frame(width: 7, height: 7)
            Text(phase.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            TUITag(text: phase.state.isEmpty ? "?" : phase.state, kind: ready ? .plain : failed ? .gone : .stale)
            if !phase.parent.isEmpty { TUITag(text: phase.parent) }
            if let at = phase.publishedAt { TUITag(text: HostWatch.goneFor(at) + " ago") }
        }
        .padding(.vertical, 3).padding(.leading, 20).padding(.trailing, 6)
        .contentShape(Rectangle())
        .help([phase.name,
               phase.parent.isEmpty ? "" : "from: " + phase.parent,
               phase.state.isEmpty ? "" : "state: " + phase.state,
               phase.region.isEmpty ? "" : "region: " + phase.region,
               phase.digest.isEmpty ? "" : "snapshot: " + phase.digest,
               phase.publishedAt.map { "saved: " + HostWatch.localeString($0) } ?? "",
               phase.owner.isEmpty ? "" : "owner: " + phase.owner,
               phase.lastError.isEmpty ? "" : "\n" + phase.lastError,
               ready ? "\nDouble-click to start a beam from it" : ""].filter { !$0.isEmpty }.joined(separator: "\n"))
        .onTapGesture(count: 2) {
            if ready { Task { await BeamsUI.start(profile, phase: phase.name, window: window) } }
        }
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        Button("History and beams…") {
            BeamsUI.showPhaseDetails(proxy: profile.proxy, home: profile.homeDir, name: phase.name, window: window)
        }
        Divider()
        Button("Start a beam from it…") { Task { await BeamsUI.start(profile, phase: phase.name, window: window) } }
            .disabled(phase.state != "ready")
        Divider()
        Button("Fork into a new Phase…") { BeamsUI.newPhase(profile, mode: "fork", source: phase.name, window: window) }
        Button("Build a new Phase on top of it…") { BeamsUI.newPhase(profile, mode: "from", source: phase.name, window: window) }
        Button("Add setups on top of it…") { BeamsUI.phaseBuilder(profile, from: phase.name, window: window) }
            .disabled(phase.state != "ready")
        if !phase.buildBeam.isEmpty {
            Divider()
            Button("Open its build Beam") {
                BeamsUI.open(Beam(id: phase.buildBeam, uuid: "", owner: "", region: "", requestedRegion: "", url: "",
                                  proxy: profile.proxy, home: profile.homeDir), window: window)
            }
        }
        Divider()
        Button("Copy name") { Clipboard.write(phase.name); TUIStatus.show("Copied \(phase.name)") }
        if !phase.digest.isEmpty {
            Button("Copy snapshot (name@digest)") {
                Clipboard.write("\(phase.name)@\(phase.digest)"); TUIStatus.show("Copied the snapshot reference")
            }
        }
        Divider()
        Button("Delete Phase…") { Task { await BeamPhaseLists.shared.removePhase(profile, phase, window: window) } }
    }
}

/// sidebar.js `failedRows` / beams.js `failedMenu`.
private struct BeamsFailedRow: View {
    let profile: TeleportProfile
    let f: FailedPhase
    weak var window: WindowModel?

    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 6) {
            Circle().fill(p.red).frame(width: 7, height: 7)
            Text(f.phase).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if !f.digest.isEmpty {
                TUITag(text: String(f.digest.replacingOccurrences(of: "sha256:", with: "").prefix(10)), kind: .gone)
            }
            if let at = f.at { TUITag(text: HostWatch.goneFor(at) + " ago") }
        }
        .padding(.vertical, 3).padding(.leading, 20).padding(.trailing, 6)
        .contentShape(Rectangle())
        .help(["\(f.phase) \u{2014} a build that failed",
               f.digest.isEmpty ? "" : "snapshot: " + f.digest,
               f.at.map { "observed: " + HostWatch.localeString($0) } ?? "",
               f.expires.map { "kept until about: " + HostWatch.localeString($0) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n"))
        .contextMenu {
            Text("\(f.phase) \u{00B7} failed")
            Button("History and beams of the Phase\u{2026}") {
                BeamsUI.showPhaseDetails(proxy: profile.proxy, home: profile.homeDir, name: f.phase, window: window)
            }
            if !f.digest.isEmpty {
                Button("Copy the failed snapshot (name@digest)") {
                    let ref = "\(f.phase)@\(f.digest)"
                    Clipboard.write(ref); TUIStatus.show("Copied " + ref)
                }
            }
            Button("Edit the Phase in a build console\u{2026}") {
                Actions.shared.perform("phase-edit", window: window, args: ["profileKey": profile.key, "name": f.phase])
            }
        }
    }
}
