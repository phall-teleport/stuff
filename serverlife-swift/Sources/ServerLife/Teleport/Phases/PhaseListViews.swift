import SwiftUI

/// sidebar.js `phaseRow`: one Phase row — host-shaped only enough to be
/// filed: the folder code neither knows nor needs to know a Phase from an
/// SSH host, the same reason that was already true for a kube cluster.
struct PhaseListRow: View {
    let profile: TeleportProfile
    let phase: BeamPhase
    let groupKey: String
    var depth = 0
    var inFolder = false
    /// nil: show its parent; "": nothing (under its base image's label); else what it was made from.
    var via: String? = nil
    var chevron: AnyView? = nil
    var count: String? = nil
    weak var window: WindowModel?
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let ready = phase.state == "ready"
        let failed = phase.state.range(of: "fail|error", options: [.regularExpression, .caseInsensitive]) != nil
        HStack(spacing: 6) {
            if let chevron { chevron }
            Circle().fill(ready ? p.green : failed ? p.red : p.amber).frame(width: 7, height: 7)
            Text(phase.name).font(.system(size: 12)).lineLimit(1).foregroundStyle(hover.on ? p.text : p.textDim)
            if let count { Text(count).font(.system(size: 10)).foregroundStyle(p.muted) }
            Spacer(minLength: 0)
            PhaseTag(text: phase.state.isEmpty ? "?" : phase.state, kind: ready ? .plain : failed ? .gone : .stale)
            // In the Relationships view, what it was made from — tsh's own `parent`
            // names only the base image, which is the one thing that view already shows.
            if let via, !via.isEmpty { PhaseTag(text: via) }
            else if via == nil, !phase.parent.isEmpty { PhaseTag(text: phase.parent) }
            if let at = phase.publishedAt { PhaseTag(text: HostWatch.goneFor(at) + " ago") }
        }
        .padding(.vertical, 3).padding(.leading, 20 + CGFloat(depth) * 16).padding(.trailing, 6)
        .background(hover.on ? p.panel2 : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
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
        .sbContextMenu { PhaseRuns.phaseMenu(profile, phase, groupKey: groupKey, window: window) }
        // Minimal drag — just enough for a folder row's own drop target to
        // catch it, the same drag an SSH host makes; no reordering.
        .onDrag { SBDrag.begin(.host(id: phaseHost(profile, phase).id, groupKey: groupKey, host: phaseHost(profile, phase))) }
    }
}

/// sidebar.js `phaseAddTrailer`: "+ New Phase…", "+ From setups…" and — only
/// where folders apply — "+ New Folder…": the same row every Phases view
/// ends with, so switching views never hides the way to make another one.
struct PhaseAddTrailer: View {
    let profile: TeleportProfile
    var hosts: [Host] = []
    var first = false
    var folders = true
    weak var window: WindowModel?

    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 6) {
            if folders {
                addRow("+  New Folder…", dot: p.muted, help: "A place to drag Phases into, or file one into from its own menu") {
                    SBMenus.folderDialog(group: phaseGroupKey(profile), hosts: hosts, window: window) { _ in }
                }
            }
            addRow(first ? "+  Build the first Phase…" : "+  New Phase…", dot: p.accent,
                   help: "tsh phase add: a build console on a build beam, from the default image, on top of a Phase, or forked from one") {
                Task { await PhaseRuns.newPhase(profile, window: window) }
            }
            addRow("+  From setups…", dot: p.accent,
                   help: "Pick setups — Go, Postgres, the AWS CLI, your dotfiles, a repo to clone — into a phase.yaml, and build it with tsh phase apply") {
                PhaseBuilder.open(profile, window: window)
            }
        }
    }

    private func addRow(_ text: String, dot: Color, help: String, _ action: @escaping () -> Void) -> some View {
        let p = Theme.shared.p
        return HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(p.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .padding(.vertical, 3).padding(.leading, 14)
        .contentShape(Rectangle())
        .help(help)
        .onTapGesture(perform: action)
    }
}

/// The Phases tab: Folders (the default), a flat list, or the build lineage between them.
struct PhaseListView: View {
    let profile: TeleportProfile
    let mode: String
    weak var window: WindowModel?

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.shared.p.muted)
            .padding(.leading, 20).padding(.vertical, 3)
    }

    var body: some View {
        let info = BeamPhaseLists.shared.phaseList(profile.proxy)
        let _ = PhaseStore.shared.journalGeneration
        let folders = mode != "list" && mode != "relationship"
        VStack(alignment: .leading, spacing: 0) {
            if info == nil || (info!.loading && info!.phases.isEmpty) {
                note("Reading Phases (tsh phase ls)…")
            } else if let info, !info.ok {
                note(info.error ?? "Could not read the Phases")
                PhaseAddTrailer(profile: profile, first: true, folders: folders, window: window)
            } else if let info, info.phases.isEmpty {
                note("No Phases yet.")
                PhaseAddTrailer(profile: profile, first: true, folders: folders, window: window)
            } else if let info {
                let list = filtered(info.phases)
                if list.isEmpty { note("No Phase matches the filter.") }
                else if mode == "relationship" { PhaseRelationRows(profile: profile, list: list, window: window) }
                else if mode == "list" {
                    ForEach(list.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }) { ph in
                        PhaseListRow(profile: profile, phase: ph, groupKey: phaseGroupKey(profile), window: window)
                    }
                    PhaseAddTrailer(profile: profile, folders: false, window: window)
                } else { folderRows(list) }
            }
        }
    }

    /// `info.phases`, trimmed to the filter box.
    private func filtered(_ all: [BeamPhase]) -> [BeamPhase] {
        let f = (window.map { $0.feature(SidebarWindow.self).filterText.trimmed } ?? "").lowercased()
        return f.isEmpty ? all : all.filter { "\($0)".lowercased().contains(f) }
    }

    /// Folders view: `tsh phase ls`, in its own folders, and a way to make another of either.
    @ViewBuilder private func folderRows(_ list: [BeamPhase]) -> some View {
        let gk = phaseGroupKey(profile)
        let hosts = list.map { phaseHost(profile, $0) }
        let byId = Dictionary(list.map { ("phase:\(profile.proxy):\($0.name)", $0) }, uniquingKeysWith: { a, _ in a })
        let rows = folderWalk(gk, hosts)
        ForEach(rows, id: \.id) { r in
            if let f = r.folder {
                if let window {
                    SBFolderRow(window: window, sw: window.feature(SidebarWindow.self), folder: f, count: r.count, depth: r.depth, groupKey: gk)
                }
            } else if let h = r.host, let ph = byId[h.id] {
                PhaseListRow(profile: profile, phase: ph, groupKey: gk, depth: r.depth, inFolder: r.inFolder, window: window)
            }
        }
        PhaseAddTrailer(profile: profile, hosts: hosts, window: window)
    }

    private struct WalkRow { var id: String; var folder: HostFolder?; var host: Host?; var count = 0; var depth = 0; var inFolder = false }

    private func folderWalk(_ gk: String, _ hosts: [Host]) -> [WalkRow] {
        var rows: [WalkRow] = []
        let shut = window?.feature(SidebarWindow.self).foldersShut ?? []
        func walk(_ parent: String?, _ depth: Int) {
            for f in FolderModel.folders(in: gk, parent: parent) {
                rows.append(WalkRow(id: "f:" + f.id, folder: f, count: FolderModel.hostsInTree(f, hosts).count, depth: depth))
                if shut.contains(f.id) { continue }
                walk(f.id, depth + 1)
                for h in FolderModel.hostsInFolder(f, hosts) {
                    rows.append(WalkRow(id: "h:\(f.id):\(h.id)", host: h, depth: depth + 1, inFolder: true))
                }
            }
        }
        walk(nil, 0)
        for h in hosts where !FolderModel.isFiled(h, gk) { rows.append(WalkRow(id: "h:" + h.id, host: h)) }
        return rows
    }
}
