import AppKit
import SwiftUI

/// The profiles view of the sidebar's Saved tab (sidebar.js
/// `renderSavedTab` / `profileRow`): saved connections grouped by their
/// profile folder, Ungrouped last, with the row menu and the New profile /
/// Export all / Import buttons.
///
/// The sidebar embeds it: `SavedProfilesList(window: w, filter: text)`, or
/// `HostsFeature.savedList(w, text)`. `groupHeader` lets the sidebar draw the
/// group headings its own way (title, count, key `sf:<folder id|none>`, rows).
struct SavedProfilesList: View {
    let window: WindowModel?
    var filter: String = ""
    var groupHeader: ((_ title: String, _ count: Int, _ key: String, _ rows: AnyView) -> AnyView)? = nil
    @StateObject private var collapsed = Local<Set<String>>([])

    private func matches(_ text: JSON) -> Bool {
        filter.isEmpty || (text.stringish ?? "null").lowercased().contains(filter.lowercased())
    }

    var body: some View {
        let p = Theme.shared.p
        let profiles = HostsData.profiles.filter { matches($0["name"]) || matches($0["alias"]) || matches($0["node"]) }
        VStack(alignment: .leading, spacing: 0) {
            if profiles.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text(filter.isEmpty ? "No saved profiles yet." : "No matching profiles.")
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                    HStack(spacing: 6) {
                        Button("New profile…") { Profiles.openEditor(window) }.buttonStyle(.ghost)
                        Button("Import…") { SavedProfilesList.runImport(window) }.buttonStyle(.ghost)
                            .help("Load a ServerLife export from another machine")
                    }
                }
                .padding(10)
            } else {
                let folders = HostsData.profileFolders + [["id": "", "name": "Ungrouped"]]
                ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                    let fid = folder["id"].stringish ?? ""
                    let items = profiles.filter { ($0["folderId"].truthy ? $0["folderId"].stringish ?? "" : "") == fid }
                    if !items.isEmpty {
                        let key = "sf:" + (fid.isEmpty ? "none" : fid)
                        let rows = AnyView(VStack(spacing: 0) { ForEach(Array(items.enumerated()), id: \.offset) { _, prof in
                            SavedProfileRow(profile: prof, window: window)
                        } })
                        if let groupHeader {
                            groupHeader(folder["name"].stringish ?? "", items.count, key, rows)
                        } else {
                            savedGroup(folder["name"].stringish ?? "", items.count, key, rows)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Button("New profile…") { Profiles.openEditor(window) }.buttonStyle(.ghost)
                    Button("Export all…") { Actions.shared.perform("backup-export", window: window, args: ["what": "all"]) }
                        .buttonStyle(.ghost)
                        .help("Profiles, macros, snippets, saved requests, layouts and preferences — everything but the session log")
                    Button("Import…") { SavedProfilesList.runImport(window) }.buttonStyle(.ghost)
                        .help("Load a ServerLife export from another machine")
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
            }
        }
    }

    private func savedGroup(_ title: String, _ count: Int, _ key: String, _ rows: AnyView) -> some View {
        let p = Theme.shared.p
        let shut = collapsed.value.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: shut ? "chevron.right" : "chevron.down").font(.system(size: 9)).foregroundStyle(p.muted)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.textDim)
                Spacer()
                Text(String(count)).font(.system(size: 10)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture {
                if shut { collapsed.value.remove(key) } else { collapsed.value.insert(key) }
            }
            if !shut { rows }
        }
    }

    /// sidebar.js `runImport`: misc's import, then a fresh inventory.
    static func runImport(_ window: WindowModel?) {
        Actions.shared.perform("backup-import", window: window, args: ["reply": { (imported: Bool) in
            if imported { Task { @MainActor in await Inventory.shared.refresh() } }
        } as (Bool) -> Void])
    }
}

/// One saved profile in the list (`profileRow`).
struct SavedProfileRow: View {
    let profile: JSON
    let window: WindowModel?
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 7) {
            Circle()
                .fill(profile["color"].string.flatMap { $0.hasPrefix("#") ? Color(hex: $0) : HostColor.color($0) } ?? p.muted.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(profile["name"].stringish ?? "").font(.system(size: 12.5)).lineLimit(1)
            if let icon = Profiles.icon(profile) { Text(icon).font(.system(size: 11)) }
            Spacer(minLength: 4)
            HTag(text: Profiles.kindLabel(profile))
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 4)
        .background(hover.on ? p.panel3 : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture(count: 2) { open() }
        .contextMenu { SavedProfileMenu(profile: profile, window: window) }
    }

    private func open() {
        let w = window
        let prof = profile
        Task { @MainActor in await Profiles.launch(prof, window: w) }
    }
}

/// sidebar.js `profileContextMenuItems(p)`: Open session (· Open with a
/// terminal for sftp) · split right/down · Mark this profile · Edit… ·
/// Duplicate · Delete. The Hosts pane's "Saved" group shows the same menu.
struct SavedProfileMenu: View {
    let profile: JSON
    let window: WindowModel?

    var body: some View {
        let p = profile
        let w = window
        // Serial, telnet, VNC and RDP each open in their own always-new tab,
        // so there is nothing honest to offer for them here; ssh, Teleport
        // and sftp go through open-host, which can split.
        let canSplit = (w?.feature(SessionsWindow.self).activePane != nil)
            && !["serial", "telnet", "vnc", "rdp"].contains(p["type"].string ?? "")
        Button("Open session") { Task { @MainActor in await Profiles.launch(p, window: w) } }
        if p["type"].string == "sftp" {
            Button("Open with a terminal") { Task { @MainActor in await Profiles.launch(p, window: w, forceTerminal: true) } }
        }
        if canSplit {
            Button("Ⅾ  Open beside current (split right)") {
                Task { @MainActor in await Profiles.launch(p, window: w, split: "right") }
            }
            Button("‗  Open below current (split down)") {
                Task { @MainActor in await Profiles.launch(p, window: w, split: "down") }
            }
        }
        Divider()
        Menu("\(Profiles.icon(p) ?? "◉")  Mark this profile") {
            Button(p["icon"].truthy ? "Icon: \(p["icon"].stringish ?? "")" : "Give it an icon…") {
                Task { @MainActor in await Profiles.setIcon(p, window: w) }
            }
            Divider()
            Section("Colour") {
                ForEach(HostColor.all) { c in
                    let on = (p["color"].string ?? "") == c.value
                    Button((on ? "✓ " : "") + c.label) { Profiles.setColor(p, c.value) }
                }
            }
        }
        .help("Give it an icon or a colour, same as a plain host")
        Divider()
        Button("Edit…") { Profiles.openEditor(w, initial: p) }
        Button("Duplicate") {
            var copy = p
            copy.removeKey("id")
            copy["name"] = .string((p["name"].stringish ?? "") + " copy")
            HostsData.upsertProfile(copy)
        }
        Divider()
        Button("Delete") {
            Task { @MainActor in
                if await MiscUI.confirm(w, title: "Delete profile", message: "Delete “\(p["name"].stringish ?? "")”?",
                                        confirmLabel: "Delete", danger: true) {
                    if let id = p["id"].string { HostsData.deleteProfile(id) }
                }
            }
        }
    }
}

extension Profiles {
    /// sidebar.js `profileIcon`.
    static func icon(_ p: JSON) -> String? { p["icon"].string?.nilIfEmpty }

    /// sidebar.js `setProfileColor`.
    static func setColor(_ p: JSON, _ value: String) {
        guard let id = p["id"].string else { return }
        HostsData.upsertProfile(["id": .string(id), "color": value.isEmpty ? .null : .string(value)])
        let name = p["name"].stringish ?? ""
        StatusBus.shared.show(value.isEmpty ? "Colour cleared for \(name)" : "\(name) is \(value)")
    }

    /// sidebar.js `setProfileIcon`.
    static func setIcon(_ p: JSON, window: WindowModel?) async {
        guard let id = p["id"].string else { return }
        let name = p["name"].stringish ?? ""
        guard let icon = await MiscUI.pickIcon(window, title: "Icon for this profile", subtitle: name,
                                               value: p["icon"].string ?? "") else { return }
        HostsData.upsertProfile(["id": .string(id), "icon": icon.isEmpty ? .null : .string(icon)])
        StatusBus.shared.show(icon.isEmpty ? "Icon cleared" : "\(name) is \(icon)")
    }
}
