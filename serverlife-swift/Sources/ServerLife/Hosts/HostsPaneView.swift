import AppKit
import SwiftUI

/// hostspane.js `render`: toolbar, then the group's hosts (or saved
/// profiles) as List, Boxes or Table, in folders or flat.
struct HostsPaneView: View {
    @ObservedObject var model: HostsPaneModel

    /// What one render draws: hosts (or, for "Saved", profiles), all and filtered.
    private struct Listing {
        var all: [Host] = []
        var shown: [Host] = []
        var profiles: [JSON] = []
        var profilesAll = 0
        var loading = false
        var error: String?
    }

    private var isProfiles: Bool { model.groupKey == "profiles" }

    private func listing() -> Listing {
        let kind = HostsHooks.hostKindShown()
        let q = model.filter.trimmed.isEmpty ? nil : Tags.compileQuery(model.filter)
        if isProfiles {
            let ps = HostsData.profiles.filter { HostsHooks.inKind(Host(json: $0), kind) }
            let shown = q.map { q in ps.filter { q.match(Host(json: $0)) } } ?? ps
            return Listing(profiles: shown, profilesAll: ps.count)
        }
        let here = model.hostsFor()
        // Watched hosts that have left the inventory are drawn here too: this
        // pane is the fleet view, and "what is missing" is a fleet question.
        let all = (here.hosts + HostsHooks.missingIn(model.groupKey, here.hosts)).filter { HostsHooks.inKind($0, kind) }
        let shown = q.map { q in all.filter { q.match($0) } } ?? all
        return Listing(all: all, shown: shown, loading: here.loading, error: here.error)
    }

    var body: some View {
        let p = Theme.shared.p
        let groups = HostsPane.paneGroups()
        let l = listing()
        VStack(spacing: 0) {
            toolbar(groups, l)
            p.borderSoft.frame(height: 1)
            ScrollView {
                Group {
                    if l.loading {
                        empty("Reading that cluster…")
                    } else if let e = l.error {
                        VStack(spacing: 8) {
                            Text(e).foregroundStyle(p.amber)
                            MiscHint(text: "A leaf is read with its own tsh ls; the certificate for the root has to be good.")
                        }
                        .font(.system(size: 12.5)).frame(maxWidth: .infinity).padding(.vertical, 30).padding(.horizontal, 12)
                    } else if isProfiles {
                        profilesContent(l.profiles)
                    } else {
                        content(l.shown)
                    }
                }
                .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 14)
            }
        }
        .background(p.bg)
        // The original re-read a stale leaf (30 s) on any redraw: a filter
        // keystroke, a folder write, an inventory event, a preference.
        .task(id: renderKey) { model.ensureFetched(groups) }
    }

    private var renderKey: String {
        let st = Store.shared
        return [model.groupKey, model.filter, String(Inventory.shared.generation), String(HostsPane.requestableOn),
                String(HostsPane.foldersOn), st.setting("hostsPaneView", "list"), String(model.landed),
                String(HostsPane.profilesOn), HostsHooks.hostKindShown(),
                String(st.settingJSON("hostFolders").hashValue), String(st.settingJSON("folderMembers").hashValue)]
            .joined(separator: "|")
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.shared.p.muted)
            .frame(maxWidth: .infinity).padding(.vertical, 30).padding(.horizontal, 12)
    }

    // MARK: Toolbar

    private func toggle(_ label: String, _ on: Bool, _ help: String, _ action: @escaping () -> Void) -> some View {
        let p = Theme.shared.p
        return Button(label, action: action)
            .buttonStyle(GhostButtonStyle(small: true))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? p.accent : Color.clear))
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? p.accentDim : Color.clear))
            .help(help)
    }

    private func toolbar(_ groups: [FolderGroup], _ l: Listing) -> some View {
        let p = Theme.shared.p
        let req = HostsPane.requestableOn, folders = HostsPane.foldersOn, box = HostsPane.boxView
        let table = HostsPane.tableView, cols = HostsPane.labelColumnsOn, saved = HostsPane.profilesOn
        let profiles = isProfiles
        let kind = HostsHooks.hostKindShown()
        // Name, Status, Heartbeat, or a label key seen on this group's own hosts.
        let sortOptions: [(value: String, label: String)] = [
            ("name", "Sort: Name"), ("status", "Sort: Status"), ("heartbeat", "Sort: Heartbeat (quietest first)"),
        ] + HostsPane.labelKeysIn(l.all).map { ("label:" + $0, "Sort: \($0)") }
        let cur = HostsPane.sortPref.value
        let sortValue = sortOptions.contains { $0.value == cur } ? cur : "name"
        let refreshHelp = profiles ? "Re-read the saved profile list"
            : HostsPane.leafOf(model.groupKey) != nil ? "Re-read this leaf cluster’s nodes"
            : "Re-read this cluster or config file — the same ⟳ the sidebar heading makes"
        let total = profiles ? l.profilesAll : l.all.count
        let shownCount = profiles ? l.profiles.count : l.shown.count
        return HFlow(spacing: 7) {
            HSelect(options: groups.map { g in
                let icon = HostsHooks.clusterIcon(g.key)
                return (g.key, (icon.isEmpty ? "" : icon + " ") + g.label)
            }, selection: Binding(get: { model.groupKey }, set: { model.setGroup($0, groups: groups) }))
            .frame(width: 220)
            Button(model.refreshing ? "Refreshing…" : "Refresh") { model.refreshCurrent(groups) }
                .buttonStyle(.ghostSmall).disabled(model.refreshing).help(refreshHelp)
            if !profiles {
                toggle("Requestable", req, req ? "Also listing what this cluster would let you ask for — click to show only what you hold"
                       : "Also list what this cluster would let you ask for, tagged req") {
                    HostsPane.setPref("hostsPaneRequestable", .bool(!req))
                }
            }
            toggle("Saved", saved, saved ? "Also listing saved profiles as their own group — click to hide them"
                   : "Also list every saved profile (SFTP, VNC, RDP, serial, telnet…) as its own group") {
                HostsPane.setPref("hostsPaneProfiles", .bool(!saved))
            }
            toggle("Folders", folders, folders ? "Showing the folder arrangement — click for the plain list"
                   : "Showing every host in one list — click for the folders") {
                HostsPane.setPref("hostsPaneFolders", .bool(!folders))
            }
            HStack(spacing: 2) {
                toggle("List", !box && !table, "One row per host") { HostsPane.setPref("hostsPaneView", "list") }
                toggle("Boxes", box, "Tiles, for scanning a lot of them") { HostsPane.setPref("hostsPaneView", "box") }
                toggle("Table", table, "Columns, for sorting and scanning a lot of them at once") {
                    HostsPane.setPref("hostsPaneView", "table")
                }
            }
            // Breaking labels into their own columns is a table idea.
            if table {
                toggle("Label columns", cols, cols
                       ? "Labels most of these hosts share are their own columns — click for one combined Labels column"
                       : "Break out the labels most of these hosts share into their own sortable columns") {
                    HostsPane.setPref("hostsPaneLabelColumns", .bool(!cols))
                }
            }
            if !profiles && !HostsPane.kubeOff {
                HStack(spacing: 4) {
                    ForEach([("all", "All"), ("ssh", "SSH"), ("kube", "K8s")], id: \.0) { k, label in
                        toggle(label, kind == k, k == "all" ? "SSH hosts and Kubernetes clusters"
                               : k == "ssh" ? "SSH hosts only" : "Kubernetes clusters only") {
                            HostsHooks.setHostKind(k)
                        }
                    }
                }
            }
            if !profiles {
                HSelect(options: sortOptions, selection: Binding(get: { sortValue }, set: { v in
                    HostsPane.setSort(v.hasPrefix("label:")
                        ? .init(mode: "label", labelKey: String(v.dropFirst(6))) : .init(mode: v))
                }))
                .frame(width: 190)
                .help("Order hosts by name, status, heartbeat (the longest quiet first), or a label’s value — "
                      + "picking a label clusters the same value together, e.g. every env=prod row")
            }
            HField(placeholder: "Filter — env=prod, name~^web, tag:gpu", text: $model.filter).frame(width: 260)
            Text(l.loading ? "reading…" : FolderBits.countText(shownCount, total))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(p.muted)
                .frame(height: 22)
            if !profiles {
                Button("New folder…") {
                    FolderDialogs.openFolderDialog(model.window, group: model.groupKey, hosts: l.all)
                }.buttonStyle(.ghostSmall)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(p.panel)
    }

    // MARK: Hosts

    private func capNotice(_ total: Int) -> some View {
        HStack(spacing: 4) {
            Text("Showing \(HostsPane.rowCap.formatted()) of \(total.formatted()) hosts. ")
                .font(.system(size: 12.5)).foregroundStyle(Theme.shared.p.muted)
            Button("Show all") { model.showAllRows = true }
                .buttonStyle(.ghostSmall)
                .help("Draw every one of them — a redraw this big can take a moment, and typing in the filter will too")
            Spacer()
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
    }

    @ViewBuilder private func content(_ shown: [Host]) -> some View {
        if shown.isEmpty {
            empty(model.filter.isEmpty ? "No hosts in this group." : "Nothing matches that filter.")
        } else {
            // Sorted once, up front: folders and Unfiled keep that order.
            let sorted = HostsPane.sortHosts(shown)
            let capped = sorted.count > HostsPane.rowCap && !model.showAllRows
            let hosts = capped ? Array(sorted.prefix(HostsPane.rowCap)) : sorted
            // Columns come from what is about to be drawn, capped or not.
            let cols = HostsPane.labelColumnsOn ? Tags.mostCommonLabelKeys(hosts) : []
            VStack(alignment: .leading, spacing: 0) {
                if capped { capNotice(sorted.count) }
                if !HostsPane.foldersOn {
                    rowsFor(hosts, depth: 0, folder: nil, order: hosts.map(FolderModel.hostKey), cols: cols)
                } else {
                    let sections = arranged(hosts)
                    let order = sections.flatMap { $0.hosts.map(FolderModel.hostKey) }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                            if let f = s.folder, s.isHead {
                                folderHead(f, depth: s.depth, count: s.count)
                            } else if s.isHead {
                                unfiledHead(s.count)
                            } else {
                                rowsFor(s.hosts, depth: s.depth, folder: s.folder, order: order, cols: cols)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Folder heads and their rows, then Unfiled — in the order drawn.
    private struct Section { var isHead: Bool; var folder: HostFolder?; var depth: Int; var count: Int; var hosts: [Host] }

    private func arranged(_ hosts: [Host]) -> [Section] {
        var out: [Section] = []
        func walk(_ parent: String?, _ depth: Int) {
            for f in FolderModel.folders(in: model.groupKey, parent: parent) {
                let deep = FolderModel.hostsInTree(f, hosts)
                if !model.filter.isEmpty && deep.isEmpty { continue }
                out.append(Section(isHead: true, folder: f, depth: depth, count: deep.count, hosts: []))
                if model.shut.contains(f.id) { continue }
                let mine = FolderModel.hostsInFolder(f, hosts)
                if !mine.isEmpty { out.append(Section(isHead: false, folder: f, depth: depth + 1, count: 0, hosts: mine)) }
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        let loose = hosts.filter { !FolderModel.isFiled($0, model.groupKey) }
        if !loose.isEmpty {
            out.append(Section(isHead: true, folder: nil, depth: 0, count: loose.count, hosts: []))
            out.append(Section(isHead: false, folder: nil, depth: 0, count: 0, hosts: loose))
        }
        return out
    }

    private func folderHead(_ folder: HostFolder, depth: Int, count: Int) -> some View {
        let p = Theme.shared.p
        let shut = model.shut.contains(folder.id)
        let colour = FolderBits.color(folder)
        let target = model.dropTarget == folder.id
        return HStack(spacing: 7) {
            Text(shut ? "▶" : "▼").font(.system(size: 8)).foregroundStyle(p.muted)
            Text(FolderModel.folderIcon(folder, open: !shut)).font(.system(size: 12))
            Text(folder.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(target ? Color.white : (colour ?? p.textDim))
            if !folder.rule.isEmpty { SmallTag(kind: .rule, text: "rule") }
            Text(String(count)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(p.muted)
            Spacer()
        }
        .padding(.vertical, 4).padding(.trailing, 8).padding(.leading, 4 + CGFloat(depth) * 18)
        .background(RoundedRectangle(cornerRadius: 6).fill(target ? p.accentDim : Color.clear))
        .overlay(alignment: .leading) { (colour ?? .clear).frame(width: 2) }
        .padding(.top, 10).padding(.bottom, 5)
        .contentShape(Rectangle())
        .onTapGesture { if shut { model.shut.remove(folder.id) } else { model.shut.insert(folder.id) } }
        .help(folder.rule.isEmpty ? "Drop hosts here to file them" : "Fills itself with: \(folder.rule)")
        // A folder heading is a drop target: this pane is a place to do the filing.
        .folderDrop(canDrop: { model.dragging != nil && HostsDrag.isFrom(model) },
                    onTarget: { model.dropTarget = $0 ? folder.id : (model.dropTarget == folder.id ? nil : model.dropTarget) },
                    onDrop: { model.drop(on: folder) })
    }

    private func unfiledHead(_ count: Int) -> some View {
        let p = Theme.shared.p
        return HStack(spacing: 7) {
            Text("—").font(.system(size: 12))
            Text("Unfiled").font(.system(size: 12)).foregroundStyle(p.muted)
            Text(String(count)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(p.muted)
            Spacer()
        }
        .foregroundStyle(p.textDim)
        .padding(.vertical, 4).padding(.horizontal, 6)
        .padding(.top, 10).padding(.bottom, 5)
    }

    /// The chosen layout for a list of hosts — a table only in Table view.
    @ViewBuilder private func rowsFor(_ hosts: [Host], depth: Int, folder: HostFolder?, order: [String], cols: [String]) -> some View {
        if HostsPane.tableView {
            table(hosts, depth: depth, folder: folder, order: order, cols: cols)
        } else if HostsPane.boxView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 7)], alignment: .leading, spacing: 7) {
                ForEach(hosts, id: \.id) { h in HostsPaneCard(model: model, host: h, folder: folder, order: order) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(hosts, id: \.id) { h in HostsPaneCard(model: model, host: h, folder: folder, order: order) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        }
    }

    /// Name / Status / Heartbeat / Address / [label columns] / Labels. A header
    /// click sorts by that column; a second click turns the order round.
    private func table(_ hosts: [Host], depth: Int, folder: HostFolder?, order: [String], cols: [String]) -> some View {
        let p = Theme.shared.p
        let cur = HostsPane.sortPref
        func col(_ label: String, _ pref: HostsPane.SortPref?) -> AnyView {
            let active = pref.map { cur.mode == $0.mode && ($0.mode != "label" || cur.labelKey == $0.labelKey) } ?? false
            let text = Text(label + (active ? (cur.desc ? " ▼" : " ▲") : ""))
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(active ? p.text : p.muted).lineLimit(1)
            guard let pref else { return AnyView(text) }
            return AnyView(text.contentShape(Rectangle())
                .onTapGesture {
                    var next = pref
                    if active { next = cur; next.desc = !cur.desc }
                    HostsPane.setSort(next)
                }
                .help(active ? "Click to reverse the order" : "Sort by \(label)"))
        }
        return LazyVStack(alignment: .leading, spacing: 1) {
            HPTableLine(name: col("Name", .init(mode: "name")), status: col("Status", .init(mode: "status")),
                        beat: col("Heartbeat", .init(mode: "heartbeat")), addr: col("Address", nil),
                        cols: cols.map { col($0, .init(mode: "label", labelKey: $0)) }, labels: col("Labels", nil))
                .padding(.horizontal, 9).padding(.vertical, 4)
            ForEach(hosts, id: \.id) { h in HostsPaneTableRow(model: model, host: h, folder: folder, order: order, cols: cols) }
        }
        .padding(.leading, CGFloat(depth) * 18)
    }

    // MARK: Saved profiles

    /// Saved profiles by the profile's own folder (as the Saved tab groups
    /// them), Unfiled last.
    @ViewBuilder private func profilesContent(_ profiles: [JSON]) -> some View {
        if profiles.isEmpty {
            empty(model.filter.isEmpty ? "No saved profiles yet." : "No matching profiles.")
        } else if !HostsPane.foldersOn {
            profileRows(profiles, depth: 0, order: profiles.map(HostsPane.profileKey))
        } else {
            let fid = { (p: JSON) in p["folderId"].truthy ? p["folderId"].stringish ?? "" : "" }
            let folders = HostsData.profileFolders.compactMap { f -> (JSON, [JSON])? in
                let id = f["id"].stringish ?? ""
                let items = profiles.filter { !id.isEmpty && fid($0) == id }
                return items.isEmpty ? nil : (f, items)
            }
            let known = Set(folders.map { $0.0["id"].stringish ?? "" })
            let loose = profiles.filter { !known.contains(fid($0)) }
            let order = folders.flatMap { $0.1.map(HostsPane.profileKey) } + loose.map(HostsPane.profileKey)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(folders.enumerated()), id: \.offset) { _, entry in
                    profileFolderHead(entry.0, count: entry.1.count)
                    profileRows(entry.1, depth: 1, order: order)
                }
                if !loose.isEmpty {
                    unfiledHead(loose.count)
                    profileRows(loose, depth: 0, order: order)
                }
            }
        }
    }

    private func profileFolderHead(_ folder: JSON, count: Int) -> some View {
        let p = Theme.shared.p
        let hex = folder["color"].string ?? ""
        let colour: Color? = hex.isEmpty ? nil : (hex.hasPrefix("#") ? Color(hex: hex) : HostColor.color(hex))
        let icon = folder["icon"].string?.nilIfEmpty ?? "\u{1F4C1}"
        return HStack(spacing: 7) {
            Text(icon).font(.system(size: 12))
            Text(folder["name"].stringish ?? "").font(.system(size: 12, weight: .semibold)).foregroundStyle(colour ?? p.textDim)
            Text(String(count)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(p.muted)
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .overlay(alignment: .leading) { (colour ?? .clear).frame(width: 2) }
        .padding(.top, 10).padding(.bottom, 5)
    }

    @ViewBuilder private func profileRows(_ profiles: [JSON], depth: Int, order: [String]) -> some View {
        if HostsPane.boxView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 7)], alignment: .leading, spacing: 7) {
                ForEach(Array(profiles.enumerated()), id: \.offset) { _, pr in HostsPaneProfileCard(model: model, profile: pr, order: order) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(profiles.enumerated()), id: \.offset) { _, pr in HostsPaneProfileCard(model: model, profile: pr, order: order) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        }
    }
}

/// One table line's columns, shared by the header and every row.
struct HPTableLine: View {
    let name: AnyView
    let status: AnyView
    let beat: AnyView
    let addr: AnyView
    let cols: [AnyView]
    let labels: AnyView
    var body: some View {
        HStack(spacing: 8) {
            name.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading).layoutPriority(2)
            status.frame(width: 110, alignment: .leading)
            beat.frame(width: 104, alignment: .leading)
            addr.frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                c.frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            }
            labels.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
        }
    }
}
