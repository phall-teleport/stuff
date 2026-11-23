import AppKit

/// 0.39 additions to a group heading's menu (sidebar.js `openGroupMenu`).
@MainActor
enum SBGroupMenuExtra {
    /// "Decode" — nettools.js `decodeMenu({ profile })`: the SSH certificate
    /// item finds this cluster's own tsh certificate. Asked of [nettools]
    /// through `decode-menu` (args `menu`, `input`, `proxy`, `cluster`, `home`).
    static func decodeItem(_ p: TeleportProfile, window: WindowModel?) -> CtxItem? {
        guard Actions.shared.isRegistered("decode-menu") else { return nil }
        let m = NSMenu()
        Actions.shared.perform("decode-menu", window: window, args: [
            "menu": m, "input": "", "proxy": p.proxy, "cluster": p.cluster, "home": p.homeDir,
        ])
        let sub = fromNSMenu(m)
        guard !sub.isEmpty else { return nil }
        return CtxItem("Decode", icon: "\u{2317}", title: "SSH certificate (yours, for this cluster), JWT or SPIFFE SVID", submenu: sub)
    }

    /// The config file an ssh group names: nil for `~/.ssh/config`.
    static func configFile(_ key: String) -> String? { key == "ssh" ? nil : String(key.dropFirst(4)) }

    static func sshConfigItems(_ key: String, window: WindowModel?) -> [CtxItem] {
        let file = configFile(key)
        return [
            CtxItem("New host in this config…", icon: "+", title: "Write a new Host block into " + (file ?? "~/.ssh/config")) {
                var args: [String: Any] = [:]
                if let file { args["configFile"] = file }
                Actions.shared.perform("add-server", window: window, args: args)
            },
            CtxItem("Edit this ssh config…", icon: "\u{270E}", title: file ?? "~/.ssh/config") {
                var args: [String: Any] = [:]
                if let file { args["path"] = file }
                Actions.shared.perform("ssh-config-edit", window: window, args: args)
            },
        ]
    }

    /// TELEPORT_TOOLS_VERSION and the like, for this cluster's tsh alone.
    static func tshEnvItem(_ p: TeleportProfile, window: WindowModel?) -> CtxItem {
        CtxItem("tsh environment for this cluster\u{2026}", icon: "$") {
            Actions.shared.perform("tsh-env-edit", window: window, args: ["proxy": p.proxy, "cluster": p.cluster])
        }
    }

    /// sidebar.js `vnetMenuItems`.
    static func vnetItems(_ p: TeleportProfile, window: WindowModel?) -> [CtxItem] {
        if p.expired { return [] }
        let v = VnetManager.shared.view(for: p.proxy)
        var out: [CtxItem] = []
        if let v, v.active {
            out.append(CtxItem(v.state == "stopping" ? "Stopping VNet\u{2026}" : "Stop VNet", icon: "\u{25C9}",
                               disabled: v.state == "stopping", title: "Stops tsh vnet and takes its network setup down with it") {
                VnetManager.shared.stop(proxy: p.proxy)
            })
        } else {
            out.append(CtxItem("Start VNet", icon: "\u{25CE}",
                               title: "Runs tsh vnet for \(p.cluster.nilIfEmpty ?? p.proxy) alone: its TCP apps answer by name, no tsh proxy needed") {
                VnetActions.start(proxy: p.proxy, home: p.homeDir.nilIfEmpty)
            })
        }
        if v != nil {
            out.append(CtxItem("VNet output\u{2026}", icon: "\u{2630}") { VnetActions.openLog(proxy: p.proxy, window: window) })
        }
        return out
    }

    /// "(proxy.example.com)" after a heading whose cluster name is not its
    /// proxy host; the standard 443 is dropped from both.
    static func proxyNote(_ p: TeleportProfile?) -> String? {
        guard let p, !p.cluster.isEmpty else { return nil }
        var h = p.proxy.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) { h.removeSubrange(r) }
        if let r = h.range(of: "^[^/@]*@", options: .regularExpression) { h.removeSubrange(r) }
        if let r = h.range(of: "/.*$", options: .regularExpression) { h.removeSubrange(r) }
        if h.hasSuffix(":443") { h.removeLast(4) }
        h = h.trimmingCharacters(in: .whitespaces)
        return !h.isEmpty && h != p.cluster ? "(\(h))" : nil
    }

    /// An NSMenu another owner filled, as menu items of ours.
    static func fromNSMenu(_ m: NSMenu) -> [CtxItem] {
        m.items.map { item in
            if item.isSeparatorItem { return .sep }
            let sub = item.submenu.map(fromNSMenu)
            return CtxItem(item.title, disabled: !item.isEnabled, title: item.toolTip, submenu: sub) {
                if let a = item.action { NSApp.sendAction(a, to: item.target, from: item) }
            }
        }
    }
}
