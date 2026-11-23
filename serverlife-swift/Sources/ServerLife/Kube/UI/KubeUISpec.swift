import Foundation

/// A context row as `Kube.listContexts` returns it (id, name, contextName,
/// cluster, namespace, kubeconfigPaths, current, source, teleportProxy,
/// teleportCluster, kubeClusterName, provider …) — kubepanel.js's `c`.
typealias KubeCtx = JSON

/// The spec a browser pane / pod terminal runs with (kubepanel.js
/// `kubeBrowseSpec`): the kube-service `KubeSpec`, plus the row id and
/// whether it rides a `tsh proxy kube` tunnel.
struct KubeUISpec: Hashable {
    var spec: KubeSpec
    var id: String?
    var viaProxy = false

    var json: JSON {
        var j = spec.json
        if let id { j["id"] = .string(id) }
        if viaProxy { j["viaProxy"] = true }
        return j
    }
    init(spec: KubeSpec, id: String? = nil, viaProxy: Bool = false) { self.spec = spec; self.id = id; self.viaProxy = viaProxy }
    init(json j: JSON) {
        spec = KubeSpec(json: j)
        id = j["id"].string?.nilIfEmpty
        viaProxy = j["viaProxy"].bool ?? false
    }
}

@MainActor
enum KubeUI {
    static func s(_ c: KubeCtx, _ k: String) -> String? { c[k].stringish?.nilIfEmpty }

    /// `kubeSpecOf(c)` — just the kubeconfig and the context.
    static func specOf(_ c: KubeCtx) -> KubeSpec {
        KubeSpec(contextName: s(c, "contextName"), kubeconfigPaths: c["kubeconfigPaths"].stringArray)
    }

    /// `kubeIdentity(c)` — enough to find the cluster again after a restart.
    static func identity(_ c: KubeCtx) -> KubeSpec {
        KubeSpec(contextName: s(c, "contextName"), kubeconfigPaths: c["kubeconfigPaths"].stringArray,
                 kubeClusterName: s(c, "kubeClusterName"), teleportCluster: s(c, "teleportCluster"),
                 teleportProxy: s(c, "teleportProxy"))
    }

    /// The id a cluster's MFA mark is stored under (kubepanel.js `mfaIdFor`):
    /// the inventory id of the Teleport kube cluster, not the row id.
    static func mfaId(id: String, cluster: String?, name: String, proxy: String? = nil) -> String {
        guard let cluster = cluster?.nilIfEmpty, !name.isEmpty else { return id }
        return Teleport.kubeInventoryId(cluster: cluster, name: name, home: Tools.home(forProxy: proxy))
    }

    static func mfaId(_ c: KubeCtx) -> String {
        mfaId(id: s(c, "id") ?? "", cluster: s(c, "teleportCluster"),
              name: s(c, "kubeClusterName") ?? s(c, "name") ?? "", proxy: s(c, "teleportProxy"))
    }

    /// kubepanel.js `kubeBrowseSpec`: the plain context, unless this cluster
    /// is marked as needing MFA — then a `tsh proxy kube` tunnel is started
    /// (or reused) and its single-context kubeconfig is used instead, so the
    /// browser's many calls ride one approval.
    static func browseSpec(_ c: KubeCtx) async -> KubeUISpec {
        var base = specOf(c)
        base.teleportProxy = s(c, "teleportProxy")
        base.kubeClusterName = s(c, "kubeClusterName")
        base.teleportCluster = s(c, "teleportCluster")
        let plain = KubeUISpec(spec: base, id: s(c, "id"))
        guard s(c, "source") == "teleport", s(c, "cluster") != nil else { return plain }
        guard HostPrefs.isMfaHost(mfaId(c)) else { return plain }
        do {
            let info = try await KubeProxy.shared.ensure(s(c, "id"), kubeClusterName: s(c, "kubeClusterName") ?? s(c, "name"),
                                                         proxy: s(c, "teleportProxy"), teleportCluster: s(c, "teleportCluster"))
            var sp = KubeSpec(kubeconfigPaths: [info.kubeconfig])
            sp.teleportProxy = base.teleportProxy; sp.kubeClusterName = base.kubeClusterName; sp.teleportCluster = base.teleportCluster
            return KubeUISpec(spec: sp, id: s(c, "id"), viaProxy: true)
        } catch {
            StatusBus.shared.toast(error.localizedDescription.nilIfEmpty
                ?? "Could not start tsh proxy kube — browsing over the usual connection instead", kind: .error)
            return plain
        }
    }

    /// kubepanel.js `reviveKubeProxySpec`: restart the tunnel a `viaProxy`
    /// spec was browsing through, after "Disconnect" (or tsh dying).
    static func revive(_ k: KubeUISpec) async -> KubeUISpec {
        guard k.viaProxy, let id = k.id else { return k }
        var out = k
        if let info = KubeProxy.shared.status(id) { out.spec.kubeconfigPaths = [info.kubeconfig]; return out }
        do {
            let info = try await KubeProxy.shared.ensure(id, kubeClusterName: k.spec.kubeClusterName,
                                                         proxy: k.spec.teleportProxy, teleportCluster: k.spec.teleportCluster)
            out.spec.kubeconfigPaths = [info.kubeconfig]
            return out
        } catch {
            StatusBus.shared.toast(error.localizedDescription.nilIfEmpty ?? "Could not restart tsh proxy kube", kind: .error)
            return k
        }
    }

    /// `looksLikeDeadProxy`.
    static func looksLikeDeadProxy(_ error: String?) -> Bool {
        (error ?? "").range(of: "connection refused|ECONNREFUSED|EOF|no route to host", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Mark as needing MFA" / "Forget that this needs MFA" (+ "Disconnect"
    /// for a running tunnel) — kubepanel.js `mfaMenuItemFor`.
    static func mfaMenuItems(id: String, cluster: String?, name: String, proxy: String?) -> [CtxItem] {
        let mid = mfaId(id: id, cluster: cluster, name: name, proxy: proxy)
        let on = HostPrefs.isMfaHost(mid)
        var items = [CtxItem(on ? "Forget that this needs MFA" : "Mark as needing MFA") {
            HostPrefs.setMfaHost(Host(type: "kube", id: mid, name: name), !on)
            KubeUIState.shared.bump()
        }]
        if on, KubeProxy.shared.status(id) != nil {
            items.append(CtxItem("Disconnect (stop tsh proxy kube)",
                                 title: "Ends the tunnel this cluster has been browsing through — the next browse approves MFA again") {
                KubeProxy.shared.stop(id)
                StatusBus.shared.toast("Disconnected \(name)")
                KubeUIState.shared.bump()
            })
        }
        return items
    }
}
