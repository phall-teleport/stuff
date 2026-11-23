import AppKit
import SwiftUI

/// The VNet actions, the state-change messages (index.js `vnet.onState`),
/// and the cluster-menu items and output dialog from sidebar.js
/// (`vnetMenuItems`, `openVnetLog`, `vnetTag`) for the sidebar to use.
///
/// Action ids: `vnet-start`, `vnet-stop` (args `proxy` or `cluster`, `home`,
/// or a host) · `vnet-log` (the VNet output dialog) · `vnet-status` (reply:
/// `[VnetManager.View]`) · `vnet-menu` (args `menu` NSMenu: append Start/Stop
/// VNet and VNet output… for that cluster).
@MainActor
enum VnetActions {
    static func install() {
        let a = Actions.shared
        a.register("vnet-start") { ctx in
            guard let (proxy, home) = target(ctx) else {
                StatusBus.shared.toast("No cluster to start VNet for", kind: .error); return
            }
            start(proxy: proxy, home: home)
        }
        a.register("vnet-stop") { ctx in
            guard let (proxy, _) = target(ctx) else { return }
            VnetManager.shared.stop(proxy: proxy)
        }
        a.register("vnet-log") { ctx in
            guard let (proxy, _) = target(ctx) else { return }
            openLog(proxy: proxy, window: ctx.window)
        }
        a.register("vnet-status") { ctx in
            ctx.arg("reply", as: ((Any?) -> Void).self)?(VnetManager.shared.status)
        }
        a.register("vnet-menu") { ctx in
            guard let menu = ctx.arg("menu", as: NSMenu.self), let (proxy, home) = target(ctx) else { return }
            let profile = Inventory.shared.profiles.first { TshEnv.bareProxy($0.proxy) == TshEnv.bareProxy(proxy) }
            if profile?.expired == true { return }
            appendMenuItems(menu, proxy: proxy, home: home, label: profile.map { $0.cluster.nilIfEmpty ?? $0.proxy } ?? proxy,
                            window: ctx.window)
        }

        // index.js: say so when a VNet comes up, fails or stops.
        var before: [String: String] = [:]
        VnetManager.shared.onState.append { v in
            let was = before[v.cluster]
            before[v.cluster] = v.state
            guard was != v.state else { return }
            switch v.state {
            case "running": StatusBus.shared.toast("VNet is running for \(v.cluster)", kind: .ok)
            case "error": StatusBus.shared.toast("VNet stopped: \(v.error ?? "tsh vnet exited")", kind: .error, seconds: 9)
            case "stopped" where was != nil: StatusBus.shared.show("VNet stopped")
            default: break
            }
        }
        AppDelegate.willTerminate.append { VnetManager.shared.stopAll() }
    }

    /// The proxy and home an action is about: `proxy`, else the host's, else
    /// the profile whose cluster or proxy is `cluster`.
    static func target(_ ctx: ActionContext) -> (String, String?)? {
        let home = ctx.arg("home", as: String.self)?.nilIfEmpty
        if let p = ctx.arg("proxy", as: String.self)?.nilIfEmpty { return (p, home) }
        if let h = ctx.host, let p = h.proxy?.nilIfEmpty { return (p, home ?? h.home) }
        if let c = ctx.arg("cluster", as: String.self)?.nilIfEmpty {
            let profs = Inventory.shared.profiles
            if let p = profs.first(where: { $0.cluster == c }) ?? profs.first(where: { TshEnv.bareProxy($0.proxy) == TshEnv.bareProxy(c) }) {
                return (p.proxy, home ?? p.homeDir)
            }
            return (c, home)
        }
        return nil
    }

    static func start(proxy: String, home: String?) {
        do {
            try VnetManager.shared.start(proxy: proxy, home: home)
            StatusBus.shared.show("Starting VNet\u{2026} macOS may ask you to approve it", seconds: 8)
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
        }
    }

    /// sidebar.js `vnetTag`: the badge a cluster row shows — (class, text, tooltip).
    static func tag(proxy: String?) -> (kind: String, text: String, tip: String)? {
        guard let v = VnetManager.shared.view(for: proxy) else { return nil }
        switch v.state {
        case "starting": return ("vnet-busy", "VNet\u{2026}", "VNet is starting \u{2014} macOS may ask to approve it")
        case "running": return ("vnet-on", "VNet", "VNet is running for this cluster: its apps answer by name. Right-click to stop it.")
        case "stopping": return ("vnet-busy", "VNet\u{2026}", "VNet is stopping")
        case "error": return ("vnet-err", "VNet \u{2715}", "VNet stopped: \(v.error ?? "tsh vnet exited") \u{2014} right-click for its output")
        default: return nil
        }
    }

    /// sidebar.js `vnetMenuItems`.
    static func appendMenuItems(_ menu: NSMenu, proxy: String, home: String?, label: String, window: WindowModel?) {
        let v = VnetManager.shared.view(for: proxy)
        if let v, v.active {
            let item = VnetMenuItem(title: v.state == "stopping" ? "Stopping VNet\u{2026}" : "\u{25C9} Stop VNet") {
                VnetManager.shared.stop(proxy: proxy)
            }
            item.toolTip = "Stops tsh vnet and takes its network setup down with it"
            item.isEnabled = v.state != "stopping"
            menu.addItem(item)
        } else {
            let item = VnetMenuItem(title: "\u{25CE} Start VNet") { start(proxy: proxy, home: home) }
            item.toolTip = "Runs tsh vnet for \(label) alone: its TCP apps answer by name, no tsh proxy needed"
            menu.addItem(item)
        }
        if v != nil {
            menu.addItem(VnetMenuItem(title: "\u{2630} VNet output\u{2026}") { openLog(proxy: proxy, window: window) })
        }
    }

    /// sidebar.js `openVnetLog`.
    static func openLog(proxy: String, window: WindowModel?) {
        Modal.sheet(window, title: "VNet", width: 720) { handle in
            VnetLogView(proxy: proxy, close: { handle.close() })
        }
    }
}

private struct VnetLogView: View {
    let proxy: String
    let close: () -> Void
    var body: some View {
        let v = VnetManager.shared.view(for: proxy)
        DialogScaffold(title: "VNet", width: 720) {
            VStack(alignment: .leading, spacing: 8) {
                Text(v.map { "\($0.state)\($0.error.map { " \u{2014} " + $0 } ?? "") \u{00B7} \($0.cluster)" } ?? "Not started.")
                    .font(.system(size: 11)).foregroundStyle(Theme.shared.p.textDim)
                OutputBlock(text: (v?.log ?? []).joined(separator: "\n").nilIfEmpty ?? "(tsh vnet has printed nothing)",
                            maxHeight: 420)
            }
        } footer: {
            Button("Close", action: close).buttonStyle(.primary).keyboardShortcut(.cancelAction)
        }
    }
}

/// An NSMenuItem that runs a closure.
final class VnetMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}
