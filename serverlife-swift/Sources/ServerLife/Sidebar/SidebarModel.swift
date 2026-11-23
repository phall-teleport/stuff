import SwiftUI

/// Per-window sidebar state (each Electron renderer had its own): which tab,
/// the filter, collapsed groups and folders, and the hosts ticked for
/// multi-exec (`state.checkedHosts`, which fleet reads).
@MainActor
@Observable
final class SidebarWindow: WindowFeature {
    @ObservationIgnored weak var window: WindowModel?

    /// hosts | saved | teleport
    var tab = "hosts"
    /// profiles | macros | s3
    var savedView = "profiles"
    /// What the filter box holds (raw, as typed).
    var filterField = ""
    /// The filter in force (trimmed; set 120 ms after typing stops).
    private(set) var filterText = ""
    @ObservationIgnored private(set) var filterMatch = Tags.compileQuery("")
    /// All/SSH/K8s — which kind of resource the Resources (Hosts) tab shows.
    /// Only reachable, and only shown, while KubeLife is enabled. One choice
    /// for the sidebar and every Hosts pane in the window (`setHostKind`).
    private(set) var hostKindFilter = "all"
    /// Closed group headings and closed folders, kept in settings so a
    /// restart opens the sidebar the way it was left rather than spreading
    /// every cluster out again. Folder ids are stable; group keys are the
    /// cluster or file key.
    var collapsed: Set<String> {
        get { Set(SB.store.setting("sidebarClosedGroups", [String]())) }
        set { SB.store.setSetting("sidebarClosedGroups", newValue.sorted()) }
    }
    var foldersShut: Set<String> {
        get { Set(SB.store.setting("sidebarClosedFolders", [String]())) }
        set { SB.store.setSetting("sidebarClosedFolders", newValue.sorted()) }
    }
    /// Host ids ticked for multi-exec.
    var checkedHosts: Set<String> = []
    /// What the Hosts tab last drew, by host id (sidebar.js `drawnHosts`).
    @ObservationIgnored var drawnHosts: [String: Host] = [:]
    /// The ticked hosts, resolved back to hosts (`checkedHostObjects`).
    var checkedHostObjects: [Host] { checkedHosts.compactMap { drawnHosts[$0] ?? SB2.hostById($0) } }
    /// Bumped when something drawn changed outside observation (requestable rows arriving).
    var tick = 0

    @ObservationIgnored let debounce = Debouncer(0.12)

    required init(window: WindowModel) { self.window = window }

    /// Set the host filter from anywhere — the box, a chip, the tag browser —
    /// keeping the field, the parsed query and the list in step.
    func setFilter(_ text: String, fromInput: Bool = false) {
        let t = text.trimmed
        filterMatch = Tags.compileQuery(t)
        filterText = t
        if !fromInput { filterField = t }
    }

    /// The field changed: apply after a short pause, as the original's debounce.
    func fieldChanged(_ value: String) {
        debounce.call { [weak self] in self?.setFilter(value, fromInput: true) }
    }

    func filterByTag(_ key: String, _ value: String) {
        setFilter(Tags.toggleTerm(filterText, Tags.termFor(key, value)))
    }

    func toggleTerm(_ term: String) { setFilter(Tags.toggleTerm(filterText, term)) }

    func hostMatches(_ h: Host) -> Bool { filterMatch.match(h) }

    /// `setHostKind`: all | ssh | kube, anything else is all.
    func setHostKind(_ kind: String) {
        hostKindFilter = ["all", "ssh", "kube"].contains(kind) ? kind : "all"
    }

    /// `hostKindShown`: SSH only while KubeLife is off.
    var hostKindShown: String {
        if !SBKube.enabled { return "ssh" }
        return hostKindFilter
    }

    /// `applyKubeEnabledSetting`: switched off while filtered to K8s, there
    /// is nothing left to show it, so fall back to the full list rather than
    /// an empty one with no visible cause.
    func applyKubeEnabled() {
        if !SBKube.enabled && hostKindFilter == "kube" { hostKindFilter = "all" }
    }

    /// `inKindShown`: whether a row belongs under the All/SSH/K8s filter.
    /// Ghosts drawn from watch records carry a `kube:` id rather than a kind.
    func inKindShown(_ h: Host) -> Bool {
        let k = hostKindShown
        if k == "all" { return true }
        let kube = SBKube.isKubeHost(h)
        return k == "kube" ? kube : !kube
    }

    /// `matches(text)` for the saved lists: a plain substring test.
    func matches(_ text: String?) -> Bool {
        filterText.isEmpty || (text ?? "").lowercased().contains(filterText.lowercased())
    }

    func toggleChecked(_ id: String) {
        if checkedHosts.contains(id) { checkedHosts.remove(id) } else { checkedHosts.insert(id) }
    }
}

/// The requestable nodes of each group, fetched on demand and kept briefly
/// (sidebar.js `reqCache`): a search is a round trip to the proxy.
@MainActor
@Observable
final class SBRequestableCache {
    static let shared = SBRequestableCache()
    static let ttlMs: Double = 120000
    private(set) var revision = 0
    @ObservationIgnored private var entries: [String: (at: Double, hosts: [Host], fetching: Bool)] = [:]

    func forget(_ key: String) { entries.removeValue(forKey: key) }

    /// The requestable nodes of one cluster, or an empty list while the
    /// answer is on its way (the redraw when it lands puts them on screen).
    func hosts(for p: TeleportProfile) -> [Host] {
        _ = revision
        let key = FolderModel.groupKey(for: p)
        guard HostPrefs.showRequestable(key) else { return [] }
        let hit = entries[key]
        if let hit, nowMs() - hit.at < Self.ttlMs { return hit.hosts }
        if hit?.fetching != true {
            entries[key] = (hit?.at ?? 0, hit?.hosts ?? [], true)
            Task { @MainActor in
                let r = await Requestable.hosts(proxy: p.proxy, home: p.homeDir.nilIfEmpty, cluster: p.cluster)
                self.entries[key] = (nowMs(), r.hosts, false)
                self.revision += 1
            }
        }
        return hit?.hosts ?? []
    }
}

/// One `ssh_config` file the list draws a group for.
struct SBConfigRoot: Hashable {
    var file: String
    var label: String
    var primary: Bool
    var exists: Bool
    var key: String { primary ? "ssh" : "ssh:" + file }
}

/// A group that can hold folders (`folderGroups`).
struct SBFolderGroup: Hashable {
    var key: String
    var label: String
    var kind: String
}

/// The host list's shared logic (sidebar.js), independent of any one window.
@MainActor
enum SB2 {
    static var inv: Inventory { Inventory.shared }

    /// `configRoots`: the files to draw a group for, never empty.
    static func configRoots() -> [SBConfigRoot] {
        let files = inv.sshConfigFiles
        if !files.isEmpty { return files.map { SBConfigRoot(file: $0.file, label: $0.label, primary: $0.primary, exists: $0.exists) } }
        return [SBConfigRoot(file: "", label: "~/.ssh/config", primary: true, exists: true)]
    }

    static func sshHosts(of root: SBConfigRoot, _ list: [Host]) -> [Host] {
        list.filter { ($0.configRoot ?? "") == root.file || (root.primary && ($0.configRoot ?? "").isEmpty) }
    }

    /// Every group that can hold folders.
    static func folderGroups() -> [SBFolderGroup] {
        var out: [SBFolderGroup] = []
        for p in inv.profiles where !p.expired {
            out.append(SBFolderGroup(key: FolderModel.groupKey(for: p), label: p.cluster.nilIfEmpty ?? p.proxy, kind: "teleport"))
        }
        for r in configRoots() { out.append(SBFolderGroup(key: r.key, label: r.label, kind: "ssh")) }
        return out
    }

    /// The hosts a group is made of — the list the sidebar draws, before the filter.
    static func hostsInGroup(_ groupKey: String) -> [Host] {
        if groupKey.isEmpty { return [] }
        if groupKey.hasPrefix("tp:") {
            for p in inv.profiles where FolderModel.groupKey(for: p) == groupKey { return inv.nodes(for: p) }
            return []
        }
        let roots = configRoots()
        let root = groupKey == "ssh" ? roots.first { $0.primary } : roots.first { "ssh:" + $0.file == groupKey }
        guard let root else { return [] }
        return sshHosts(of: root, inv.sshHosts)
    }

    /// Which group's list a host is drawn in — the scope its folders live in.
    static func groupKeyForHost(_ host: Host?) -> String {
        guard let host else { return "" }
        if host.type == Host.teleport {
            let p = inv.profiles.first { $0.cluster == host.cluster && ($0.home?.nilIfEmpty) == (host.home?.nilIfEmpty) }
            return p.map { FolderModel.groupKey(for: $0) } ?? ""
        }
        if host.type != Host.ssh { return "" }
        let roots = configRoots()
        guard let root = roots.first(where: { $0.file == (host.configRoot ?? "") }) ?? roots.first(where: { $0.primary }) else { return "" }
        return root.key
    }

    /// A group key that names a real list (not the Starred or Watched gatherings).
    static func realGroupKey(_ key: String?, for host: Host) -> String {
        if let key, !key.isEmpty, key != "starred", key != "gone" { return key }
        return groupKeyForHost(host)
    }

    /// Find the host descriptor for an id (nodes, then ssh_config hosts).
    static func hostById(_ id: String) -> Host? {
        for list in inv.nodesByKey.values { if let n = list.first(where: { $0.id == id }) { return n } }
        return inv.sshHosts.first { $0.id == id }
    }

    /// Every starred host that still exists, in the order starred.
    static func starredHosts() -> [Host] {
        var byId: [String: Host] = [:]
        for n in inv.allNodes { byId[n.id] = n }
        for h in inv.sshHosts { byId[h.id] = h }
        return HostPrefs.starredIds.compactMap { byId[$0] }
    }

    /// Quiet: stopped heartbeating, or watched and gone/unchecked.
    static func isQuiet(_ h: Host) -> Bool { h.watchMissing || h.watchUnconfirmed || Heartbeat.isStale(h) }

    /// Hidden, quiet filter, then the query.
    static func visibleHost(_ h: Host, _ sw: SidebarWindow) -> Bool {
        if HostPrefs.isHidden(h) && !HostPrefs.showHiddenHosts { return false }
        let quiet = Heartbeat.quietFilter
        if quiet == "hide" && isQuiet(h) && !h.watchMissing && !h.watchUnconfirmed { return false }
        if quiet == "only" && !isQuiet(h) { return false }
        return sw.hostMatches(h)
    }

    /// Every watched host that is missing, drawn in a group or orphaned.
    static func allGhosts() -> [Host] {
        let groups = folderGroups()
        return groups.flatMap { HostWatch.missingIn($0.key, hostsInGroup($0.key)) } + HostWatch.orphanGhosts(groups.map(\.key))
    }

    static func quietCount(_ sw: SidebarWindow) -> Int {
        (inv.allNodes + allGhosts()).filter { isQuiet($0) && sw.hostMatches($0) }.count
    }

    static func goneCount(_ sw: SidebarWindow) -> Int { allGhosts().filter { sw.hostMatches($0) }.count }

    /// The label a human would actually sort by.
    static let labelPriority = ["env", "environment", "tier", "role", "service", "app", "team", "region", "az", "os"]

    static func lastSegment(_ k: String) -> String {
        k.lowercased().split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? k.lowercased()
    }

    /// "dev +9": the most telling label, and how many more.
    static func labelSummary(_ node: Host) -> String {
        let entries = Tags.labelEntries(node)
        if entries.isEmpty { return "" }
        let preferred = labelPriority.lazy.compactMap { k in entries.first { lastSegment($0.key) == k } }.first
        let (k, v) = preferred.map { ($0.key, $0.value) } ?? (entries[0].key, entries[0].value)
        let text = v.count > 12 ? String(v.prefix(11)) + "…" : v
        let shown = text.range(of: "^(true|false)$", options: [.regularExpression, .caseInsensitive]) != nil ? k : text
        return entries.count > 1 ? "\(shown) +\(entries.count - 1)" : shown
    }

    /// The badge after an ssh host's name.
    static func sshLabel(_ h: Host) -> String { h.viaTsh ? "tsh" : (h.proxied ? "proxy" : (h.user ?? "")) }

    /// The connection state of a host's live connection, if any.
    static func connectionState(_ hostId: String) -> ConnState? {
        ConnectionManager.shared.connections.first { $0.hostId == hostId }?.state
    }

    /// Whether tsh itself is missing.
    static func tshMissing() -> Bool { inv.tshMissing }

    /// Windows-only in the original (no OpenSSH client).
    static func sshMissing() -> Bool {
        if let f = inv.toolInfo?["ssh"]["found"].bool { return !f }
        return false
    }

    /// The short name a home is known by.
    static func homeLabel(_ home: String) -> String {
        inv.profiles.first { $0.homeDir == home || $0.home == home }?.homeName.nilIfEmpty ?? home
    }

    /// The saved cluster record behind a live profile (teleportpanel.js `savedClusterFor`).
    static func savedClusterFor(_ p: TeleportProfile) -> JSON? {
        let same = Inventory.savedLogins().filter {
            Teleport.proxyAddress($0["proxy"].stringish) == Teleport.proxyAddress(p.proxy)
                && ($0["home"].stringish ?? "") == (p.home ?? "")
        }
        return same.first { ($0["user"].stringish ?? "") == p.username } ?? same.first
    }
}

// MARK: - Rows

/// One host row's placement.
struct SBHostItem {
    var host: Host
    var label: String
    var groupKey: String?
    var depth: Int = 0
    var folder: HostFolder?
}

/// What the Hosts tab draws, in order.
enum SBItem: Identifiable {
    case host(SBHostItem)
    case folder(HostFolder, count: Int, depth: Int, groupKey: String)
    case more(groupKey: String, hidden: Int)
    case empty(id: String, lines: [String], kind: SBEmptyKind)
    case narrowed(TeleportProfile, granted: Int)
    case expired(TeleportProfile, saved: JSON?)
    case beamHead(TeleportProfile, count: Int)
    case phases(TeleportProfile)
    case kubeLocal
    case beam(Beam)
    case beamAdd(TeleportProfile, first: Bool)
    case local(String)

    var id: String {
        switch self {
        case .host(let h): return "h|\(h.groupKey ?? "")|\(h.folder?.id ?? "")|\(h.host.id)"
        case .folder(let f, _, _, _): return "f|\(f.id)"
        case .more(let k, _): return "more|\(k)"
        case .empty(let id, _, _): return "e|\(id)"
        case .narrowed(let p, _): return "n|\(p.key)"
        case .expired(let p, _): return "x|\(p.key)"
        case .beamHead(let p, _): return "bh|\(p.proxy)"
        case .phases(let p): return "ph|\(p.proxy)"
        case .kubeLocal: return "kube-local"
        case .beam(let b): return "b|\(b.proxy)|\(b.id)"
        case .beamAdd(let p, _): return "ba|\(p.proxy)"
        case .local(let k): return "l|\(k)"
        }
    }
}

/// What an empty-state block offers.
enum SBEmptyKind {
    case plain
    case loading
    case noNodes
    case filterMiss
    case tpError(missing: Bool)
    case noSsh
    case sshEmpty(primary: Bool, showButton: Bool)
}

/// A badge on a group heading.
enum SBGroupTag {
    case home(TeleportProfile)
    case leaf(TeleportProfile)
    case requests(TeleportProfile)
    case expired
    case loggedOut
    case vnet(TeleportProfile)
    case env(TeleportProfile)
    case soon(TeleportProfile)
    case refresh(key: String, title: String, profile: TeleportProfile?)
    case beams(Int)
    case active
    case gathered
    case missingFile(String)
    case extraFile(String)
    case gone(Int)
    case unchecked(Int)
}

struct SBGroup: Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var count: Int
    var profile: TeleportProfile?
    var tags: [SBGroupTag] = []
    var items: [SBItem]
}

/// The panel's entries: groups, and the notes that sit between them.
enum SBEntry: Identifiable {
    case group(SBGroup)
    case note(id: String, lines: [String], kind: SBEmptyKind)
    var id: String {
        switch self {
        case .group(let g): return "G|" + g.key
        case .note(let id, _, _): return "N|" + id
        }
    }
}

@MainActor
extension SB2 {
    /// A group's rows: its folders (nested, with what is in them), then the
    /// hosts not filed anywhere — with watched ghosts first, and the per-group cap.
    static func groupRows(_ groupKey: String, _ hostsIn: [Host], _ sw: SidebarWindow, labelFor: (Host) -> String) -> [SBItem] {
        var rows: [SBItem] = []
        let filtering = !sw.filterText.isEmpty
        let ghosts = (HostWatch.missingIn(groupKey, hostsIn) + HostWatch.requestableIn(groupKey, hostsIn)
            + HostWatch.unconfirmedIn(groupKey, hostsIn)).filter { visibleHost($0, sw) && sw.inKindShown($0) }
        let hosts = ghosts.isEmpty ? hostsIn : ghosts + hostsIn

        func walk(_ parent: String?, _ depth: Int) {
            for f in FolderModel.folders(in: groupKey, parent: parent) {
                let deep = FolderModel.hostsInTree(f, hosts)
                if filtering && deep.isEmpty { continue }
                rows.append(.folder(f, count: deep.count, depth: depth, groupKey: groupKey))
                if sw.foldersShut.contains(f.id) { continue }
                walk(f.id, depth + 1)
                for h in HostPrefs.orderHosts(FolderModel.hostsInFolder(f, hosts), groupKey) {
                    rows.append(.host(SBHostItem(host: h, label: labelFor(h), groupKey: groupKey, depth: depth + 1, folder: f)))
                }
            }
        }
        walk(nil, 0)

        let loose = FolderModel.showFiledHosts ? hosts : hosts.filter { !FolderModel.isFiled($0, groupKey) }
        for h in HostPrefs.orderHosts(loose, groupKey) {
            rows.append(.host(SBHostItem(host: h, label: labelFor(h), groupKey: groupKey)))
        }

        let limit = HostPrefs.hostLimit
        if limit == 0 || filtering { return rows }
        var shown = 0, hidden = 0
        var capped: [SBItem] = []
        for r in rows {
            guard case .host(let item) = r, !item.host.watchMissing else { capped.append(r); continue }
            if shown < limit { capped.append(r); shown += 1 } else { hidden += 1 }
        }
        if hidden > 0 { capped.append(.more(groupKey: groupKey, hidden: hidden)) }
        return capped
    }

    /// The beams inside a cluster's group.
    static func beamItems(_ p: TeleportProfile, _ sw: SidebarWindow) -> [SBItem] {
        guard inv.beamsSupported(p.proxy) else { return [] }
        let all = BeamsUI.visibleBeams(p.proxy)
        let f = sw.filterText.lowercased()
        let list = f.isEmpty ? all : all.filter { JSON.encode($0).text().lowercased().contains(f) }
        if !f.isEmpty && list.isEmpty { return [] }
        var rows: [SBItem] = [.beamHead(p, count: all.count)]
        // Beams | Phases | Failed, as tabs, where this tsh can do Phases.
        if BeamPhaseLists.shared.tab(for: p.proxy) != .beams { return rows + [.phases(p)] }
        rows += list.map { .beam($0) }
        rows.append(.beamAdd(p, first: list.isEmpty))
        return rows
    }

    /// Put the groups in the user's order, each into a slot another occupied,
    /// so the notes between them stay where they were written.
    static func applyGroupOrder(_ entries: [SBEntry]) -> [SBEntry] {
        let order = HostPrefs.groupOrder
        let groups = entries.compactMap { e -> SBGroup? in if case .group(let g) = e { return g }; return nil }
        guard groups.count >= 2, !order.isEmpty else { return entries }
        let orderedKeys = HostPrefs.orderedGroupKeys(groups.map(\.key), order: order)
        var byKey: [String: SBGroup] = [:]
        for g in groups { byKey[g.key] = g }
        var i = 0
        return entries.map { e in
            guard case .group = e else { return e }
            defer { i += 1 }
            return .group(byKey[orderedKeys[i]]!)
        }
    }

    /// The keys of the groups as they are on screen (for reordering).
    static func groupKeysOnScreen(_ sw: SidebarWindow) -> [String] {
        hostsTab(sw).compactMap { e -> String? in if case .group(let g) = e { return g.key }; return nil }
    }
}
