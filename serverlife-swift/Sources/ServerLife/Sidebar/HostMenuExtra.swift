import AppKit
import SwiftUI

// The 0.39 additions to a host's menu (sidebar.js `onHostContextMenu`):
// bulk requests, the startup command, the saved pane style, Ask the AI,
// SSH options, the ssh-config source items, Install Teleport.

extension HostPrefs {
    /// The command set to run the moment a session on this host opens, if any.
    static func startupCommand(_ host: Host) -> String {
        SB.store.settings["hostStartupCommand"][host.sbPrefKey].string ?? ""
    }

    static func setStartupCommand(_ host: Host, _ value: String) {
        var map = SB.store.settings["hostStartupCommand"].entries
        if value.trimmed.isEmpty { map.removeValue(forKey: host.sbPrefKey) } else { map[host.sbPrefKey] = .string(value) }
        SB.store.updateSettings(["hostStartupCommand": .object(map)])
        StatusBus.shared.show(value.trimmed.isEmpty ? "Startup command cleared" : "Startup command set for \(label(host))")
    }
}

@MainActor
extension SBMenus {
    /// "Request access to N selected nodes…", or nil with fewer than two
    /// hosts ticked. On every menu a host row can show — the row
    /// right-clicked is routinely not one of the ticked ones.
    static func bulkRequestItem(_ sw: SidebarWindow?, window: WindowModel?) -> CtxItem? {
        guard let sw, sw.checkedHosts.count > 1 else { return nil }
        let hosts = sw.checkedHostObjects
        let n = hosts.filter(\.isRequestableRow).count
        return CtxItem("Request access to \(n) selected node\(n == 1 ? "" : "s")…", icon: "\u{2691}", disabled: n == 0,
                       title: n > 0 ? "Starts one request per cluster the selection spans" : "None of the selected hosts are requestable") {
            Actions.shared.perform("access-request-many", window: window, args: ["hosts": hosts])
        }
    }

    static func multiexecSelectedItem(_ sw: SidebarWindow?, window: WindowModel?) -> CtxItem? {
        guard let sw, sw.checkedHosts.count > 1 else { return nil }
        return CtxItem("Open multi-exec on \(sw.checkedHosts.count) selected hosts\u{2026}", icon: "\u{25B8}",
                       title: "Opens the multi-exec dock, already targeting the ticked hosts") {
            Actions.shared.perform("multiexec", window: window, args: ["hostIds": Array(sw.checkedHosts)])
        }
    }

    static func startupCommandItem(_ host: Host, window: WindowModel?) -> CtxItem {
        CtxItem(HostPrefs.startupCommand(host).isEmpty ? "Startup command…" : "Startup command: set…", icon: "\u{25B8}",
                title: "Run a command the moment a session on this host opens") {
            SBDialogs.startupCommand(host, window: window)
        }
    }

    /// panestyle.js `hostStyleMenu(key)`: only once a look has been saved
    /// for the host. Asked of [sessions] (`host-style-menu`, args `key`,
    /// reply a CtxItem or nil).
    static func hostStyleItem(_ key: String, window: WindowModel?) -> CtxItem? {
        var out: CtxItem?
        Actions.shared.perform("host-style-menu", window: window, args: [
            "key": key, "reply": { (v: Any?) in out = v as? CtxItem } as (Any?) -> Void,
        ])
        return out
    }

    static func askAiItem(_ host: Host, window: WindowModel?) -> CtxItem {
        CtxItem("Ask the AI about this host", icon: "\u{2726}",
                title: "Put its details into the AI assistant \u{2014} then type your question") {
            Actions.shared.perform("ai-ask", window: window, host: host,
                                   args: ["source": "the host \(host.name.nilIfEmpty ?? host.alias ?? "") in ServerLife"])
        }
    }

    /// The "SSH options" submenu ([hosts] `ssh-options-menu`), with X11 in it.
    static func sshOptionsItem(_ host: Host, login: String?, window: WindowModel?) -> CtxItem {
        var out: CtxItem?
        let x11: () -> Void = { Task { await SBActions.openX11(host, login: login, window: window) } }
        var args: [String: Any] = ["openX11": x11, "reply": { (v: Any?) in out = v as? CtxItem } as (Any?) -> Void]
        if let login { args["login"] = login }
        Actions.shared.perform("ssh-options-menu", window: window, host: host, args: args)
        // Until [hosts] answers, X11 on its own, as before.
        return out ?? CtxItem("Open with X11 forwarding", icon: "\u{2317}", onClick: x11)
    }

    /// An ssh_config host read from a file: take it out, add beside it, edit the file.
    static func sshSourceItems(_ host: Host, window: WindowModel?) -> [CtxItem] {
        guard host.type == Host.ssh, let source = host.extra["source"]?.string?.nilIfEmpty else { return [] }
        let file = host.configFile
        return [
            CtxItem("Delete or comment out in ssh config…", icon: "\u{2716}",
                    title: "Take \"\(host.alias ?? "")\" out of \(source), after showing you its block") {
                Actions.shared.perform("ssh-config-remove-host", window: window, host: host)
            },
            CtxItem("New host in this config…", icon: "+",
                    title: "Write a new Host block into " + (host.extra["configRoot"]?.string?.nilIfEmpty ?? source)) {
                var args: [String: Any] = [:]
                if let file { args["configFile"] = file }
                Actions.shared.perform("add-server", window: window, args: args)
            },
            CtxItem("Edit its ssh config…", icon: "\u{270E}", title: source) {
                Actions.shared.perform("ssh-config-edit", window: window, args: ["path": source])
            },
        ]
    }

    /// Only once the probe has actually found it missing — never guessed at,
    /// never with the detection setting off.
    static func installTeleportItem(_ host: Host, window: WindowModel?) -> CtxItem? {
        guard host.type != Host.teleport, SBPresence.enabled,
              let p = SBPresence.shared.known(host.id), !p.installed else { return nil }
        return CtxItem("Install Teleport on this host\u{2026}", icon: "\u{26A1}",
                       title: "Generates a join token and the commands to enroll this machine") {
            SBInstallTeleport.open(host, window: window)
        }
    }

    static func watchProfileItem(_ host: Host, window: WindowModel?) -> CtxItem {
        CtxItem("Profile…", icon: "\u{2139}",
                title: "What was kept about it: the cluster it came from, its node id, address and labels") {
            SBDialogs.watchProfile(host, window: window)
        }
    }
}

@MainActor
extension SBDialogs {
    /// sidebar.js `setHostStartupCommand`.
    static func startupCommand(_ host: Host, window: WindowModel?) {
        let current = HostPrefs.startupCommand(host)
        Task {
            guard let res: String = await SBModal.ask(window, width: 480, content: { finish in
                SBStartupCommandView(host: host, current: current, finish: finish)
            }) else { return }
            HostPrefs.setStartupCommand(host, res)
        }
    }
}

private struct SBStartupCommandView: View {
    let host: Host
    let current: String
    let finish: (String?) -> Void
    @StateObject private var value: Local<String>

    init(host: Host, current: String, finish: @escaping (String?) -> Void) {
        self.host = host; self.current = current; self.finish = finish
        _value = StateObject(wrappedValue: Local(current))
    }

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Startup command", subtitle: HostPrefs.label(host), width: 480) {
            VStack(alignment: .leading, spacing: 8) {
                MiscField(label: "Run on open") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $value.value)
                            .font(.system(size: 11.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(height: 64)
                        if value.value.isEmpty {
                            Text("tmux attach || tmux new\ncd /var/log")
                                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.muted)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                    MiscHint(text: "Sent to the session the moment it connects")
                }
                MiscHint(text: host.type == Host.teleport
                         ? "Stored against this node's uuid (\(String((host.uuid ?? "").prefix(8)))…), so renaming the host keeps it."
                         : "Stored against this ssh_config entry.", size: 11.5)
                    .padding(.top, 9)
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            if !current.isEmpty { Button("Clear") { finish("") }.buttonStyle(GhostButtonStyle(destructive: true)) }
            Button("Save") { finish(value.value) }.buttonStyle(.primary)
        }
    }
}
