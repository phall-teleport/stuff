import AppKit
import SwiftUI

/// hosticons.js `serverIcon`: two stacked rack units with a light each, at
/// text size — or nothing while Settings has it off (`showServerIcon`).
struct HostsServerIcon: View {
    var title = "SSH server"
    var body: some View {
        if Store.shared.settingJSON("showServerIcon") != .bool(false) {
            Canvas { ctx, size in
                let s = size.width / 16
                for y in [2.5, 8.9] {
                    let r = CGRect(x: 2 * s, y: y * s, width: 12 * s, height: 4.6 * s)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 1.2 * s), with: .foreground, lineWidth: 1.4 * s)
                }
                for y in [4.8, 11.2] {
                    ctx.fill(Path(ellipseIn: CGRect(x: (4.9 - 0.95) * s, y: (y - 0.95) * s, width: 1.9 * s, height: 1.9 * s)),
                             with: .foreground)
                    var line = Path()
                    line.move(to: CGPoint(x: 8 * s, y: y * s))
                    line.addLine(to: CGPoint(x: 11.8 * s, y: y * s))
                    ctx.stroke(line, with: .foreground, style: StrokeStyle(lineWidth: 1.2 * s, lineCap: .round))
                }
            }
            .frame(width: 13, height: 13)
            .foregroundStyle(Theme.shared.p.muted)
            .help(title)
        }
    }
}

extension View {
    /// Click picks, double-click opens, right-click the row menu — the same
    /// in every layout.
    fileprivate func hostsPaneRow(_ model: HostsPaneModel, _ host: Host, folder: HostFolder?, order: [String]) -> some View {
        let k = FolderModel.hostKey(host)
        return contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { model.open(host) }
                .exclusively(before: TapGesture(count: 1).onEnded { model.pick(k, order: order) }))
            .hostsRightClick { model.rowMenu(host, folder: folder) }
    }
}

@MainActor private extension Host {
    var hpKube: Bool { extra["kind"]?.string == "kube" }
    var hpMissing: Bool { extra["missing"]?.truthy == true }
    var hpRequestable: Bool { extra["requestable"]?.truthy == true }
    var hpAvailable: Bool { extra["availableCluster"].map { !$0.isNull } ?? false }
    var hpAddr: String { addr?.nilIfEmpty ?? (tunnel == true ? "tunnel" : (user ?? "")) }
    var hpTip: String {
        if hpKube { return name }
        return [HostsPane.nameOf(self), addr?.nilIfEmpty ?? (tunnel == true ? "tunnel" : ""), HostsHooks.heartbeat(self)?.line ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
    var hpServerTitle: String { type == "teleport" ? "Teleport SSH server" : "SSH server" }
}

/// One host in the pane (`.hp-card` / `kubeCard`), as a row or a tile.
struct HostsPaneCard: View {
    @ObservedObject var model: HostsPaneModel
    let host: Host
    let folder: HostFolder?
    let order: [String]
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let box = HostsPane.boxView
        let k = FolderModel.hostKey(host)
        let on = model.picked.contains(k)
        let kube = host.hpKube
        let missing = host.hpMissing
        let quiet = !kube && HostsHooks.heartbeat(host)?.stale == true
        let tags = Array(Tags.labelEntries(host).prefix(box ? 3 : 5))
        VStack(alignment: .leading, spacing: 4) {
            if kube { kubeLine(on) } else { sshLine(on, k) }
            if !tags.isEmpty {
                HFlow(spacing: 3, lineSpacing: 3) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, t in LabelChip(key: t.key, value: t.value, onAccent: on) }
                }
            }
        }
        .foregroundStyle(on ? Color.white : (hover.on ? p.text : p.textDim))
        .padding(.horizontal, box ? 10 : 9).padding(.vertical, box ? 8 : 5)
        .frame(minHeight: box ? 52 : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? p.accentDim
            : (box ? (hover.on ? p.panel3 : p.panel2) : (hover.on ? p.panel2 : Color.clear))))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? p.accent : (box ? p.borderSoft : Color.clear)))
        .overlay(alignment: .leading) { if quiet { p.amber.frame(width: 2) } }
        .opacity(missing ? 0.72 : 1)
        .onHover { hover.on = $0 }
        .help(host.hpTip)
        .hostsPaneRow(model, host, folder: folder, order: order)
        .onDrag {
            model.startDrag(k)
            return HostsDrag.provider(HostsPane.nameOf(host), from: model)
        }
        // In a folder, the fastest way out of it is the one you already tried.
        .focusable(folder != nil)
        .focusEffectDisabled()
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let folder else { return .ignored }
            FolderModel.unfileHost(host, folder.id)
            return .handled
        }
    }

    private func sshLine(_ on: Bool, _ k: String) -> some View {
        let p = Theme.shared.p
        let missing = host.hpMissing
        let icon = Store.shared.settingJSON("hostIcons")[k].string ?? ""
        return HStack(spacing: 7) {
            HostDot(on: FolderBits.connected(host), color: missing ? p.amber : nil)
            if HostsHooks.showWatchMark && HostsHooks.isWatched(host) && !missing {
                Text("\u{1F514}").font(.system(size: 10)).help("Watched for disappearance")
            }
            Text(HostsPane.nameOf(host)).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .strikethrough(missing)
            HostsServerIcon(title: host.hpServerTitle)
            if !icon.isEmpty { Text(icon).font(.system(size: 12)) }
            if host.ambiguous == true, let uuid = host.uuid {
                Text("\u{1F4CB}").font(.system(size: 10))
                    .help("Duplicate named node — another node here answers to “\(host.name)”.\nThis one is dialled by its id, \(uuid).")
            }
            if host.hpRequestable {
                SmallTag(kind: .req, text: "req",
                         help: "Not yours to open yet \u{2014} \(host.cluster ?? "this cluster") will let you ask for it.\nDouble-click to start a request.")
            } else if missing {
                SmallTag(kind: .gone, text: "\u{2298} gone " + HostsHooks.goneFor(host.extra["missingSince"]?.double),
                         help: HostsHooks.missingLine(host))
            } else {
                HeartbeatTag(host: host)
            }
            Spacer(minLength: 4)
            Text(host.hpAddr)
                .font(.system(size: 11)).foregroundStyle(on ? Color.white.opacity(0.75) : p.muted).lineLimit(1).fixedSize()
        }
    }

    /// kubeCard: name, the ☸ marks, a state tag, its heartbeat.
    private func kubeLine(_ on: Bool) -> some View {
        HStack(spacing: 7) {
            HostDot(on: false)
            Text(host.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
            HostsHooks.kubeMarks(host)
            if host.hpRequestable {
                SmallTag(kind: .req, text: "req", help: "Not yours to open yet — double-click to start a request.")
            } else if host.hpAvailable {
                SmallTag(kind: .rule, text: "available", help: "Not logged in yet — double-click to log in")
            }
            if let b = HostsHooks.kubeBeat(host) { b }
            Spacer(minLength: 4)
        }
    }
}

/// One host as a table line (`tableRow` / `kubeTableRow`). Table rows do not
/// drag, as the original's do not.
struct HostsPaneTableRow: View {
    @ObservedObject var model: HostsPaneModel
    let host: Host
    let folder: HostFolder?
    let order: [String]
    let cols: [String]
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let on = model.picked.contains(FolderModel.hostKey(host))
        let kube = host.hpKube
        let missing = host.hpMissing
        let quiet = !kube && HostsHooks.heartbeat(host)?.stale == true
        let tags = Tags.labelEntries(host)
        // Whatever did not get its own column still shows.
        let leftover = cols.isEmpty ? tags : tags.filter { !cols.contains($0.key) }
        HPTableLine(
            name: AnyView(nameCell),
            status: AnyView(statusCell),
            beat: AnyView(beatCell),
            addr: AnyView(Text(kube ? "" : host.hpAddr).font(.system(size: 11))
                .foregroundStyle(on ? Color.white.opacity(0.75) : p.muted).lineLimit(1)),
            cols: cols.map { ck in
                let found = tags.first { $0.key == ck }
                return AnyView(Text(found.map { $0.value.isEmpty ? "—" : $0.value } ?? "—")
                    .font(.system(size: 11)).lineLimit(1)
                    .help(found.map { "\(ck)=\($0.value)" } ?? ck))
            },
            labels: AnyView(HStack(spacing: 3) {
                ForEach(Array(leftover.enumerated()), id: \.offset) { _, t in LabelChip(key: t.key, value: t.value, onAccent: on) }
            }.lineLimit(1).clipped()))
        .foregroundStyle(on ? Color.white : (hover.on ? p.text : p.textDim))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(on ? p.accentDim : (hover.on ? p.panel2 : Color.clear)))
        .overlay(alignment: .leading) { if quiet { p.amber.frame(width: 2) } }
        .opacity(missing ? 0.72 : 1)
        .onHover { hover.on = $0 }
        .help(host.hpTip)
        .hostsPaneRow(model, host, folder: folder, order: order)
    }

    private var nameCell: some View {
        let p = Theme.shared.p
        let kube = host.hpKube
        return HStack(spacing: 7) {
            HostDot(on: !kube && FolderBits.connected(host), color: host.hpMissing ? p.amber : nil)
            Text(kube ? host.name : HostsPane.nameOf(host)).font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.tail).strikethrough(host.hpMissing)
            if kube { HostsHooks.kubeMarks(host) } else { HostsServerIcon(title: host.hpServerTitle) }
        }
    }

    @ViewBuilder private var statusCell: some View {
        if host.hpRequestable {
            SmallTag(kind: .req, text: "req")
        } else if host.hpKube && host.hpAvailable {
            SmallTag(kind: .rule, text: "available")
        } else if host.hpMissing {
            SmallTag(kind: .gone, text: "\u{2298} gone " + HostsHooks.goneFor(host.extra["missingSince"]?.double),
                     help: HostsHooks.missingLine(host))
        }
    }

    @ViewBuilder private var beatCell: some View {
        if host.hpKube {
            if let b = HostsHooks.kubeBeat(host) { b }
        } else if !host.hpMissing && !host.hpRequestable {
            HeartbeatTag(host: host)
        }
    }
}

/// A saved profile in the "Saved" group, the shape of a host card.
/// Double-click launches it; right-click is the Saved tab's own menu.
struct HostsPaneProfileCard: View {
    @ObservedObject var model: HostsPaneModel
    let profile: JSON
    let order: [String]
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let box = HostsPane.boxView
        let k = HostsPane.profileKey(profile)
        let on = model.picked.contains(k)
        let colour = profile["color"].string.flatMap { $0.hasPrefix("#") ? Color(hex: $0) : HostColor.color($0) }
        let w = model.window
        let prof = profile
        HStack(spacing: 7) {
            HostDot(on: false)
            Text(profile["name"].stringish ?? "").font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
            if let icon = Profiles.icon(profile) { Text(icon).font(.system(size: 12)) }
            SmallTag(kind: .rule, text: HostsPane.profileKind(profile))
            Spacer(minLength: 4)
            Text(Profiles.meta(profile)).font(.system(size: 11))
                .foregroundStyle(on ? Color.white.opacity(0.75) : p.muted).lineLimit(1)
        }
        .foregroundStyle(on ? Color.white : (hover.on ? p.text : p.textDim))
        .padding(.horizontal, box ? 10 : 9).padding(.vertical, box ? 8 : 5)
        .frame(minHeight: box ? 52 : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? p.accentDim
            : (box ? (hover.on ? p.panel3 : p.panel2) : (hover.on ? p.panel2 : Color.clear))))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? p.accent : (box ? p.borderSoft : Color.clear)))
        .overlay(alignment: .leading) { if let colour { colour.frame(width: 3) } }
        .onHover { hover.on = $0 }
        .help([profile["name"].stringish ?? "", Profiles.meta(profile)].filter { !$0.isEmpty }.joined(separator: "\n"))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { Task { @MainActor in await Profiles.launch(prof, window: w) } }
            .exclusively(before: TapGesture(count: 1).onEnded { model.pick(k, order: order) }))
        .contextMenu { SavedProfileMenu(profile: prof, window: w) }
    }
}
