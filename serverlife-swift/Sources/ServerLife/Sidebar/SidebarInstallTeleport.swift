import SwiftUI

/// sidebar.js `openInstallTeleportOnHostWizard`: for a direct SSH host the
/// probe found without Teleport. The commands come from
/// `Teleport.nodeInstallCommand` — the chosen cluster's own install.sh, then
/// `teleport node configure` with the node name and labels, then the service
/// started — shown live with a placeholder token before any token exists.
/// "Copy command" makes a real join token, on the cluster picked and checked
/// to be that one; "Run in this session" types the commands into the host's
/// own terminal, so sudo can ask for its password there.
@MainActor
enum SBInstallTeleport {
    static func open(_ host: Host, window: WindowModel?) {
        let profiles = Inventory.shared.profiles.filter { !$0.expired }
        guard !profiles.isEmpty else {
            StatusBus.shared.toast("Log into a Teleport cluster first \u{2014} that is what this host would join.", kind: .error)
            return
        }
        Modal.sheet(window, title: "", width: 700) { handle in
            SBInstallTeleportView(host: host, profiles: profiles, window: window) { handle.close() }
        }
    }

    /// The host behind a connection, for a session opened some other way than
    /// a sidebar row (`hostForConnection`), then the wizard
    /// (`openInstallTeleportForHostId`, the pane header's Teleport button).
    static func open(hostId: String, label: String?, window: WindowModel?) {
        open(hostForConnection(hostId, label: label, window: window), window: window)
    }

    /// The host behind a connection opened some other way than a sidebar row
    /// (a saved profile's host is not in the list under its own id), built
    /// from the connection itself — all the wizard needs.
    static func hostForConnection(_ hostId: String, label: String?, window: WindowModel?) -> Host {
        if let h = window?.feature(SidebarWindow.self).drawnHosts[hostId] ?? SB2.hostById(hostId) { return h }
        let conn = ConnectionManager.shared.connections.first { $0.hostId == hostId }
        let name = (label ?? conn?.label ?? hostId).replacingOccurrences(of: #"\s+\([^)]*\)$"#, with: "", options: .regularExpression)
        var h = Host(type: Host.ssh, id: hostId, name: name)
        h.alias = name
        return h
    }

    /// `labels()`: key=value, one per line or comma-separated.
    static func parseLabels(_ text: String) -> [(String, String)] {
        let parts = text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { String($0).trimmed }
        return parts.filter { $0.contains("=") }.compactMap { (l: String) -> (String, String)? in
            guard let i = l.firstIndex(of: "=") else { return nil }
            let k = String(l[..<i]).trimmed, v = String(l[l.index(after: i)...]).trimmed
            return k.isEmpty ? nil : (k, v)
        }
    }
}

private struct SBInstallTeleportView: View {
    let host: Host
    let profiles: [TeleportProfile]
    let window: WindowModel?
    let close: () -> Void
    @StateObject private var proxy: Local<String>
    @StateObject private var nodeName: Local<String>
    @StateObject private var labels = Local("")
    @StateObject private var note = Local("")
    /// Made once per cluster in this dialog.
    @StateObject private var token = Local<(value: String, proxy: String)?>(nil)

    init(host: Host, profiles: [TeleportProfile], window: WindowModel?, close: @escaping () -> Void) {
        self.host = host; self.profiles = profiles; self.window = window; self.close = close
        _proxy = StateObject(wrappedValue: Local(profiles[0].proxy))
        _nodeName = StateObject(wrappedValue: Local(host.alias?.nilIfEmpty ?? host.hostname?.nilIfEmpty ?? host.name))
    }

    private var name: String { host.name.nilIfEmpty ?? host.alias ?? "" }
    private var profile: TeleportProfile? { profiles.first { $0.proxy == proxy.value } }

    private func command(_ tok: String?) -> Teleport.NodeInstall {
        Teleport.nodeInstallCommand(proxy: proxy.value, token: tok, labels: SBInstallTeleport.parseLabels(labels.value),
                                    nodeName: nodeName.value.trimmed)
    }

    private var shown: Teleport.NodeInstall {
        command(token.value?.proxy == proxy.value ? token.value?.value : nil)
    }

    private func mint() async -> String? {
        if let t = token.value, t.proxy == proxy.value { return t.value }
        note.value = "Making a join token…"
        let r = await Teleport.createJoinToken(type: "node", ttl: "1h", proxy: proxy.value, home: profile?.home,
                                               cluster: profile?.cluster)
        if !r.ok { note.value = "Could not make a join token: \(r.error ?? "")"; return nil }
        token.value = (r.token, proxy.value)
        note.value = "Join token made on \(r.cluster.nilIfEmpty ?? profile?.cluster ?? ""), valid 1 hour."
        return r.token
    }

    var body: some View {
        let p = Theme.shared.p
        let r = shown
        DialogScaffold(title: "Install Teleport on \(name)", width: 700) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Installs the cluster\u{2019}s own Teleport version with its install.sh (managed updates included), configures it as an "
                     + "SSH node with the name and labels below, and starts it. Needs root on a Linux host with systemd.")
                    .font(.system(size: 12)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                MiscField(label: "Join this Teleport cluster") {
                    Picker("", selection: $proxy.value) {
                        ForEach(profiles, id: \.proxy) { pr in Text("\(pr.cluster.nilIfEmpty ?? pr.proxy) (\(pr.proxy))").tag(pr.proxy) }
                    }.labelsHidden()
                }
                MiscField(label: "Node name") {
                    TextField("node name (defaults to its hostname)", text: $nodeName.value).textFieldStyle(.roundedBorder)
                    MiscHint(text: "How it appears in tsh ls and the Web UI")
                }
                MiscField(label: "Labels") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $labels.value).font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden).frame(height: 52)
                        if labels.value.isEmpty {
                            Text("env=lab\nteam=se").font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                    MiscHint(text: "key=value, one per line \u{2014} what roles and search match on")
                }
                Text("What will run").font(.system(size: 12, weight: .semibold)).padding(.top, 10)
                ScrollView {
                    Text(r.ok ? r.command : (r.error ?? ""))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(r.ok ? p.text : p.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                MiscHint(text: note.value).frame(minHeight: 15, alignment: .topLeading)
            }
        } footer: {
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Copy command") {
                Task {
                    guard let t = await mint() else { return }
                    let c = command(t)
                    if !c.ok { StatusBus.shared.toast(c.error ?? "", kind: .error); return }
                    Clipboard.write(c.command)
                    StatusBus.shared.toast("Commands copied, with a join token valid for 1 hour")
                }
            }.buttonStyle(.ghost)
            Button("Run in this session") { Task { await runHere() } }
                .buttonStyle(.primary)
                .help("Types the commands into the host\u{2019}s own terminal, so sudo can ask for a password there")
        }
    }

    private func runHere() async {
        let conn = ConnectionManager.shared.connections.first { $0.hostId == host.id && $0.state == .connected }
        let sw = window?.feature(SessionsWindow.self)
        guard let conn, let pane = sw?.panes.values.first(where: { $0.connId == conn.id && $0.hasTerm }) else {
            StatusBus.shared.toast("Open a terminal on \(name) first", kind: .error)
            return
        }
        guard let t = await mint() else { return }
        let c = command(t)
        if !c.ok { StatusBus.shared.toast(c.error ?? "", kind: .error); return }
        Actions.shared.perform("send-text", window: window, paneId: pane.id, args: ["text": c.oneLine, "enter": true])
        // The ⚡ clears itself once the install has landed.
        SBPresence.shared.set(host.id, nil)
        SBPresence.shared.watchInstall(host, connId: conn.id)
        sw?.setActivePane(pane.id)
        StatusBus.shared.toast("Running in \(name)'s terminal \u{2014} answer sudo's password prompt there")
        close()
    }
}
