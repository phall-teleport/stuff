import Foundation

// kubelogs.js, kubewatch.js and kubemetrics.js: the long-lived kubectl
// processes (and the one poll) the browser and the Log Viewer keep running
// until stopped. Each is keyed by an id; main.js made the ids
// (`logs-N-<now>`, `watch-N-<now>`, `metrics-N-<now>`) and pushed events as
// `kube:logsData` / `kube:watchData` / `kube:metricsData` — here the caller
// passes `onEvent`, called on the main actor, with the same `{id, …}` shapes.

/// Splits a byte stream into lines the way Node's readline does (\n or \r\n,
/// the last unterminated line flushed at the end).
final class KubeLineSplitter: @unchecked Sendable {
    private var buf = Data()
    private let lock = NSLock()
    func feed(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buf.append(d)
        var lines: [String] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            var line = buf[buf.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            buf = Data(buf[(nl + 1)...])
        }
        return lines
    }
    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !buf.isEmpty else { return [] }
        var line = buf
        if line.last == 0x0D { line = line.dropLast() }
        buf = Data()
        return [String(decoding: line, as: UTF8.self)]
    }
}

/// Hop to the main actor in order (one serial queue).
@inline(__always) func kubeOnMain(_ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
}

// MARK: - Logs

/// Live log tailing for the Log Viewer — one pod, or every pod behind a label
/// selector, line by line (stdout and stderr both: a crashing container's last
/// words are usually on stderr).
@MainActor final class KubeLogs {
    static let shared = KubeLogs()
    private var running: [String: RunningProcess] = [:]
    private var seq = 0

    /// `kube:logsStart`: `{id, line}` per line, then `{id, done:true, code}` once.
    /// Returns `{ok, id}` or `{ok:false, error}`.
    @discardableResult
    func start(_ spec: KubeSpec, id given: String? = nil, podName: String? = nil, selector: String? = nil, namespace: String? = nil,
               containerName: String? = nil, allContainers: Bool = false, tail: Int? = 200, previous: Bool = false,
               onEvent: @escaping @MainActor (JSON) -> Void) -> JSON {
        KubeServiceFeature.install()
        seq += 1
        let id = given ?? "logs-\(seq)-\(Int64(nowMs()))"
        do {
            if id.isEmpty { throw AppError("No id given.") }
            if running[id] != nil { throw AppError("That log session is already running.") }
            var s = spec
            s.namespace = namespace; s.podName = podName; s.selector = selector; s.containerName = containerName
            let a = try Kube.logArgs(s, follow: true, previous: previous, tail: tail ?? 200, allContainers: allContainers)
            let out = KubeLineSplitter(), err = KubeLineSplitter()
            let send: @Sendable ([String]) -> Void = { lines in
                guard !lines.isEmpty else { return }
                kubeOnMain { for l in lines { onEvent(["id": .string(id), "line": .string(l)]) } }
            }
            let p = try RunningProcess(a.bin, a.args, env: a.env,
                onStdout: { send(out.feed($0)) }, onStderr: { send(err.feed($0)) },
                onExit: { code in
                    send(out.flush() + err.flush())
                    kubeOnMain {
                        guard KubeLogs.shared.running.removeValue(forKey: id) != nil else { return }
                        onEvent(["id": .string(id), "done": true, "code": .number(Double(code))])
                    }
                })
            running[id] = p
            return ["ok": true, "id": .string(id)]
        } catch {
            return kubeFail(error)
        }
    }

    /// `kube:logsStop`.
    @discardableResult
    func stop(_ id: String) -> Bool {
        guard let p = running.removeValue(forKey: id) else { return false }
        p.terminate()
        return true
    }

    func stopAll() { for id in Array(running.keys) { stop(id) } }
}

// MARK: - Watch

/// Live updates for the full cluster browser — `kubectl get <kind> -o yaml
/// --watch`, each object its own YAML document separated by a `---` line.
/// It cannot say a resource was deleted (kubectl never prints that), so the
/// browser pairs it with a slower periodic re-list.
@MainActor final class KubeWatch {
    static let shared = KubeWatch()
    private final class Entry { let p: RunningProcess; var idle: DispatchWorkItem?; init(_ p: RunningProcess) { self.p = p } }
    private var running: [String: Entry] = [:]
    private var seq = 0

    /// The buffering part, pure: complete documents and the remainder. A
    /// document's own "---" text never splits early — only a line with nothing else.
    nonisolated static func splitDocuments(_ buffered: String) -> (complete: [String], remainder: String) {
        guard let re = try? NSRegularExpression(pattern: #"\n---[ \t]*\r?\n"#) else { return ([], buffered) }
        let ns = buffered as NSString
        var parts: [String] = []
        var last = 0
        for m in re.matches(in: buffered, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        let remainder = ns.substring(from: last)
        return (parts.filter { !$0.trimmed.isEmpty }, remainder)
    }

    /// `kube:watchStart`: `{id, row}` per object (shaped by `rowFrom`, the same
    /// row a list fetch returns), then `{id, done:true, code, error}` once.
    @discardableResult
    func start(_ spec: KubeSpec, id given: String? = nil, kind: String?, namespaced: Bool = true, namespace: String? = nil,
               selector: String? = nil, onEvent: @escaping @MainActor (JSON) -> Void) -> JSON {
        KubeServiceFeature.install()
        seq += 1
        let id = given ?? "watch-\(seq)-\(Int64(nowMs()))"
        do {
            if id.isEmpty { throw AppError("No id given.") }
            guard let kind = kind?.nilIfEmpty else { throw AppError("No resource kind to watch.") }
            if running[id] != nil { throw AppError("That watch is already running.") }
            let k = Kube.kubectlArgsFor(namespaced ? spec.with(namespace: namespace) : spec.with(namespace: nil))
            let scope = !namespaced ? [] : (namespace?.isEmpty == false ? [] : ["-A"])
            let sel = selector?.nilIfEmpty.map { ["-l", $0] } ?? []
            let args = k.baseArgs + ["get", kind] + scope + sel + ["-o", "yaml", "--watch"]
            let decoder = KubeLineSplitter()   // only for its lock; text is accumulated below
            _ = decoder
            nonisolated(unsafe) var errText = ""
            let errLock = NSLock()
            let p = try RunningProcess(k.bin, args, env: k.env,
                onStdout: { d in
                    let text = String(decoding: d, as: UTF8.self)
                    kubeOnMain { KubeWatch.shared.chunk(id, text, onEvent) }
                },
                onStderr: { d in errLock.lock(); errText += String(decoding: d, as: UTF8.self); errLock.unlock() },
                onExit: { code in
                    errLock.lock(); let e = errText; errLock.unlock()
                    kubeOnMain { KubeWatch.shared.exited(id, code, e, onEvent) }
                })
            running[id] = Entry(p)
            buffers[id] = ""
            return ["ok": true, "id": .string(id)]
        } catch {
            return kubeFail(error)
        }
    }

    private var buffers: [String: String] = [:]

    private func emitDoc(_ text: String, _ id: String, _ onEvent: @MainActor (JSON) -> Void) {
        let t = text.trimmed
        guard !t.isEmpty, let object = try? KubeYAML.load(t), object.truthy else { return }
        onEvent(["id": .string(id), "row": KubeResources.rowFrom(object)])
    }

    private func chunk(_ id: String, _ text: String, _ onEvent: @escaping @MainActor (JSON) -> Void) {
        guard let e = running[id] else { return }
        e.idle?.cancel(); e.idle = nil
        let (complete, remainder) = Self.splitDocuments((buffers[id] ?? "") + text)
        buffers[id] = remainder
        for d in complete { emitDoc(d, id, onEvent) }
        if !remainder.trimmed.isEmpty {
            // The last object arrives with no separator after it: flush it after a quiet moment.
            let w = DispatchWorkItem {
                MainActor.assumeIsolated {
                    let w = KubeWatch.shared
                    guard w.running[id] != nil, let b = w.buffers[id], !b.trimmed.isEmpty,
                          let object = try? KubeYAML.load(b.trimmed) else { return }
                    w.buffers[id] = ""
                    if object.truthy { onEvent(["id": .string(id), "row": KubeResources.rowFrom(object)]) }
                }
            }
            e.idle = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
    }

    private func exited(_ id: String, _ code: Int32, _ errText: String, _ onEvent: @MainActor (JSON) -> Void) {
        guard let e = running.removeValue(forKey: id) else { return }   // stop() already called
        e.idle?.cancel()
        emitDoc(buffers.removeValue(forKey: id) ?? "", id, onEvent)
        let lastErr = errText.trimmed.components(separatedBy: "\n").filter { !$0.isEmpty }.last
        onEvent(["id": .string(id), "done": true, "code": .number(Double(code)),
                 "error": code != 0 ? (lastErr.map { .string($0) } ?? .null) : .null])
    }

    /// `kube:watchStop`.
    @discardableResult
    func stop(_ id: String) -> Bool {
        guard let e = running.removeValue(forKey: id) else { return false }
        e.idle?.cancel()
        buffers[id] = nil
        e.p.terminate()
        return true
    }

    func stopAll() { for id in Array(running.keys) { stop(id) } }
}

// MARK: - Metrics

/// History for the full browser's CPU/memory charts. `kubectl top` has no
/// streaming mode, so this polls `top()` and turns kubectl's strings
/// ("123m", "456Mi", "45%") into numbers; the UI keeps the history.
@MainActor final class KubeMetrics {
    static let shared = KubeMetrics()
    private var running: [String: Task<Void, Never>] = [:]
    private var seq = 0

    /// "123m" → 123, "2" → 2000, anything unparseable → 0 (never NaN).
    nonisolated static func parseCpu(_ v: String?) -> Double {
        let s = (v ?? "").trimmed
        if s.hasSuffix("m") { let f = KubeResources.jsParseFloat(s); return f.isNaN ? 0 : f.rounded(.toNearestOrAwayFromZero) }
        let f = KubeResources.jsParseFloat(s)
        return ((f.isNaN ? 0 : f) * 1000).rounded(.toNearestOrAwayFromZero)
    }

    nonisolated static let memMult: [String: Double] = [
        "": 1, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
        "Ki": 1024, "Mi": 1_048_576, "Gi": 1_073_741_824, "Ti": 1_099_511_627_776,
    ]

    /// "456Mi" → bytes, a bare number → itself. Unparseable → 0.
    nonisolated static func parseMemBytes(_ v: String?) -> Double {
        guard let m = TPText.match(#"^([\d.]+)([KMGT]i?)?$"#, (v ?? "").trimmed), let n = m[1] else { return 0 }
        let f = KubeResources.jsParseFloat(n)
        let unit = m.count > 2 ? (m[2] ?? "") : ""
        return ((f.isNaN ? 0 : f) * (memMult[unit] ?? 1)).rounded(.toNearestOrAwayFromZero)
    }

    /// "45%" → 45. Unparseable → 0.
    nonisolated static func parsePercent(_ v: String?) -> Double {
        guard let m = TPText.match(#"^([\d.]+)%?$"#, (v ?? "").trimmed), let n = m[1] else { return 0 }
        let f = KubeResources.jsParseFloat(n)
        return f.isNaN ? 0 : f.rounded(.toNearestOrAwayFromZero)
    }

    /// One `top()` result as numbers — pure given that result.
    nonisolated static func snapshotFrom(_ top: JSON) -> JSON {
        let nodes: [JSON] = (top["nodes"]["ok"].truthy ? top["nodes"]["items"].items : []).map { n in
            ["name": n["name"], "cpuM": .number(parseCpu(n["cpu"].string)), "cpuPercent": .number(parsePercent(n["cpuPercent"].string)),
             "memBytes": .number(parseMemBytes(n["memory"].string)), "memPercent": .number(parsePercent(n["memoryPercent"].string))]
        }
        let pods: [JSON] = (top["pods"]["ok"].truthy ? top["pods"]["items"].items : []).map { p in
            ["namespace": p["namespace"], "name": p["name"], "cpuM": .number(parseCpu(p["cpu"].string)),
             "memBytes": .number(parseMemBytes(p["memory"].string))]
        }
        return ["at": .number(Double(nowMs())), "ok": .bool(top["nodes"]["ok"].truthy || top["pods"]["ok"].truthy),
                "nodes": .array(nodes), "pods": .array(pods)]
    }

    /// `kube:metricsStart`: a sample at once, then every `intervalMs`, failed
    /// polls included (`ok` says which), each as `{id, …snapshot}`.
    @discardableResult
    func start(_ spec: KubeSpec, id given: String? = nil, intervalMs: Double = 15000,
               onSample: @escaping @MainActor (JSON) -> Void) -> JSON {
        KubeServiceFeature.install()
        seq += 1
        let id = given ?? "metrics-\(seq)-\(Int64(nowMs()))"
        if id.isEmpty { return kubeFail("No id given.") }
        if running[id] != nil { return kubeFail("That metrics poll is already running.") }
        let interval = max(intervalMs, 1000) / 1000
        running[id] = Task { @MainActor in
            while !Task.isCancelled {
                // Ticks do not wait for one another, as setInterval did not.
                Task { @MainActor in
                    var snap = KubeMetrics.snapshotFrom(await KubeResources.top(spec))
                    guard KubeMetrics.shared.running[id] != nil else { return }
                    snap["id"] = .string(id)
                    onSample(snap)
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        return ["ok": true, "id": .string(id)]
    }

    /// `kube:metricsStop`.
    @discardableResult
    func stop(_ id: String) -> Bool {
        guard let t = running.removeValue(forKey: id) else { return false }
        t.cancel()
        return true
    }

    func stopAll() { for id in Array(running.keys) { stop(id) } }
}
