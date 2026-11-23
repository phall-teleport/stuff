import AppKit
import Foundation
import SwiftUI

/// Teleport tab, access requests, request monitor, recordings, live sessions, beams UI (teleportpanel.js …).
///
/// Owner: teleport-ui (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens: register
/// actions, slots, status items and timers here. Action ids and their args
/// are listed in README.md.
@MainActor
enum TeleportUIFeature {
    static func install() {
        let a = Actions.shared

        // MARK: Menu ids

        /// `openTeleportPanel`: the requests of the active profile, or a login.
        a.register("teleport-panel") { ctx in
            if let p = TUI.activeProfile() { AccessRequestsUI.openRequestsDialog(p, window: ctx.window) }
            else { TeleportPanel.openLoginDialog(window: ctx.window) }
        }
        a.register("cluster-info") { ctx in
            let proxy = ctx.arg("proxy", as: String.self) ?? TUI.profile(from: ctx)?.proxy ?? ctx.host?.proxy
            TeleportPanel.openClusterInfo(proxy: proxy, window: ctx.window)
        }
        a.register("request-monitor") { ctx in ReqMonitor.toggle(ctx.window) }
        a.register("recordings") { ctx in
            let tab = ctx.arg("tab", as: String.self)
            if let h = ctx.host, h.isTeleport || h.isBeam, tab == nil || tab == "recordings" {
                RecordingsUI.open(tab: "recordings", filter: h.name, proxy: h.proxy, window: ctx.window)
            } else {
                RecordingsUI.open(tab: tab ?? "recordings", filter: ctx.arg("filter", as: String.self),
                                  proxy: ctx.arg("proxy", as: String.self), home: ctx.arg("home", as: String.self),
                                  window: ctx.window)
            }
        }
        a.register("tsh-login") { ctx in
            var pre = TeleportPanel.LoginPrefill(proxy: ctx.arg("proxy", as: String.self) ?? "", home: ctx.arg("home", as: String.self) ?? "",
                                                 user: ctx.arg("user", as: String.self) ?? "",
                                                 cluster: ctx.arg("cluster", as: String.self) ?? "")
            if !pre.proxy.isEmpty, let saved = TUIData.listTshLogins().first(where: {
                Teleport.proxyAddress($0["proxy"].stringish) == Teleport.proxyAddress(pre.proxy)
                    && ($0["home"].stringish ?? "") == pre.home && (pre.user.isEmpty || $0["user"].stringish == pre.user)
            }) {
                pre = TeleportPanel.LoginPrefill(record: saved)
            }
            TeleportPanel.openLoginDialog(pre, window: ctx.window)
        }
        // tshenv.js editClusterEnv, from a cluster heading's menu.
        a.register("tsh-env-edit") { ctx in
            let proxy = ctx.arg("proxy", as: String.self) ?? TUI.profile(from: ctx)?.proxy ?? ctx.host?.proxy ?? ""
            guard !proxy.isEmpty else { return }
            let cluster = ctx.arg("cluster", as: String.self) ?? TUI.profile(from: ctx)?.cluster ?? ctx.host?.cluster
            TshEnvUI.edit(proxy: proxy, cluster: cluster, window: ctx.window)
        }
        // doLogin for a profile, the way it is saved to be logged into, for
        // a connect waiting on it (args profileKey; `done` (Bool) -> Void is
        // called once the login — terminal tab included — has finished).
        a.register("tsh-login-profile") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            let done = ctx.args["done"] as? (Bool) -> Void
            Task { let ok = await TeleportPanel.doLogin(p, window: ctx.window); done?(ok) }
        }
        a.register("tsh-status") { ctx in
            guard let p = TUI.profile(from: ctx) ?? TUI.activeProfile() else { TUIStatus.toast("No Teleport profile", "error"); return }
            Task { await TeleportPanel.openClusterStatus(p, window: ctx.window) }
        }

        // MARK: Cross-feature ids

        a.register("access-request-new") { ctx in
            guard let p = TUI.profile(from: ctx) ?? TUI.activeProfile() else {
                TUIStatus.toast("Log in to that cluster first", "error"); return
            }
            var resources: [ReqResource] = ctx.arg("resources", as: [ReqResource].self) ?? []
            for id in ctx.arg("resourceIds", as: [String].self) ?? [] where !resources.contains(where: { $0.id == id }) {
                var r = resourceFromId(id, profile: p)
                // The host the request came from knows the name a human uses.
                if let h = ctx.host, let uuid = h.uuid, !uuid.isEmpty, id.hasSuffix("/node/" + uuid) {
                    r.name = h.name; r.labels = h.labels
                }
                resources.append(r)
            }
            if resources.isEmpty, let h = ctx.host, h.isTeleport, let uuid = h.uuid {
                // sidebar.js `requestAccessFor(host)`: the id as the cluster writes it.
                let cluster = h.cluster?.nilIfEmpty ?? p.cluster
                resources = [ReqResource(id: "/\(cluster)/node/\(uuid)", kind: "node", name: h.name, cluster: cluster,
                                         uuid: uuid, labels: h.labels)]
            }
            Task { await AccessRequestsUI.openCreateRequest(p, prefill: .init(resources: resources), window: ctx.window) }
        }
        // sidebar.js requestKubeResourceAccessFor / kubebrowser.js
        // requestKubeResourceAccess: the picker straight at namespaces/pods
        // in one kube cluster (args profileKey/proxy/cluster, `kubeCluster`,
        // `title`, `subtitle`), then the request for what was picked.
        a.register("access-request-kube-resource") { ctx in
            guard let p = TUI.profile(from: ctx) else { TUIStatus.toast("Log in to that cluster first", "error"); return }
            let kc = ctx.arg("kubeCluster", as: String.self)?.nilIfEmpty ?? ctx.host?.uuid?.nilIfEmpty ?? ctx.host?.name
            let name = ctx.arg("subtitle", as: String.self) ?? ctx.host?.name ?? kc ?? ""
            let opts = RequestPicker.Options(title: ctx.arg("title", as: String.self) ?? "Request a namespace or pod in \(name)…",
                                             subtitle: name, initialKind: "kube_resource", initialKubeCluster: kc)
            Task {
                guard let picked = await RequestPicker.pickResources(p, opts: opts, window: ctx.window), !picked.isEmpty else { return }
                await AccessRequestsUI.openCreateRequest(p, prefill: .init(resources: picked), window: ctx.window)
            }
        }
        // sidebar.js requestAccessForMany: only the requestable hosts in a
        // multi-select (args `hosts` [Host]), one request per cluster they
        // resolve to, each prefilled with every node from it at once.
        a.register("access-request-many") { ctx in
            let hosts = ctx.arg("hosts", as: [Host].self) ?? []
            Task { await requestAccessForMany(hosts, window: ctx.window) }
        }
        a.register("access-requests") { ctx in
            AccessRequestsUI.openRequestsDialog(TUI.profile(from: ctx), window: ctx.window)
        }
        a.register("access-requests-menu") { ctx in RequestWatchUI.showRequestsMenu(window: ctx.window) }
        a.register("live-sessions") { ctx in
            if let h = ctx.host, h.isTeleport || h.isBeam, ctx.arg("proxy", as: String.self) == nil {
                LiveSessionsUI.open(for: h, window: ctx.window)
                return
            }
            let p = TUI.profile(from: ctx)
            let proxy = ctx.arg("proxy", as: String.self) ?? p?.proxy
            guard let proxy else { TUIStatus.toast("No Teleport profile", "error"); return }
            LiveSessionsUI.open(proxy: proxy, home: ctx.arg("home", as: String.self) ?? p?.homeDir,
                                match: ctx.arg("match", as: [String].self),
                                title: ctx.arg("title", as: String.self) ?? "Active sessions",
                                subtitle: ctx.arg("subtitle", as: String.self) ?? p.map(TUI.name), window: ctx.window)
        }
        a.register("request-monitor-add") { ctx in
            guard let p = TUI.profile(from: ctx) else { ReqMonitor.openPane(ctx.window); ReqMonitor.addDialog(ctx.window); return }
            ReqMonitor.openPane(ctx.window)
            Task { await ReqMonitor.addForProfile(p, window: ctx.window) }
        }

        // Profile actions the sidebar's cluster heading offers.
        a.register("tsh-logout") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.doLogout(p, window: ctx.window) }
        }
        a.register("tsh-make-active") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.makeProfileActive(p) }
        }
        a.register("tsh-remove-profile") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.removeExpiredProfile(p, window: ctx.window) }
        }
        a.register("tsh-copy-login") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            TeleportPanel.copyLoginCommand(p)
        }
        a.register("tsh-config") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.openTshConfigDialog(p, window: ctx.window) }
        }
        // The ⏳ "expires soon" badge: log out and straight back in, one confirmation.
        a.register("tsh-relogin-expiring") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.doRelogin(p, window: ctx.window) }
        }
        a.register("tsh-relogin") { ctx in
            // The heading's "Log in again": the saved record, else a dialog for this proxy.
            guard let p = TUI.profile(from: ctx) else { return }
            if let saved = TeleportPanel.savedClusterFor(p) { TeleportPanel.loginFromSaved(saved, window: ctx.window) }
            else { TeleportPanel.openLoginDialog(.init(proxy: p.proxy, home: p.homeDir), window: ctx.window) }
        }
        a.register("cluster-switch") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            TeleportPanel.openClusterSwitcher(p, window: ctx.window)
        }
        a.register("cluster-web") { ctx in
            let p = TUI.profile(from: ctx)
            TeleportPanel.openClusterWeb(proxy: ctx.arg("proxy", as: String.self) ?? p?.proxy,
                                         cluster: ctx.arg("cluster", as: String.self) ?? p?.cluster)
        }

        // Beams.
        a.register("beam-start") { ctx in
            guard let p = TUI.profile(from: ctx) else { TUIStatus.toast("Log in to a cluster first", "error"); return }
            Task { await BeamsUI.start(p, phase: ctx.arg("phase", as: String.self) ?? "", window: ctx.window) }
        }
        // The services in a beam and their logs (beams.js `showBeamServices`).
        a.register("beam-services") { ctx in
            guard let b = BeamsUI.beam(from: ctx) else { return }
            Task { await BeamsUI.showServices(b, window: ctx.window) }
        }
        // The Phase list read for a cluster (query; reply `BeamPhaseLists.PhaseList?`),
        // and a fresh read of it (`phase-refresh`, args `profileKey`).
        a.register("phase-list") { ctx in
            let px = ctx.arg("proxy", as: String.self) ?? TUI.profile(from: ctx)?.proxy ?? ""
            ctx.arg("reply", as: ((Any?) -> Void).self)?(BeamPhaseLists.shared.phaseList(px))
        }
        a.register("phase-refresh") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await BeamPhaseLists.shared.refreshPhases(p) }
        }
        BeamPhaseLists.shared.hookBeams()
        a.register("beam-menu") { ctx in
            guard let b = BeamsUI.beam(from: ctx) else { return }
            if let menu = ctx.arg("menu", as: NSMenu.self) { BeamsUI.appendMenu(menu, b, window: ctx.window) }
            else { BeamsUI.showMenu(b, window: ctx.window) }
        }
        a.register("beam-open") { ctx in
            guard let b = BeamsUI.beam(from: ctx) else { return }
            BeamsUI.open(b, filesOnly: ctx.arg("filesOnly", as: Bool.self) ?? false, window: ctx.window)
        }
        a.register("beam-delete") { ctx in
            guard let b = BeamsUI.beam(from: ctx) else { return }
            Task { await BeamsUI.remove(b, window: ctx.window) }
        }

        // The Sessions dialog's history tab: menu id `history` belongs to the
        // hosts owner; filled in here only if nobody else has registered it.
        a.register("sessions-history") { ctx in RecordingsUI.open(tab: "history", window: ctx.window) }
        if !a.isRegistered("history") {
            a.register("history") { ctx in RecordingsUI.open(tab: "history", window: ctx.window) }
        }

        ReqMonitor.install()

        // What the sidebar draws from here.
        SidebarHooks.teleportTab = { w in AnyView(TeleportTabView(window: w)) }
        SidebarHooks.leafClusterTag = { p, w in
            TeleportPanel.leavesFor(p).isEmpty ? nil : AnyView(LeafClusterTag(p: p, window: w))
        }
        SidebarHooks.clusterSwitchMenuItem = { p, w in TeleportPanel.clusterSwitchMenuItem(p, window: w) }
        SidebarHooks.beamMenu = { b, w in BeamsUI.menuItems(b, window: w) }

        // Only under --snapshot: the tab in a panel of its own, so it can be
        // looked at before the sidebar embeds it.
        if CommandLine.arguments.contains("--snapshot") {
            a.register("teleport-ui-debug-tab") { ctx in
                guard let w = ctx.window else { return }
                Modal.panel(id: "tui-debug-tab", title: "Teleport tab", width: 320, height: 760) { _ in
                    VStack(spacing: 0) {
                        // Two made-up profiles, to see the row with something in it.
                        ProfileRow(p: TeleportProfile(proxy: "lab.example.com:443", cluster: "lab", username: "alice@example.com",
                                                      logins: ["root", "ubuntu"], roles: ["access"], activeRequests: ["4a1b"],
                                                      validUntil: TPText.isoString(ms: nowMs() + 5 * 3600_000), active: true,
                                                      home: "/tmp/tsh-work", homeDir: "/tmp/tsh-work", homeName: "work"), window: w)
                        ProfileRow(p: TeleportProfile(proxy: "old.example.com:443", cluster: "old", username: "alice",
                                                      validUntil: "2024-01-01T00:00:00Z", expired: true), window: w)
                        TeleportTabView(window: w)
                    }.background(Theme.shared.p.panel)
                }
            }
        }
    }

    /// sidebar.js `requestAccessForMany`. Sequential, not parallel: each
    /// is its own modal, and two at once would stack one behind the other.
    static func requestAccessForMany(_ hosts: [Host], window: WindowModel?) async {
        let requestable = hosts.filter { $0.extra["requestable"]?.truthy == true }
        if requestable.isEmpty { TUIStatus.toast("None of the selected hosts are requestable", "error"); return }
        let inv = Inventory.shared
        var order: [String] = []
        var groups: [String: (TeleportProfile, [ReqResource])] = [:]
        var unmatched = 0
        for h in requestable {
            guard let p = inv.profile(for: h) ?? inv.profiles.first(where: { $0.cluster == h.cluster }),
                  let uuid = h.uuid?.nilIfEmpty else { unmatched += 1; continue }
            let cluster = h.cluster?.nilIfEmpty ?? p.cluster
            let r = ReqResource(id: "/\(cluster)/node/\(uuid)", kind: "node", name: h.name, cluster: cluster, uuid: uuid,
                                labels: h.labels)
            if groups[p.key] == nil { order.append(p.key); groups[p.key] = (p, []) }
            groups[p.key]?.1.append(r)
        }
        if groups.isEmpty { TUIStatus.toast("Log in to that cluster first", "error"); return }
        for k in order {
            guard let (p, rs) = groups[k] else { continue }
            await AccessRequestsUI.openCreateRequest(p, prefill: .init(resources: rs), window: window)
        }
        if unmatched > 0 {
            TUIStatus.toast("\(unmatched) host\(unmatched == 1 ? "" : "s") skipped — log in to \(unmatched == 1 ? "its" : "their") cluster first", "error")
        }
    }

    /// `/cluster/kind/name[/sub]` → a resource the request dialog can show.
    static func resourceFromId(_ id: String, profile p: TeleportProfile) -> ReqResource {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let cluster = parts.count > 1 ? parts[1] : p.cluster
        let kind = parts.count > 2 ? parts[2] : "node"
        let name = parts.count > 3 ? parts[3] : id
        var label = name
        if kind == "node", let n = Inventory.shared.nodes(for: p).first(where: { $0.uuid == name }) { label = n.name }
        return ReqResource(id: id, kind: kind, name: label, cluster: cluster, uuid: kind == "node" ? name : "")
    }
}
