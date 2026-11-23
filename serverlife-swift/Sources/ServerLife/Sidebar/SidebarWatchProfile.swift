import AppKit
import SwiftUI

/// sidebar.js `openWatchProfile`: what is known about a watched host that
/// cannot be looked at now — gone, requestable, or on a cluster that cannot
/// be read: the record kept of it and where it came from. Every value can be
/// copied.
@MainActor
extension SBDialogs {
    static func watchProfile(_ host: Host, window: WindowModel?) {
        let m = SBWatchProfileModel(host)
        Modal.sheet(window, title: "", width: 620) { handle in
            SBWatchProfileView(m: m) { handle.close() }
        }
    }
}

struct SBWatchProfileModel {
    struct Row { var key: String; var value: String; var prose: Bool }
    let host: Host
    let rows: [Row]
    let labels: [(String, String)]
    let offerLogin: Bool

    @MainActor init(_ host: Host) {
        self.host = host
        let bare: (String?) -> String = { x in
            (x ?? "").replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression).lowercased()
        }
        let prof = Inventory.shared.profiles.first { p in
            (host.proxy?.isEmpty == false) && bare(p.proxy) == bare(host.proxy)
                && ((host.cluster ?? "").isEmpty || p.cluster.isEmpty || p.cluster == host.cluster)
        }
        let when: (Double?) -> String = { ms in
            guard let ms, ms > 0 else { return "" }
            return "\(SBWatchProfileModel.localString(ms)) (\(HostWatch.goneFor(ms)) ago)"
        }
        let until = SBWatchProfileModel.isoMs(prof?.validUntil).map(SBWatchProfileModel.localString)
        let login: String
        if (host.proxy ?? "").isEmpty { login = "" }
        else if let prof {
            login = prof.expired
                ? "Expired\(until.map { " at \($0)" } ?? "")"
                : "Logged in\(prof.username.isEmpty ? "" : " as \(prof.username)")\(until.map { ", valid until \($0)" } ?? "")"
        } else { login = "Not logged in \u{2014} no tsh profile for this proxy" }
        let status: String
        if host.isRequestableRow {
            status = "Requestable \u{2014} alive, but your roles do not reach it (since \(HostWatch.goneFor(host.requestableSince ?? nowMs())) ago)"
                + ((host.extra["requestUncheckedSince"]?.double).map { "; not rechecked since \(when($0))" } ?? "")
        } else if host.watchMissing {
            status = "Gone \u{2014} absent from the cluster\u{2019}s list since \(when(host.watchMissingSince))"
        } else {
            status = "Unchecked \u{2014} its cluster could not be read, so nothing is known either way"
        }
        let hn = host.hostname ?? ""
        let addr = host.addr ?? ""
        let connects = host.type == Host.teleport || host.type.isEmpty
            ? (host.tunnel == true ? "Reverse tunnel (dials the cluster)" : "Direct") : host.type
        let all: [Row] = [
            Row(key: "Status", value: status, prose: true),
            Row(key: "Name", value: host.name, prose: false),
            Row(key: "Hostname", value: !hn.isEmpty && hn != host.name ? hn : "", prose: false),
            Row(key: "ssh_config alias", value: host.alias ?? "", prose: false),
            Row(key: "Node id (UUID)", value: host.uuid ?? "", prose: false),
            Row(key: "Cluster", value: host.cluster ?? "", prose: false),
            Row(key: "Proxy", value: host.proxy ?? "", prose: false),
            Row(key: "Cluster login", value: login, prose: true),
            Row(key: "tsh home", value: host.home ?? "", prose: false),
            // A tunnelled node has no address of its own; "tunnel" is what tsh says.
            Row(key: "Last address", value: !addr.isEmpty && addr != "tunnel" ? addr : "", prose: false),
            Row(key: "Connects", value: connects, prose: true),
            Row(key: "Last seen", value: when(host.watchLastSeen), prose: true),
        ]
        rows = all.filter { !$0.value.isEmpty }
        labels = host.labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        offerLogin = !(host.proxy ?? "").isEmpty && (prof == nil || prof!.expired)
    }

    var allText: String {
        (rows.map { "\($0.key): \($0.value)" } + labels.map { "label \($0.0): \($0.1)" }).joined(separator: "\n")
    }

    static func localString(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static func isoMs(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
    }
}

private struct SBWatchProfileView: View {
    let m: SBWatchProfileModel
    let close: () -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "\(m.host.name) \u{2014} watched", width: 620) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(m.rows.enumerated()), id: \.offset) { _, r in
                    row(r.key, r.value, prose: r.prose, copy: r.value)
                }
                if !m.labels.isEmpty {
                    Text("Labels (\(m.labels.count))").font(.system(size: 12)).foregroundStyle(p.muted)
                        .padding(.top, 10).padding(.bottom, 4)
                    ForEach(Array(m.labels.enumerated()), id: \.offset) { _, l in
                        row(l.0, l.1, prose: false, copy: "\(l.0)=\(l.1)")
                    }
                }
                MiscHint(text: "Kept from the last time the cluster listed it; nothing here is read from the host now.")
                    .padding(.top, 10)
            }
        } footer: {
            if m.offerLogin {
                Button("Copy the login command") {
                    close()
                    Clipboard.write("tsh login --proxy=\(m.host.proxy ?? "")\((m.host.cluster ?? "").isEmpty ? "" : " \(m.host.cluster!)")")
                    StatusBus.shared.show("Copied the tsh login command")
                }.buttonStyle(.ghost)
            }
            Button("Copy all") { Clipboard.write(m.allText); StatusBus.shared.show("Copied the record") }.buttonStyle(.ghost)
            Button("Close") { close() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
        }
    }

    private func row(_ k: String, _ v: String, prose: Bool, copy: String) -> some View {
        let p = Theme.shared.p
        return HStack(alignment: .center, spacing: 8) {
            Text(k).font(.system(size: 12)).foregroundStyle(p.muted).frame(width: 130, alignment: .leading)
            Text(v).font(prose ? .system(size: 12) : .system(size: 12, design: .monospaced))
                .foregroundStyle(p.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if prose { Color.clear.frame(width: 22, height: 1) } else {
                Button("\u{29C9}") { Clipboard.write(copy); StatusBus.shared.show("Copied " + copy) }
                    .buttonStyle(.plain).foregroundStyle(p.textDim).help("Copy").frame(width: 22)
            }
        }
    }
}
