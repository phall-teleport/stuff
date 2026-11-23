import SwiftUI

/// The sidebar's side of KubeLife (sidebar.js 0.30 → 0.39): a kube cluster is
/// host-shaped (kubepanel.js `kubeHostsForProfile`) so it falls into the same
/// folders, filter and cap as the SSH nodes beside it, but its row and menu
/// are kube-ui's (`SidebarHooks.kubeClusterRow`, `kube-host-menu`).
@MainActor
enum SBKube {
    /// `state.settings.kubeEnabled !== false`.
    static var enabled: Bool { SB.store.setting("kubeEnabled", true) }

    /// `inKindShown`'s test: a kind, a `kube:` id (a ghost drawn from its
    /// watch record), or a kube_cluster resource id.
    nonisolated static func isKubeHost(_ h: Host) -> Bool {
        let kind = h.extra["kind"]?.string ?? ""
        if kind == "kube" || kind == "kube_cluster" { return true }
        if h.id.hasPrefix("kube:") { return true }
        return (h.extra["resourceId"]?.string ?? "").contains("/kube_cluster/")
    }

    /// `host.kind === 'kube'`.
    nonisolated static func isKube(_ h: Host) -> Bool { h.extra["kind"]?.string == "kube" }

    /// A Teleport cluster's kube clusters, host-shaped; none while KubeLife is off.
    static func hosts(for p: TeleportProfile) -> [Host] {
        guard enabled else { return [] }
        return SidebarHooks.kubeHostsForProfile?(p) ?? []
    }

    /// `kubeGroupCount()`: contexts with no Teleport cluster behind them.
    static var localCount: Int { enabled ? (SidebarHooks.kubeLocalCount?() ?? 0) : 0 }
}

/// What a kube cluster's own row needs to know of where it is drawn
/// (sidebar.js `rowOpts`: depth, folder, groupKey, watched).
struct SBKubeRowContext {
    var depth: Int = 0
    var folder: Bool = false
    var groupKey: String?
    var watched: Bool = false
}

extension Host {
    /// sidebar.js `hostPrefKey` (and folders.js `hostKey`, kept in step):
    /// Host.prefKey, plus the keys a kube cluster is filed and marked under —
    /// its Teleport cluster's name when there is one, else its group.
    nonisolated var sbPrefKey: String {
        if let uuid, !uuid.isEmpty { return "uuid:" + uuid }
        if SBKube.isKube(self), !name.isEmpty {
            if let tc = extra["teleportCluster"]?.string, !tc.isEmpty { return "kube:\(tc):\(name)" }
            if let gk = extra["groupKey"]?.string, !gk.isEmpty { return "kube:\(gk):\(name)" }
        }
        return prefKey
    }
}
