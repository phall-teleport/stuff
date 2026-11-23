import AppKit
import SwiftUI

/// hostspane.js: a cluster's hosts, given the whole pane — the same
/// inventory as the sidebar with the room it needs, in a real pane that
/// splits, sits beside a terminal and closes like anything else.
///
/// Three things it can be told, all remembered (settings): folders on or
/// off (`hostsPaneFolders`), rows or tiles (`hostsPaneView` "list"/"box"),
/// and whether to list what the cluster would let you ask for
/// (`hostsPaneRequestable`). Plus a filter in the usual query language.
@MainActor
enum HostsPane {
    /// Leaf clusters read on demand: pane key → (when, nodes, error).
    static var leafNodes: [String: (at: Double, nodes: [Host], error: String?)] = [:]
    static let leafTTL: Double = 30000
    /// A render past this many rows is a visible stall; "Show all" is one click away.
    static let rowCap = 500

    static var boxView: Bool { Store.shared.setting("hostsPaneView", "list") == "box" }
    static var tableView: Bool { Store.shared.setting("hostsPaneView", "list") == "table" }
    /// Only meaningful in Table view — a stale `true` must not change List or Boxes.
    static var labelColumnsOn: Bool { tableView && Store.shared.settingJSON("hostsPaneLabelColumns") == .bool(true) }
    static var foldersOn: Bool { Store.shared.settingJSON("hostsPaneFolders") != .bool(false) }
    /// Off by default: a cluster can offer far more than you hold.
    static var requestableOn: Bool { Store.shared.settingJSON("hostsPaneRequestable") == .bool(true) }
    /// Also off by default — a "Saved" group of every saved profile is extra.
    static var profilesOn: Bool { Store.shared.settingJSON("hostsPaneProfiles") == .bool(true) }
    static var kubeOff: Bool { Store.shared.settingJSON("kubeEnabled") == .bool(false) }

    static func setPref(_ key: String, _ value: JSON) { Store.shared.updateSettings([key: value]) }

    // MARK: Live panes

    private final class WeakModel { weak var model: HostsPaneModel?; init(_ m: HostsPaneModel) { model = m } }
    private static var live: [WeakModel] = []

    static func remember(_ m: HostsPaneModel) {
        live.removeAll { $0.model == nil || $0.model?.closed == true }
        live.append(WeakModel(m))
    }

    /// `pickedHostsOf(paneId)`: whichever hosts are picked in this pane, so a
    /// bare split (⌘⇧D/⌘⇧E, no host named) on a hosts pane targets the host
    /// selected there instead of a disconnected local shell.
    static func pickedHostsOf(_ paneId: String) -> [Host] {
        guard let m = live.lazy.compactMap(\.model).first(where: { !$0.closed && $0.pane?.id == paneId }) else { return [] }
        return m.shownHosts().filter { m.picked.contains(FolderModel.hostKey($0)) }
    }

    /// `openHostsPane({ groupKey, dir })`: a new tab, or beside the focused pane.
    static func open(_ window: WindowModel?, groupKey: String? = nil, split: String? = nil) {
        let groups = paneGroups()
        guard !groups.isEmpty else { return HToast.error("No clusters or ssh hosts to show yet") }
        let key = groupKey.flatMap { k in groups.contains { $0.key == k } ? k : nil } ?? groups[0].key
        let label = groups.first { $0.key == key }?.label ?? "Hosts"
        let w = window ?? WindowManager.shared.current()
        let model = HostsPaneModel(window: w, groupKey: key)
        var args: [String: Any] = [
            "title": "Hosts · \(label)", "isHosts": true, "hostsGroup": key,
            "view": { AnyView(HostsPaneView(model: model)) } as () -> AnyView,
            "onClose": { model.closed = true } as () -> Void,
        ]
        if let split { args["split"] = split }
        Actions.shared.perform("open-view-pane", window: w, args: args)
        // The pane just made is the focused one: keep it, so its title can follow the cluster.
        if let pane = w.feature(SessionsWindow.self).activePane, pane.isHosts { model.pane = pane }
        remember(model)
    }

    /// Everything the pane can be pointed at: the folder groups, plus every
    /// leaf cluster behind each Teleport one, as `root › leaf`, plus "Saved"
    /// when that toggle is on and there are profiles.
    static func paneGroups() -> [FolderGroup] {
        var out: [FolderGroup] = []
        for g in HostsHooks.folderGroups() {
            out.append(g)
            if g.kind != "teleport" { continue }
            guard let p = Inventory.shared.profiles.first(where: { FolderModel.groupKey(for: $0) == g.key }) else { continue }
            for leaf in HostsHooks.leavesFor(p) where leaf.name != p.cluster {
                out.append(FolderGroup(key: "\(g.key)::\(leaf.name)", label: "\(g.label) \u{203A} \(leaf.name)", kind: "leaf",
                                       proxy: p.proxy, home: p.homeDir, cluster: leaf.name))
            }
        }
        // Every saved profile, as one more group to point the pane at.
        if profilesOn && !HostsData.profiles.isEmpty {
            out.append(FolderGroup(key: "profiles", label: "Saved", kind: "profiles"))
        }
        return out
    }

    /// A selection key naming a leaf, or nil for an ordinary group.
    static func leafOf(_ key: String) -> (group: String, cluster: String)? {
        guard let r = key.range(of: "::") else { return nil }
        return (String(key[..<r.lowerBound]), String(key[r.upperBound...]))
    }

    /// The cluster a pane is pointed at, as proxy, home and cluster name.
    static func clusterOf(_ groupKey: String, _ groups: [FolderGroup]) -> FolderGroup? {
        if let g = groups.first(where: { $0.key == groupKey }), g.proxy != nil { return g }
        guard let p = Inventory.shared.profiles.first(where: { FolderModel.groupKey(for: $0) == groupKey }) else { return nil }
        return FolderGroup(key: groupKey, label: p.cluster, kind: "teleport", proxy: p.proxy, home: p.homeDir, cluster: p.cluster)
    }

    /// Kubernetes clusters, host-shaped, for a root Teleport group — filtered
    /// by this pane's own Requestable toggle, so one setting governs
    /// everything the pane shows.
    static func kubeHostsFor(_ groupKey: String) -> [Host] {
        guard let p = Inventory.shared.profiles.first(where: { FolderModel.groupKey(for: $0) == groupKey }) else { return [] }
        return HostsHooks.kubeHostsForProfile(p).filter { requestableOn || $0.extra["requestable"]?.truthy != true }
    }

    // MARK: Sorting

    struct SortPref: Equatable {
        var mode: String
        var labelKey: String?
        var desc = false
        var value: String { mode == "label" && labelKey != nil ? "label:" + labelKey! : mode }
    }

    static var sortPref: SortPref {
        let j = Store.shared.settingJSON("hostsPaneSort")
        return SortPref(mode: j["mode"].string ?? "name", labelKey: j["labelKey"].string, desc: j["desc"].truthy)
    }

    static func setSort(_ s: SortPref) {
        var o: JSON = ["mode": .string(s.mode)]
        if let k = s.labelKey { o["labelKey"] = .string(k) }
        if s.desc { o["desc"] = true }
        setPref("hostsPaneSort", o)
    }

    nonisolated static func nameOf(_ h: Host) -> String { h.name.nilIfEmpty ?? h.alias ?? "" }

    private static func before(_ a: String, _ b: String) -> Bool? {
        let r = a.localizedCompare(b)
        return r == .orderedSame ? nil : r == .orderedAscending
    }

    /// Lower sorts first: connected, the normal ones, stale, gone, requestable.
    static func statusRank(_ h: Host) -> Int {
        if FolderBits.connected(h) { return 0 }
        if h.extra["missing"]?.truthy == true { return 3 }
        if HostsHooks.heartbeat(h)?.stale == true { return 2 }
        if h.extra["requestable"]?.truthy == true { return 4 }
        return 1
    }

    /// Every label key across the list, most common first.
    static func labelKeysIn(_ hosts: [Host]) -> [String] {
        var counts: [String: Int] = [:]
        var first: [String] = []
        for h in hosts {
            for e in Tags.labelEntries(h) {
                if counts[e.key] == nil { first.append(e.key) }
                counts[e.key, default: 0] += 1
            }
        }
        // Stable on ties: first seen first, as the JS Map's sort keeps them.
        return first.enumerated().sorted { a, b in
            let x = counts[a.element]!, y = counts[b.element]!
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// Hosts in the chosen order — Name, Status, Heartbeat (the longest quiet
    /// first) or a label's value; a host missing that label sorts last.
    static func sortHosts(_ hosts: [Host], _ pref: SortPref? = nil) -> [Host] {
        let pref = pref ?? sortPref
        var list = hosts.enumerated().map { $0 }
        func byName(_ a: Host, _ b: Host, _ ia: Int, _ ib: Int) -> Bool { before(nameOf(a), nameOf(b)) ?? (ia < ib) }
        switch pref.mode {
        case "heartbeat":
            let info = list.map { e -> (at: Double?, quiet: Bool) in
                let h = e.element
                if h.extra["kind"]?.string == "kube" { return HostsHooks.kubeBeatTime(h) }
                return (Heartbeat.heartbeatAt(h), HostsHooks.heartbeat(h)?.stale == true)
            }
            list.sort { a, b in
                let x = info[a.offset], y = info[b.offset]
                if x.quiet != y.quiet { return x.quiet }
                if (x.at == nil) != (y.at == nil) { return x.at != nil }
                let xa = x.at ?? 0, ya = y.at ?? 0
                if xa != ya { return xa < ya }
                return byName(a.element, b.element, a.offset, b.offset)
            }
        case "status":
            list.sort { a, b in
                let x = statusRank(a.element), y = statusRank(b.element)
                return x != y ? x < y : byName(a.element, b.element, a.offset, b.offset)
            }
        case "label" where pref.labelKey != nil:
            let key = pref.labelKey!
            func value(_ h: Host) -> String? { Tags.labelEntries(h).first { $0.key == key }?.value }
            list.sort { a, b in
                let va = value(a.element), vb = value(b.element)
                switch (va, vb) {
                case (nil, nil): return byName(a.element, b.element, a.offset, b.offset)
                case (nil, _): return false
                case (_, nil): return true
                default: return before(va!, vb!) ?? byName(a.element, b.element, a.offset, b.offset)
                }
            }
        default:
            list.sort { a, b in byName(a.element, b.element, a.offset, b.offset) }
        }
        let out = list.map(\.element)
        // Turned round from the table's header (a second click on its column).
        return pref.desc ? out.reversed() : out
    }

    static func profileKey(_ p: JSON) -> String { "profile:" + (p["id"].stringish ?? "") }

    /// sidebar.js `profileKindLabel`, as the pane's profile card shows it.
    static func profileKind(_ p: JSON) -> String {
        ["sftp": "sftp", "teleport": "tsh", "serial": "serial", "telnet": "telnet", "vnc": "vnc", "rdp": "rdp"][p["type"].string ?? ""] ?? "ssh"
    }
}

@MainActor
final class HostsPaneModel: ObservableObject {
    weak var window: WindowModel?
    weak var pane: SessionPane?
    var closed = false
    @Published var groupKey: String
    @Published var filter = ""
    @Published var picked = Set<String>()
    var lastKey: String?
    @Published var shut = Set<String>()
    @Published var dropTarget: String?
    @Published var fetching = false
    /// Bumped when a background read lands.
    @Published var landed = 0
    // Requestable: fetched once per (proxy, home) until the toggle or cluster changes.
    var reqKey: String?
    var reqAt: Double?
    var reqFetching = false
    var reqHosts: [Host] = []
    var reqError: String?
    var dragging: [String]?
    /// Opting into the full, uncapped render; reset when the group changes.
    @Published var showAllRows = false
    @Published var refreshing = false

    init(window: WindowModel?, groupKey: String) {
        self.window = window
        self.groupKey = groupKey
    }

    func setGroup(_ key: String, groups: [FolderGroup]) {
        groupKey = key
        picked = []
        // A different group can be a wildly different scale.
        showAllRows = false
        let label = groups.first { $0.key == key }?.label ?? "Hosts"
        pane?.title = "Hosts · \(label)"
        pane?.hostsGroup = key
    }

    /// Start whatever background reads the current selection needs.
    func ensureFetched(_ groups: [FolderGroup]) {
        if groupKey == "profiles" { return }
        if HostsPane.requestableOn, let g = HostsPane.clusterOf(groupKey, groups), let proxy = g.proxy {
            let key = "\(proxy)\u{0}\(g.home ?? "")"
            if (reqKey != key || reqAt == nil) && !reqFetching {
                reqFetching = true
                Task { @MainActor in
                    let r = await HostsHooks.requestableHosts(proxy, g.home, g.cluster)
                    reqHosts = r.hosts
                    reqError = r.error
                    reqFetching = false
                    reqKey = key
                    reqAt = nowMs()
                    landed += 1
                }
            }
        }
        guard HostsPane.leafOf(groupKey) != nil else { return }
        let key = groupKey
        let cached = HostsPane.leafNodes[key]
        let fresh = cached.map { nowMs() - $0.at < HostsPane.leafTTL } ?? false
        if !fresh && !fetching, let g = groups.first(where: { $0.key == key }) {
            fetching = true
            Task { @MainActor in
                let r = await Teleport.listNodes(proxy: g.proxy, cluster: g.cluster, home: g.home)
                HostsPane.leafNodes[key] = (nowMs(), r.ok ? r.items : [], r.ok ? nil : (r.error ?? "that cluster would not answer"))
                fetching = false
                landed += 1
            }
        }
    }

    /// The hosts for the selection: the sidebar's own list for a cluster it
    /// draws, the cached `tsh ls` for a leaf, plus anything askable.
    func hostsFor() -> (hosts: [Host], loading: Bool, error: String?) {
        _ = landed
        // Saved profiles are drawn from the store; none of the rest applies.
        if groupKey == "profiles" { return ([], false, nil) }
        let askable = HostsPane.requestableOn ? reqHosts : []
        func withAskable(_ list: [Host]) -> [Host] {
            if askable.isEmpty { return list }
            // Anything already reachable wins.
            let have = Set(list.compactMap(\.uuid))
            return list + askable.filter { !have.contains($0.uuid ?? "") }
        }
        guard HostsPane.leafOf(groupKey) != nil else {
            return (withAskable(HostsHooks.hostsInGroup(groupKey)) + HostsPane.kubeHostsFor(groupKey), false, nil)
        }
        let cached = HostsPane.leafNodes[groupKey]
        return (withAskable(cached?.nodes ?? []), cached == nil, cached?.error)
    }

    /// Everything the pane draws — so a dragged requestable or missing row
    /// is found again on the drop.
    func shownHosts() -> [Host] {
        let held = hostsFor().hosts
        return held + HostsHooks.missingIn(groupKey, held)
    }

    func pick(_ k: String, order: [String]) {
        FolderBits.pick(k, picked: &picked, last: &lastKey, order: order)
    }

    func startDrag(_ k: String) {
        if !picked.contains(k) { picked = [k] }
        dragging = Array(picked)
    }

    func drop(on folder: HostFolder) {
        guard let keys = dragging, HostsDrag.isFrom(self) else { return }
        dragging = nil
        let list = shownHosts().filter { keys.contains(FolderModel.hostKey($0)) }
        let g = groupKey
        Task { @MainActor in
            guard let r = await FolderModel.fileHostsInto(list, folder, g) else { return }
            StatusBus.shared.show("\(r.count) host\(r.count == 1 ? "" : "s") \(r.mode == "move" ? "moved to" : "added to") \(folder.name)")
        }
    }

    /// What "Refresh" means for the group: a leaf drops its cached `tsh ls`;
    /// a root cluster or an ssh config file gets the sidebar heading's ⟳.
    func refreshCurrent(_ groups: [FolderGroup]) {
        if refreshing { return }
        refreshing = true
        let key = groupKey
        Task { @MainActor in
            if key == "profiles" {
                // The store is the profile list; a redraw is the re-read.
            } else if HostsPane.leafOf(key) != nil {
                HostsPane.leafNodes[key] = nil
            } else if let g = groups.first(where: { $0.key == key }), g.kind == "ssh" {
                await Inventory.shared.refreshSshConfigs(key: g.key)
            } else if let p = Inventory.shared.profiles.first(where: { FolderModel.groupKey(for: $0) == key }) {
                await Inventory.shared.refreshProfile(p)
            } else {
                await Inventory.shared.refresh()
            }
            refreshing = false
            landed += 1
        }
    }

    /// Right-click a row in any layout. A multi-selection gets its own small
    /// menu (a bulk "Request access…"); a kube cluster gets its own.
    func rowMenu(_ host: Host, folder: HostFolder?) {
        let k = FolderModel.hostKey(host)
        if !picked.contains(k) { picked = [k]; lastKey = k }
        let w = window
        if picked.count > 1 {
            let chosen = shownHosts().filter { picked.contains(FolderModel.hostKey($0)) }
            // Bulk requesting stays SSH-node-only.
            let reqable = chosen.filter { $0.extra["requestable"]?.truthy == true && $0.extra["kind"]?.string != "kube" }
            CtxMenu.build([CtxItem("Request access to \(reqable.count) node\(reqable.count == 1 ? "" : "s")…", disabled: reqable.isEmpty) {
                HostsHooks.requestAccessForMany(reqable, window: w)
            }]).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        if host.extra["kind"]?.string == "kube" {
            let g = groupKey
            if host.extra["requestable"]?.truthy == true {
                CtxMenu.build([
                    .heading(host.name),
                    CtxItem("Request access to it…") { Actions.shared.perform("kube-request-access", window: w, host: host) },
                    CtxItem("Request a namespace or pod…") { Actions.shared.perform("kube-request-resource", window: w, host: host) },
                    .sep,
                    CtxItem(HostsHooks.isWatched(host) ? "Stop watching this cluster" : "Watch this cluster") {
                        HostWatch.toggleWatch(host, g)
                    },
                ]).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                return
            }
            let menu = NSMenu()
            menu.autoenablesItems = false
            Actions.shared.perform("kube-host-menu", window: w, host: host, args: ["menu": menu, "groupKey": g])
            if !menu.items.isEmpty { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
            return
        }
        HostsHooks.showHostMenu(host, folder: folder, groupKey: groupKey, window: w)
    }

    func open(_ host: Host) {
        // A kube cluster is host-shaped only for folders, filter and drag: its
        // own open (browse a context, log in to an available one) and its
        // request are kube-ui's.
        if host.extra["kind"]?.string == "kube" {
            if host.extra["requestable"]?.truthy == true {
                return Actions.shared.perform("kube-request-access", window: window, host: host)
            }
            return Actions.shared.perform("kube-host-open", window: window, host: host)
        }
        // A requestable node cannot be opened, so the double-click asks for it.
        if host.extra["requestable"]?.truthy == true { return HostsOpen.requestAccess(host, window: window) }
        if host.extra["missing"]?.truthy == true {
            return HToast.error("\(host.name) is not in the inventory any more — last seen \(HostsHooks.goneFor(host.extra["missingSince"]?.double)) ago")
        }
        // The host list's own open: the pinned or remembered account, and the
        // MFA route where the node needs one.
        HostsOpen.openFromList(host, window: window)
    }
}

