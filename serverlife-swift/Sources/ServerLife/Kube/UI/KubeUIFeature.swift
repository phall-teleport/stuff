import SwiftUI

/// What the kube UI's views redraw on: bumped when a mark, a cache or a
/// tunnel changes (kubepanel.js `state.emit('kubeContexts')`).
@MainActor @Observable
final class KubeUIState {
    static let shared = KubeUIState()
    private(set) var generation = 0
    func bump() { generation += 1 }
}

/// Registers the kube UI's actions, hooks and the sidebar section.
@MainActor
enum KubeUIFeature {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        KubeServiceFeature.install()
        let a = Actions.shared

        a.register("kube-browser") { ctx in
            let reply = ctx.arg("reply", as: ((Bool) -> Void).self)
            Task { @MainActor in
                let ok = await KubeBrowserOpen.fromAction(ctx)
                reply?(ok)
            }
        }
        a.register("kube-port-forwards") { ctx in KubePodMenu.showActive(contextName: ctx.arg("context")) }
        a.register("kube-log-viewer") { ctx in
            guard let j = ctx.arg("spec", as: JSON.self) else { return }
            KubeLogViewer.open(KubeSpec(json: j), namespace: ctx.arg("namespace"), pod: ctx.arg("pod"),
                               container: ctx.arg("container"), selector: ctx.arg("selector"), title: ctx.arg("title"),
                               window: ctx.window)
        }
        KubeSidebar.install()
    }
}
