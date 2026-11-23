import Foundation

/// The kubeconfig contexts, read once and cached for the interface (the
/// `window.api.kube.contexts({extraPaths: settings.kubeconfigPaths})` read
/// kubepanel.js's ensureLoaded() does). No caching below this — it is a local
/// file read — so `reload()` simply reads again.
@MainActor @Observable
final class KubeContexts {
    static let shared = KubeContexts()
    private(set) var contexts: [JSON] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var lastError = ""
    /// Bumped on every finished read (the original's `kubeContexts` emit).
    private(set) var generation = 0
    /// Called after each finished read.
    var onLoaded: [@MainActor () -> Void] = []

    /// Kicks off a read on first use.
    func ensureLoaded() { if !loaded && !loading { reload() } }

    func reload() {
        loading = true
        let paths = Store.shared.kubeSettingConfigPaths
        Task {
            let r = await Kube.listContexts(extraPaths: paths)
            contexts = r["contexts"].items
            lastError = r["ok"].truthy ? "" : (r["error"].string?.nilIfEmpty ?? "Could not read kubeconfig contexts")
            loading = false; loaded = true; generation += 1
            for f in onLoaded { f() }
        }
    }
}

/// The `kube:heartbeat` / `kube:agents` / `kube:heartbeatTeleport` handlers
/// with main.js's gate: nothing runs on a server while "background commands
/// on servers" is off in Settings.
@MainActor
enum KubeService {
    static let quietDetail = "Background commands on servers are off in Settings."

    static func heartbeat(_ spec: KubeSpec) async -> JSON {
        if Store.shared.kubeSettingQuietRemote { return ["ok": false, "state": "quiet", "detail": .string(quietDetail)] }
        return await KubeResources.heartbeat(spec, mfaHosts: Store.shared.kubeSettingMfaHosts)
    }

    static func heartbeatTeleport(proxy: String?, kubeCluster: String?, home: String? = nil, teleportCluster: String? = nil) async -> JSON {
        if Store.shared.kubeSettingQuietRemote { return ["ok": false, "state": "quiet", "detail": .string(quietDetail)] }
        return await KubeResources.heartbeatTeleport(proxy: proxy, kubeCluster: kubeCluster, home: home,
                                                     teleportCluster: teleportCluster, mfaHosts: Store.shared.kubeSettingMfaHosts)
    }

    /// Every helper this owner starts, stopped (quit, SIGINT/SIGTERM).
    static func stopAll() {
        KubeProxy.shared.stopAll()
        KubeLogs.shared.stopAll()
        KubeWatch.shared.stopAll()
        KubeMetrics.shared.stopAll()
        KubeForward.shared.stopAll()
    }
}

/// Registers `kube-refresh`, `kube-contexts` and the quit hook.
@MainActor
enum KubeServiceFeature {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let a = Actions.shared
        // Re-read the kubeconfig contexts.
        a.register("kube-refresh") { _ in KubeContexts.shared.reload() }
        // Query: `reply([JSON])` with the cached contexts (starting a read on first use).
        a.register("kube-contexts") { ctx in
            KubeContexts.shared.ensureLoaded()
            ctx.arg("reply", as: ((Any?) -> Void).self)?(KubeContexts.shared.contexts)
        }
        // `tsh proxy kube`, log streams, watches, metrics samplers and forwards end with the app.
        a.register("app-will-quit") { _ in KubeService.stopAll() }
    }
}
