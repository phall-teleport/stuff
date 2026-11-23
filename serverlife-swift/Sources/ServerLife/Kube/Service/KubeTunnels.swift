import Foundation
import Observation

// kubeforward.js (`kubectl port-forward`) and kubeproxy.js (`tsh proxy kube`):
// spawn, scan the output for the line that says it is up, keep running until
// stopped or the app quits.

/// Spawn a process and wait for its output to say it is up. `scan` sees the
/// accumulated text (stdout and stderr both) and returns a value once ready.
final class KubeScanStart<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var settled = false
    private var cont: CheckedContinuation<T, Error>?
    private(set) var process: RunningProcess?

    /// `onExit(code, settledAlready, text)` is told of every exit (an unexpected death after start too).
    static func run(_ exe: String, _ args: [String], env: [String: String?], timeout: TimeInterval, timeoutMessage: String,
                    spawnError: @escaping @Sendable (String) -> String,
                    scan: @escaping @Sendable (String) -> T?,
                    exitMessage: @escaping @Sendable (Int32, String) -> String,
                    onExit: @escaping @Sendable (Int32) -> Void) async throws -> (T, RunningProcess) {
        let s = KubeScanStart<T>()
        let v: T = try await withCheckedThrowingContinuation { c in
            s.cont = c
            let feed: (Data) -> Void = { d in
                s.lock.lock()
                s.out += String(decoding: d, as: UTF8.self)
                let text = s.out, done = s.settled
                s.lock.unlock()
                if !done, let v = scan(text) { s.finish(.success(v)) }
            }
            do {
                s.process = try RunningProcess(exe, args, env: env, onStdout: feed, onStderr: feed, onExit: { code in
                    onExit(code)
                    s.lock.lock(); let text = s.out; s.lock.unlock()
                    s.finish(.failure(AppError(exitMessage(code, text))))
                })
            } catch {
                s.finish(.failure(AppError(spawnError((error as? AppError)?.message ?? error.localizedDescription))))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { s.finish(.failure(AppError(timeoutMessage))) }
        }
        return (v, s.process!)
    }

    private func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard !settled, let c = cont else { lock.unlock(); return }
        settled = true; cont = nil
        lock.unlock()
        if case .failure = r { process?.terminate() }
        c.resume(with: r)
    }
}

/// The last non-empty line of some output.
func kubeLastLine(_ text: String) -> String? {
    text.trimmed.components(separatedBy: "\n").filter { !$0.isEmpty }.last
}

// MARK: - Port-forwards

/// `kubectl port-forward` to one pod/service/workload; several at once, keyed by id.
/// `forwards` is observable — it is the push main.js sent as `kube:forwardUpdate`
/// (the sidebar's active list and the browser's count badge read it).
@MainActor @Observable final class KubeForward {
    static let shared = KubeForward()
    struct Info: Sendable {
        var port: Int; var resource: String; var name: String; var namespace: String?
        var remotePort: String; var contextName: String?; var startedAt: Double
    }
    @ObservationIgnored private var running: [String: (p: RunningProcess, info: Info)] = [:]
    /// `list()`, kept current: `[{id, port, resource, name, namespace, remotePort, contextName, startedAt}]`.
    private(set) var forwards: [JSON] = []
    @ObservationIgnored private var listeners: [() -> Void] = []

    /// `onChange`: called whenever a forward starts, stops or dies on its own.
    func onChange(_ f: @escaping () -> Void) { listeners.append(f) }

    private func notify() {
        forwards = list()
        for f in listeners { f() }
    }

    func list() -> [JSON] {
        running.sorted { $0.value.info.startedAt < $1.value.info.startedAt }.map { id, r in Self.json(id, r.info) }
    }

    static func json(_ id: String?, _ i: Info) -> JSON {
        var o: [String: JSON] = ["port": .number(Double(i.port)), "resource": .string(i.resource), "name": .string(i.name),
                                 "namespace": i.namespace.map { .string($0) } ?? .null, "remotePort": .string(i.remotePort),
                                 "contextName": i.contextName.map { .string($0) } ?? .null, "startedAt": .number(Double(i.startedAt))]
        if let id { o["id"] = .string(id) }
        return .object(o)
    }

    /// Start (or reuse) a forward. A blank/0 `localPort` lets kubectl pick one,
    /// read back from its "Forwarding from…" line. Throws with kubectl's last line.
    func start(id: String?, spec: KubeSpec, resource: String?, name: String?, namespace: String?,
               localPort: String? = nil, remotePort: String?) async throws -> Info {
        KubeServiceFeature.install()
        guard let id = id?.nilIfEmpty else { throw AppError("No id given.") }
        guard let resource = resource?.nilIfEmpty, let name = name?.nilIfEmpty else { throw AppError("No resource to forward.") }
        guard let remotePort = remotePort?.nilIfEmpty, remotePort != "0" else { throw AppError("No remote port given.") }
        if let e = running[id], e.p.isRunning { return e.info }
        let k = Kube.kubectlArgsFor(spec.with(namespace: namespace))
        let lp = (localPort?.nilIfEmpty).flatMap { $0 == "0" ? nil : $0 } ?? ""
        let args = k.baseArgs + ["port-forward", "\(resource)/\(name)", "\(lp):\(remotePort)"]
        let ns = namespace?.nilIfEmpty, ctx = spec.contextName?.nilIfEmpty
        let (info, p) = try await KubeScanStart<Info>.run(k.bin, args, env: k.env, timeout: 20,
            timeoutMessage: "Timed out waiting for \"kubectl port-forward \(resource)/\(name)\".",
            spawnError: { "Could not run kubectl: \($0)" },
            scan: { text in
                guard let m = TPText.match(#"Forwarding from 127\.0\.0\.1:(\d+) ->"#, text), let n = m[1], let port = Int(n) else { return nil }
                return Info(port: port, resource: resource, name: name, namespace: ns, remotePort: remotePort, contextName: ctx, startedAt: nowMs())
            },
            exitMessage: { code, text in kubeLastLine(text) ?? "kubectl port-forward exited with code \(code)" },
            onExit: { _ in
                // An unexpected death is a change too — the same removal either way.
                kubeOnMain { KubeForward.shared.exited(id) }
            })
        running[id] = (p, info)
        notify()
        return info
    }

    /// `kube:forwardStart`'s shape: `{ok:true, …info}` or `{ok:false, error}`.
    func startJSON(id: String?, spec: KubeSpec, resource: String?, name: String?, namespace: String?,
                   localPort: String? = nil, remotePort: String?) async -> JSON {
        do {
            let i = try await start(id: id, spec: spec, resource: resource, name: name, namespace: namespace, localPort: localPort, remotePort: remotePort)
            var o = Self.json(nil, i); o["ok"] = true; return o
        } catch { return kubeFail(error) }
    }

    private func exited(_ id: String) {
        // Only the forward that just died: a reused id may already hold a new one.
        guard let e = running[id], !e.p.isRunning else { return }
        running[id] = nil
        notify()
    }

    @discardableResult
    func stop(_ id: String) -> Bool {
        guard let e = running.removeValue(forKey: id) else { return false }
        e.p.terminate()
        notify()
        return true
    }

    func stopAll() { for id in Array(running.keys) { stop(id) } }
}

// MARK: - tsh proxy kube

/// `tsh proxy kube` — a local proxy serving a kubeconfig plain kubectl can use,
/// for a cluster marked as needing per-session MFA (one approval, not one per
/// call). One per context id; concurrent starts for one id share the first.
@MainActor @Observable final class KubeProxy {
    static let shared = KubeProxy()
    struct Info: Sendable { var port: Int; var kubeconfig: String; var kubeClusterName: String; var startedAt: Double }
    @ObservationIgnored private var running: [String: (p: RunningProcess, info: Info)] = [:]
    @ObservationIgnored private var starting: [String: Task<Info, Error>] = [:]
    /// Context ids with a proxy up (observable).
    private(set) var runningIds: Set<String> = []

    nonisolated static func stripAnsi(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// Start (or reuse) a proxy for one Teleport kube cluster context.
    func ensure(_ id: String?, kubeClusterName: String?, proxy: String? = nil, home: String? = nil,
                teleportCluster: String? = nil) async throws -> Info {
        KubeServiceFeature.install()
        guard let id = id?.nilIfEmpty else { throw AppError("No context given.") }
        guard let kube = kubeClusterName?.nilIfEmpty else { throw AppError("No Kubernetes cluster chosen.") }
        if let e = running[id], e.p.isRunning { return e.info }
        if let t = starting[id] { return try await t.value }
        let t = Task { @MainActor in try await self.start(id, kube: kube, proxy: proxy, home: home, teleportCluster: teleportCluster) }
        starting[id] = t
        defer { starting[id] = nil }
        return try await t.value
    }

    private func start(_ id: String, kube: String, proxy: String?, home: String?, teleportCluster: String?) async throws -> Info {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["proxy", "kube", kube, "--proxy-log-output=stdout"]
        if let c = teleportCluster?.nilIfEmpty { args.append("--cluster=" + c) }
        let env = Tools.tshEnv(home: home?.nilIfEmpty ?? Tools.home(forProxy: proxy))
        let (info, p) = try await KubeScanStart<Info>.run(Tools.tsh, args, env: env, timeout: 30,
            timeoutMessage: "Timed out waiting for \"tsh proxy kube \(kube)\".",
            spawnError: { "Could not run tsh: \($0)" },
            scan: { text in
                guard let pm = TPText.match(#"Started local proxy for Kubernetes on [^:]+:(\d+)"#, text), let ps = pm[1], let port = Int(ps),
                      let cm = TPText.match(#"KUBECONFIG="([^"]+)""#, text), let cfg = cm[1] else { return nil }
                return Info(port: port, kubeconfig: cfg, kubeClusterName: kube, startedAt: nowMs())
            },
            exitMessage: { code, text in kubeLastLine(KubeProxy.stripAnsi(text)) ?? "tsh proxy kube exited with code \(code)" },
            onExit: { _ in kubeOnMain { KubeProxy.shared.exited(id) } })
        running[id] = (p, info)
        runningIds.insert(id)
        return info
    }

    private func exited(_ id: String) {
        guard let e = running[id], !e.p.isRunning else { return }
        running[id] = nil
        runningIds.remove(id)
    }

    static func json(_ i: Info) -> JSON {
        ["port": .number(Double(i.port)), "kubeconfig": .string(i.kubeconfig), "kubeClusterName": .string(i.kubeClusterName),
         "startedAt": .number(Double(i.startedAt))]
    }

    /// `kube:proxyStart`: `{ok:true, port, kubeconfig, kubeClusterName, startedAt}` or `{ok:false, error}`.
    func startJSON(_ id: String?, kubeClusterName: String?, proxy: String? = nil, home: String? = nil, teleportCluster: String? = nil) async -> JSON {
        do {
            var o = Self.json(try await ensure(id, kubeClusterName: kubeClusterName, proxy: proxy, home: home, teleportCluster: teleportCluster))
            o["ok"] = true
            return o
        } catch { return kubeFail(error) }
    }

    @discardableResult
    func stop(_ id: String) -> Bool {
        guard let e = running.removeValue(forKey: id) else { return false }
        e.p.terminate()
        runningIds.remove(id)
        return true
    }

    func stopAll() { for id in Array(running.keys) { stop(id) } }

    /// `kube:proxyStatus`'s `info` (nil when none is running).
    func status(_ id: String) -> Info? { running[id]?.info }
}
