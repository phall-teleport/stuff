import Foundation

/// What every kube call is given (the renderer's `spec`): which context in
/// which kubeconfig files, and — for a pod terminal, logs or debugging — the
/// pod, container, shell and image. Built from a context row (`Kube.listContexts`)
/// or a saved profile's `spec` with `KubeSpec(json:)`.
struct KubeSpec: Sendable, Hashable {
    var contextName: String?
    var kubeconfigPaths: [String] = []
    var namespace: String?
    var podName: String?
    var containerName: String?
    var shell: String?
    var image: String?
    var nodeName: String?
    var selector: String?
    var kubeClusterName: String?
    var teleportCluster: String?
    var teleportProxy: String?
    var source: String?

    init(contextName: String? = nil, kubeconfigPaths: [String] = [], namespace: String? = nil,
         podName: String? = nil, containerName: String? = nil, shell: String? = nil, image: String? = nil,
         nodeName: String? = nil, selector: String? = nil, kubeClusterName: String? = nil,
         teleportCluster: String? = nil, teleportProxy: String? = nil, source: String? = nil) {
        self.contextName = contextName; self.kubeconfigPaths = kubeconfigPaths; self.namespace = namespace
        self.podName = podName; self.containerName = containerName; self.shell = shell; self.image = image
        self.nodeName = nodeName; self.selector = selector; self.kubeClusterName = kubeClusterName
        self.teleportCluster = teleportCluster; self.teleportProxy = teleportProxy; self.source = source
    }

    init(json j: JSON) {
        func s(_ k: String) -> String? { j[k].stringish?.nilIfEmpty }
        contextName = s("contextName")
        kubeconfigPaths = j["kubeconfigPaths"].stringArray
        namespace = s("namespace"); podName = s("podName"); containerName = s("containerName")
        shell = s("shell"); image = s("image"); nodeName = s("nodeName"); selector = s("selector")
        kubeClusterName = s("kubeClusterName"); teleportCluster = s("teleportCluster")
        teleportProxy = s("teleportProxy"); source = s("source")
    }

    var json: JSON {
        var o: [String: JSON] = ["kubeconfigPaths": JSON(kubeconfigPaths)]
        let pairs: [(String, String?)] = [
            ("contextName", contextName), ("namespace", namespace), ("podName", podName),
            ("containerName", containerName), ("shell", shell), ("image", image), ("nodeName", nodeName),
            ("selector", selector), ("kubeClusterName", kubeClusterName), ("teleportCluster", teleportCluster),
            ("teleportProxy", teleportProxy), ("source", source),
        ]
        for (k, v) in pairs { if let v { o[k] = .string(v) } }
        return .object(o)
    }

    /// `{ ...spec, namespace }`.
    func with(namespace ns: String?) -> KubeSpec { var c = self; c.namespace = ns?.nilIfEmpty; return c }
    /// `namespace ? { ...spec, namespace } : spec`.
    func overriding(namespace ns: String?) -> KubeSpec { (ns?.isEmpty ?? true) ? self : with(namespace: ns) }
    /// `namespace ? { ...spec, namespace } : { ...spec, namespace: null }`.
    func scoped(namespace ns: String?) -> KubeSpec { with(namespace: ns) }
}

/// A command a terminal pane runs: `{command, args, env}` (execSpec, logSpec …).
struct KubeCommandSpec: Sendable {
    var command: String
    var args: [String]
    var env: [String: String?]

    /// The environment as plain strings over the process's own (for a pty).
    var fullEnvironment: [String: String] { Proc.environment(env) }

    var json: JSON {
        var e: [String: JSON] = [:]
        for (k, v) in env { if let v { e[k] = .string(v) } }
        return ["command": .string(command), "args": JSON(args), "env": .object(e)]
    }
}

// Small JSON helpers for the ports: JavaScript's `x || ''` and `x || 0`.
extension JSON {
    /// `String(x || '')` for a value that should be a string.
    var kStr: String { stringish ?? "" }
    /// `x || 0`.
    var kNum: Double { double ?? 0 }
    /// `x ?? fallback` for numbers.
    func kNum(_ fallback: Double) -> Double { double ?? fallback }
    /// The object entries in key order (sorted — JSON objects here keep none).
    var kSortedEntries: [(String, JSON)] { entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
}

/// `a || b` on strings.
func kubeOr(_ a: String?, _ b: String) -> String { (a?.isEmpty ?? true) ? b : a! }

/// JS `Date.parse` on the RFC 3339 times Kubernetes writes; nil when unreadable.
func kubeParseDate(_ s: String?) -> Double? { TPText.parseDate(s) }

/// The number as JS would print it (`String(3)` → "3").
func kubeNumText(_ d: Double) -> String {
    if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
    return String(d)
}

/// An ok/error result object, the shape every handler answered with.
func kubeFail(_ error: String, _ extra: [String: JSON] = [:]) -> JSON {
    var o = extra
    o["ok"] = false
    o["error"] = .string(error)
    return .object(o)
}

func kubeOk(_ extra: [String: JSON] = [:]) -> JSON {
    var o = extra
    o["ok"] = true
    return .object(o)
}

/// `{ok:false, error: e.message}` for a thrown error.
func kubeFail(_ error: Error, _ extra: [String: JSON] = [:]) -> JSON {
    kubeFail((error as? AppError)?.message ?? error.localizedDescription, extra)
}
