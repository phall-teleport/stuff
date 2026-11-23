import AppKit
import Foundation

/// Where a kube terminal opens: beside the focused pane (right / down), or a
/// tab of its own (kubepanel.js `opts.dir` / `opts.newTab`).
enum KubePaneWhere { case right, down, newTab
    var split: String? { switch self { case .right: "right"; case .down: "down"; case .newTab: nil } }
}

/// The pod a terminal is for (kubepanel.js `pod`): name, namespace, restarts.
struct KubePodRef: Hashable {
    var name: String
    var namespace: String?
    var restarts = 0
    var containers: [String] = []
    init(name: String, namespace: String?, restarts: Int = 0, containers: [String] = []) {
        self.name = name; self.namespace = namespace; self.restarts = restarts; self.containers = containers
    }
    init(json p: JSON) {
        name = p["name"].stringish ?? ""; namespace = p["namespace"].string?.nilIfEmpty
        restarts = Int(p["restarts"].double ?? 0)
        containers = p["containers"].items.compactMap { $0.string ?? $0["name"].string }
    }
}

/// kubepanel.js `openPodExec` / `openPodLogs` / `openPodAttach` /
/// `openPodDebug` / `openNodeShell` / `openSelectorLogs`: kubectl on a pty,
/// opened beside what is focused (split right by default) or in a new tab.
@MainActor
enum KubePanes {
    /// `DEFAULT_DEBUG_IMAGE` — a small image with real tools in it.
    static let defaultDebugImage = "nicolaka/netshoot:latest"

    static func open(_ cmd: KubeCommandSpec, title: String, where w: KubePaneWhere, window: WindowModel? = nil) throws {
        let proc = try PTYProcess(exe: cmd.command, args: cmd.args, env: cmd.env)
        let backend = PTYBackend(proc, kind: "command")
        var args: [String: Any] = ["backend": backend as TerminalBackend, "title": title]
        if let s = w.split { args["split"] = s }
        Actions.shared.perform("open-backend", ActionContext(window: window ?? WindowManager.shared.focused, args: args))
    }

    static func podSpec(_ k: KubeUISpec, _ pod: KubePodRef, _ container: String?) -> KubeSpec {
        var s = k.spec
        s.namespace = pod.namespace; s.podName = pod.name; s.containerName = container?.nilIfEmpty
        return s
    }

    static func label(_ pod: KubePodRef, _ container: String?) -> String {
        container?.nilIfEmpty.map { "\(pod.name)/\($0)" } ?? pod.name
    }

    static func exec(_ k: KubeUISpec, _ pod: KubePodRef, _ container: String?, _ w: KubePaneWhere = .right) {
        do { try open(Kube.execSpec(podSpec(k, pod, container)), title: label(pod, container), where: w) }
        catch { StatusBus.shared.toast("Could not exec into \(pod.name): \(error.localizedDescription)", kind: .error) }
    }

    static func logs(_ k: KubeUISpec, _ pod: KubePodRef, _ container: String?, _ w: KubePaneWhere = .right, previous: Bool = false) {
        let title = label(pod, container) + (previous ? " (previous) logs" : " logs")
        do { try open(Kube.logSpec(podSpec(k, pod, container), previous: previous), title: title, where: w) }
        catch { StatusBus.shared.toast("Could not read logs for \(pod.name): \(error.localizedDescription)", kind: .error) }
    }

    static func attach(_ k: KubeUISpec, _ pod: KubePodRef, _ container: String?, _ w: KubePaneWhere = .right) {
        do { try open(Kube.attachSpec(podSpec(k, pod, container)), title: label(pod, container) + " (attach)", where: w) }
        catch { StatusBus.shared.toast("Could not attach to \(pod.name): \(error.localizedDescription)", kind: .error) }
    }

    static func debug(_ k: KubeUISpec, _ pod: KubePodRef, _ container: String?, _ w: KubePaneWhere = .right, image given: String? = nil) async {
        var image = given
        if image == nil {
            image = await askImage(title: "Debug container in \(pod.name)", label: "Image for the ephemeral debug container")
            if image == nil { return }
        }
        var s = podSpec(k, pod, container); s.image = image
        do { try open(Kube.debugSpec(s), title: "\(pod.name) debug (\(image!))", where: w) }
        catch { StatusBus.shared.toast("Could not start a debug container in \(pod.name): \(error.localizedDescription)", kind: .error) }
    }

    static func nodeShell(_ k: KubeUISpec, node: String, _ w: KubePaneWhere = .right, image given: String? = nil) async {
        var image = given
        if image == nil {
            image = await askImage(title: "Node shell on \(node)", label: "Image for the debug pod (mounts the node at /host)")
            if image == nil { return }
        }
        var s = k.spec; s.nodeName = node; s.image = image
        do { try open(Kube.nodeDebugSpec(s), title: "\(node) shell", where: w) }
        catch { StatusBus.shared.toast("Could not open a shell on \(node): \(error.localizedDescription)", kind: .error) }
    }

    static func selectorLogs(_ k: KubeUISpec, namespace: String?, selector: String, title: String? = nil,
                             _ w: KubePaneWhere = .right, previous: Bool = false) {
        var s = k.spec; s.namespace = namespace?.nilIfEmpty; s.selector = selector
        do { try open(Kube.logSpec(s, previous: previous), title: title ?? "logs: \(selector)", where: w) }
        catch { StatusBus.shared.toast("Could not read logs for \(selector): \(error.localizedDescription)", kind: .error) }
    }

    /// The image prompt (validate: an image is required).
    static func askImage(title: String, label: String) async -> String? {
        while true {
            guard let v = await Modal.prompt(title: title, message: label, value: defaultDebugImage) else { return nil }
            let t = v.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
            await Modal.alert(title: title, message: "An image is required.")
        }
    }

    /// The "Split right / Split down / Open in a new tab" submenu every pod
    /// action has; a plain click on the parent splits right.
    static func whereMenu(_ go: @escaping (KubePaneWhere) -> Void) -> [CtxItem] {
        [CtxItem("Split right") { go(.right) }, CtxItem("Split down") { go(.down) },
         CtxItem("Open in a new tab") { go(.newTab) }]
    }
}
