import SwiftUI

/// Extension points other owners fill in from their `install()`, for the
/// parts of the host list that draw their data. Each is optional: unset, the
/// sidebar says the thing is not available rather than failing.
@MainActor
enum SidebarHooks {
    /// teleport-ui (teleportpanel.js `renderTeleportTab`): the Teleport tab's contents.
    static var teleportTab: ((WindowModel) -> AnyView)?

    /// teleport-ui (`leafClusterTag`): the leaf-cluster badge on a cluster
    /// heading, or nil when the cluster has no leaves.
    static var leafClusterTag: ((TeleportProfile, WindowModel) -> AnyView?)?

    /// teleport-ui (`clusterSwitchMenuItem`): the "switch cluster" entry of a
    /// cluster heading's menu (a submenu for a handful, a dialog past ten).
    static var clusterSwitchMenuItem: ((TeleportProfile, WindowModel) -> CtxItem?)?

    /// teleport-ui (beams.js `beamMenu`): a beam row's right-click menu.
    static var beamMenu: ((Beam, WindowModel) -> [CtxItem])?

    /// fleet (macros.js): the macro list on Saved → Macros.
    static var macros: SidebarMacroSource?

    // MARK: kube-ui (kubepanel.js / kubeheartbeat.js / kubecloud.js)

    /// `kubeHostsForProfile(p)`: a Teleport cluster's kube clusters, host-shaped
    /// (`extra["kind"] = "kube"`, id `kube:…`) so they fall into the same
    /// folders, filter and cap as the SSH nodes beside them. A requestable one
    /// carries `extra["requestable"] = true` (and `requestableInfo`).
    static var kubeHostsForProfile: ((TeleportProfile) -> [Host])?

    /// `kubeContextRow` / `availableClusterRow`: the row (or tree) for a
    /// logged-in or available kube cluster. nil draws its bare name.
    static var kubeClusterRow: ((_ host: Host, _ ctx: SBKubeRowContext, WindowModel) -> AnyView?)?

    /// `kubeMarks(host)` + `listedBeatTag(proxy, name)`: the ☸ and the
    /// cluster's heartbeat tag after a kube row's name.
    static var kubeMarks: ((Host) -> AnyView?)?

    /// `cloudMenuItem(host)`: the cloud-provider entry of a kube row's menu.
    static var kubeCloudMenuItem: ((Host, WindowModel) -> CtxItem?)?

    /// `kubeGroupCount()` and `kubeGroupRows()`: contexts with no Teleport
    /// cluster behind them (raw EKS/GKE/kind), in their own “☸ Local
    /// kubeconfigs” group. The rows are drawn from
    /// `Slots.sidebarSections["kube"]`; 0 (or unset) leaves the group out.
    static var kubeLocalCount: (() -> Int)?
}

/// What the Saved → Macros list needs from macros.js. Macros are JSON in the
/// store's shape (`id, name, command, description, category, confirm,
/// repeatSeconds, interactive, noEnter, builtin, runScope …`).
@MainActor
protocol SidebarMacroSource: AnyObject {
    /// Every macro (built-ins and the user's), as `state.macros`.
    func all() -> [JSON]
    /// `macroCategories(list)`: the list grouped by category, in category order.
    func categories(_ list: [JSON]) -> [(category: String, items: [JSON])]
    func isPinned(_ id: String) -> Bool
    /// The pinned button's icon.
    func pinnedIcon(_ id: String) -> String
    /// `scopeLabel(pinnedScopeFor(id))`, e.g. "Every host".
    func pinnedScopeLabel(_ id: String) -> String
    /// `runScopeOf(m)`: "hosts", "local" or "both".
    func runScope(_ m: JSON) -> String
    /// `runScopeLabel(scope)`.
    func runScopeLabel(_ scope: String) -> String
    /// `sendMacro(m, { all })`: to the focused terminal, or every pane in the tab.
    func send(_ m: JSON, all: Bool, window: WindowModel)
    /// `runMacroOnHost(m, host, login)`: run headless and show the output.
    func runOnHost(_ m: JSON, host: Host, login: String?, window: WindowModel)
    /// `promptRepeat(m)`.
    func promptRepeat(_ m: JSON, window: WindowModel)
    /// `togglePin(m)`.
    func togglePin(_ m: JSON, window: WindowModel) async
    /// `editMacro(m)` (an empty object for a new one).
    func edit(_ m: JSON, window: WindowModel) async
    /// `deleteMacro(m)`: true when it went (or was hidden).
    func delete(_ m: JSON, window: WindowModel) async -> Bool
    /// `restoreBuiltins()`.
    func restoreBuiltins() async
    /// `moveCategory(category, delta)`: true when it moved.
    func moveCategory(_ category: String, _ delta: Int) async -> Bool
    /// `moveMacro(id, targetId, { after })`: true when it moved. Dropped in
    /// another category, the user's own macro moves into it; a built-in stays.
    func moveMacro(_ id: String, _ targetId: String, after: Bool) async -> Bool
}

extension SidebarMacroSource {
    func moveMacro(_ id: String, _ targetId: String, after: Bool) async -> Bool { false }
}
