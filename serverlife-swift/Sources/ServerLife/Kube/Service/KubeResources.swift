import Foundation

/// kuberesources.js — KubeLife's full-cluster browser: every resource kind a
/// cluster actually has (`kubectl api-resources`), rows for each, YAML
/// diff/apply/validate, describe/delete/cordon/drain and `kubectl top`.
/// Access (can-i, who-can) is in KubeAccess.swift; heartbeats, provider
/// detection and the Cloud view in KubeHeartbeat.swift.
enum KubeResources {
    typealias Args = (bin: String, baseArgs: [String], env: [String: String?])

    /// `run()`: execFile (20 s default) + explainMissing.
    static func run(_ k: Args, _ args: [String], timeout: TimeInterval = 20) async -> KubeRun {
        await KubeBin.run(k.bin, k.baseArgs + args, env: k.env, timeout: timeout)
    }

    /// `runWithStdin()`: the same, text fed over stdin (nil is fed as "").
    static func runWithStdin(_ k: Args, _ args: [String], _ input: String?, timeout: TimeInterval = 20) async -> KubeRun {
        await KubeBin.run(k.bin, k.baseArgs + args, env: k.env, timeout: timeout, stdin: input ?? "")
    }

    /// `kubectlArgsFor(namespace ? {...spec, namespace} : spec)`.
    static func argsFor(_ spec: KubeSpec, namespace: String?) -> Args {
        Kube.kubectlArgsFor(spec.overriding(namespace: namespace))
    }

    /// `kubectlArgsFor({...spec, namespace: null})`.
    static func clusterArgs(_ spec: KubeSpec) -> Args { Kube.kubectlArgsFor(spec.with(namespace: nil)) }

    // MARK: - api-resources

    /// `kubectl api-resources -o wide`'s table, read by column position (an
    /// empty SHORTNAMES column would shift a whitespace split).
    static func parseApiResources(_ text: String?) -> [JSON] {
        let lines = (text ?? "").components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("NAME") }) else { return [] }
        let header = Array(lines[headerIdx].utf16)
        let cols = ["NAME", "SHORTNAMES", "APIVERSION", "NAMESPACED", "KIND", "VERBS", "CATEGORIES"]
        func indexOf(_ needle: String) -> Int? {
            let n = Array(needle.utf16)
            guard n.count <= header.count else { return nil }
            for i in 0...(header.count - n.count) where Array(header[i..<(i + n.count)]) == n { return i }
            return nil
        }
        let starts = cols.compactMap { c in indexOf(c).map { (c, $0) } }
        if starts.isEmpty { return [] }
        var out: [JSON] = []
        for line in lines[(headerIdx + 1)...] {
            if line.trimmed.isEmpty { continue }
            let u = Array(line.utf16)
            var row: [String: String] = [:]
            for (i, (c, start)) in starts.enumerated() {
                let end = i + 1 < starts.count ? starts[i + 1].1 : u.count
                let a = min(start, u.count), b = max(a, min(end, u.count))
                row[c] = String(decoding: u[a..<b], as: UTF16.self).trimmed
            }
            func list(_ k: String) -> JSON { JSON((row[k] ?? "").isEmpty ? [] : (row[k] ?? "").components(separatedBy: ",")) }
            out.append([
                "name": JSON(row["NAME"]), "shortNames": list("SHORTNAMES"), "apiVersion": JSON(row["APIVERSION"]),
                "namespaced": .bool(row["NAMESPACED"] == "true"), "kind": JSON(row["KIND"]),
                "verbs": list("VERBS"), "categories": list("CATEGORIES"),
            ])
        }
        return out
    }

    static let categoryByKind: [String: String] = [
        "Pod": "Workloads", "Deployment": "Workloads", "ReplicaSet": "Workloads", "StatefulSet": "Workloads",
        "DaemonSet": "Workloads", "Job": "Workloads", "CronJob": "Workloads", "ReplicationController": "Workloads",
        "ConfigMap": "Config", "Secret": "Config", "ResourceQuota": "Config", "LimitRange": "Config",
        "HorizontalPodAutoscaler": "Config", "PodDisruptionBudget": "Config",
        "Service": "Network", "Endpoints": "Network", "EndpointSlice": "Network", "Ingress": "Network",
        "IngressClass": "Network", "NetworkPolicy": "Network",
        "PersistentVolume": "Storage", "PersistentVolumeClaim": "Storage", "StorageClass": "Storage", "VolumeAttachment": "Storage",
        "ServiceAccount": "Access Control", "Role": "Access Control", "ClusterRole": "Access Control",
        "RoleBinding": "Access Control", "ClusterRoleBinding": "Access Control",
        "Node": "Cluster", "Namespace": "Cluster", "Event": "Cluster", "ComponentStatus": "Cluster", "Binding": "Cluster",
    ]

    /// Argo CD's own CRDs and Flux's `*.toolkit.fluxcd.io` groups — by apiGroup, never Kind name.
    static func isGitOpsGroup(_ group: String) -> Bool {
        group == "argoproj.io" || group.hasSuffix(".toolkit.fluxcd.io")
    }

    static func categorize(_ t: JSON) -> String {
        if let k = t["kind"].string, let b = categoryByKind[k] { return b }
        let group = t["apiVersion"].kStr.components(separatedBy: "/")[0]
        if !group.isEmpty && isGitOpsGroup(group) { return "GitOps" }
        return !group.isEmpty && group != "v1" ? "Custom Resources: \(group)" : "Custom Resources"
    }

    static func discoverResourceTypes(_ spec: KubeSpec) async -> JSON {
        let r = await run(Kube.kubectlArgsFor(spec), ["api-resources", "-o", "wide"], timeout: 20)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl api-resources failed"), ["types": []]) }
        let types = parseApiResources(r.stdout).map { t -> JSON in var t = t; t["category"] = .string(categorize(t)); return t }
        return kubeOk(["types": .array(types)])
    }

    // MARK: - Rows

    private static func n(_ j: JSON, _ fallback: Double = 0) -> String { kubeNumText(j.double ?? fallback) }

    /// "Actionable information" for each list row; "" for kinds without special knowledge.
    static func detailOf(_ kind: String?, _ i: JSON) -> String {
        let kind = kind ?? ""
        let status = i["status"], spec = i["spec"]
        switch kind {
        case "Pod":
            let cs = status["containerStatuses"].items
            let restarts = cs.reduce(0.0) { $0 + ($1["restartCount"].double ?? 0) }
            return "\(cs.filter { $0["ready"].truthy }.count)/\(cs.count) ready" + (restarts != 0 ? ", \(kubeNumText(restarts)) restarts" : "")
        case "Deployment", "StatefulSet", "ReplicaSet":
            let ready = status["readyReplicas"].double ?? 0
            let desired = spec["replicas"].double ?? status["replicas"].double ?? 0
            return "\(kubeNumText(ready))/\(kubeNumText(desired)) ready"
        case "DaemonSet":
            return "\(n(status["numberReady"]))/\(n(status["desiredNumberScheduled"])) ready"
        case "Node":
            let roles = i["metadata"]["labels"].entries.keys.sorted()
                .filter { $0.hasPrefix("node-role.kubernetes.io/") }
                .map { $0.components(separatedBy: "/")[1] }.joined(separator: ",")
            return "\(kubeOr(roles, "worker")) · \(status["nodeInfo"]["kubeletVersion"].kStr)"
        case "Service":
            return "\(kubeOr(spec["type"].string, "ClusterIP")) · \(spec["clusterIP"].kStr)"
        case "Job":
            return "\(n(status["succeeded"]))/\(n(spec["completions"], 1)) completed"
        case "CronJob":
            return "\(spec["schedule"].kStr)\(spec["suspend"].truthy ? " · suspended" : "")"
        case "Event":
            let obj = i["involvedObject"]
            let count = i["count"].double ?? 0
            let times = count > 1 ? " ×\(kubeNumText(count))" : ""
            return "\(obj["kind"].kStr)/\(obj["name"].kStr): \(i["reason"].kStr) — \(i["message"].kStr)\(times)"
        case "ResourceQuota":
            // Whatever resources this quota actually names — never a fixed list.
            let hard = status["hard"].entries, used = status["used"].entries
            let keys = Array(hard.keys.sorted().prefix(3))
            if keys.isEmpty { return "no limits set" }
            return keys.map { k in
                let u = used[k].flatMap { $0.isNull ? nil : $0.kStr } ?? "0"
                return "\(u)/\(hard[k]?.kStr ?? "") \(k)"
            }.joined(separator: " · ")
        case "LimitRange":
            let limits = spec["limits"].items
            guard let first = limits.first else { return "no limits defined" }
            let src = first["default"].object != nil ? first["default"] : first["defaultRequest"]
            let bits = src.kSortedEntries.prefix(2).map { "\($0.0) \($0.1.kStr)" }
            return "\(kubeOr(first["type"].string, "Container"))\(bits.isEmpty ? "" : ": " + bits.joined(separator: ", "))"
                + (limits.count > 1 ? " (+\(limits.count - 1) more)" : "")
        case "Role", "ClusterRole":
            let c = i["rules"].items.count
            return "\(c) rule\(c == 1 ? "" : "s")"
        case "RoleBinding", "ClusterRoleBinding":
            let ref = i["roleRef"]
            let c = i["subjects"].items.count
            return "\(ref["kind"].kStr)/\(ref["name"].kStr) → \(c) subject\(c == 1 ? "" : "s")"
        default: break
        }
        // GitOps CRDs: real status. Argo's Application is the one non-Ready-condition shape.
        if isGitOpsGroup(i["apiVersion"].kStr.components(separatedBy: "/")[0]) {
            if kind == "Application" {
                return "\(kubeOr(status["sync"]["status"].string, "Unknown")), \(kubeOr(status["health"]["status"].string, "Unknown"))"
            }
            guard let ready = status["conditions"].items.first(where: { $0["type"].string == "Ready" }) else { return "Unknown" }
            return ready["status"].string == "True" ? "Ready"
                : "Not ready: \(kubeOr(ready["reason"].string, kubeOr(ready["message"].string, "unknown reason")))"
        }
        return ""
    }

    /// A clean Ready/NotReady rather than every condition type joined.
    static func conditionStatus(_ i: JSON) -> String {
        let conds = i["status"]["conditions"].items
        if let ready = conds.first(where: { $0["type"].string == "Ready" }) {
            return ready["status"].string == "True" ? "Ready" : "NotReady"
        }
        return conds.map { $0["type"].kStr }.joined(separator: ",")
    }

    /// `matchLabels` as `k=v,k2=v2` — kubectl's own -l syntax.
    static func selectorString(_ matchLabels: JSON) -> String {
        matchLabels.kSortedEntries.map { "\($0.0)=\($0.1.kStr)" }.joined(separator: ",")
    }

    /// One full item into the row a table shows — pure. Watched objects go through this too.
    static func rowFrom(_ i: JSON) -> JSON {
        let kind = i["kind"].string
        let md = i["metadata"]
        var row: [String: JSON] = [
            "name": .string(md["name"].kStr),
            "namespace": .string(md["namespace"].kStr),
        ]
        if kind == "Event" {
            // lastTimestamp: when a recurring event most recently happened.
            let age = [i["lastTimestamp"], i["eventTime"], i["firstTimestamp"], md["creationTimestamp"]]
                .compactMap { $0.string?.nilIfEmpty }.first ?? ""
            row["age"] = .string(age)
            row["status"] = .string(i["type"].kStr)
        } else {
            row["age"] = .string(md["creationTimestamp"].kStr)
            row["status"] = .string(i["status"]["phase"].string?.nilIfEmpty ?? conditionStatus(i))
        }
        row["detail"] = .string(detailOf(kind, i))
        if kind == "Pod" {
            row["containers"] = JSON(i["spec"]["containers"].items.map { $0["name"].kStr })
            if let w = i["status"]["containerStatuses"].items.compactMap({ $0["state"]["waiting"]["reason"].string?.nilIfEmpty }).first {
                row["waitingReason"] = .string(w)
            }
        }
        let workloads = ["Deployment", "ReplicaSet", "StatefulSet", "DaemonSet"]
        if let k = kind, workloads.contains(k) {
            let ml = i["spec"]["selector"]["matchLabels"]
            row["selector"] = .string(selectorString(ml))
            row["selectorLabels"] = ml.object.map { .object($0) } ?? [:]
        } else if kind == "Service" {
            let sel = i["spec"]["selector"]
            if let s = selectorString(sel).nilIfEmpty { row["selector"] = .string(s) }
            row["selectorLabels"] = sel.object.map { .object($0) } ?? [:]
        }
        if kind == "CronJob" { row["suspended"] = .bool(i["spec"]["suspend"].truthy) }
        if kind == "Deployment" || kind == "StatefulSet" {
            row["desiredReplicas"] = .number(i["spec"]["replicas"].double ?? 1)
            row["readyReplicas"] = .number(i["status"]["readyReplicas"].double ?? 0)
        }
        return .object(row)
    }

    /// One kind's rows — `kubectl get <kind> [-n ns|-A] -o json`, plus CRD
    /// printer columns, newest-first events and metrics-server cpu/mem.
    static func getResources(_ spec: KubeSpec, name: String, namespaced: Bool = false, namespace: String? = nil,
                             selector: String? = nil, fieldSelector: String? = nil, apiVersion: String? = nil) async -> JSON {
        let k = Kube.kubectlArgsFor(spec.scoped(namespace: namespace))
        let scope = !namespaced ? [] : (namespace?.isEmpty == false ? [] : ["-A"])
        let sel = selector.flatMap { $0.isEmpty ? nil : ["-l", $0] } ?? []
        let fsel = fieldSelector.flatMap { $0.isEmpty ? nil : ["--field-selector", $0] } ?? []
        let r = await run(k, ["get", name] + scope + sel + fsel + ["-o", "json"], timeout: 20)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl get \(name) failed"), ["items": []]) }
        guard let data = try? JSON.parse(r.stdout) else { return kubeFail("Unexpected output from kubectl", ["items": []]) }
        let list = data["items"].array ?? (data["metadata"].isNull ? [] : [data])
        var items = list.map(rowFrom)
        // A CRD's own additionalPrinterColumns — only for a kind known to be custom.
        if let apiVersion, !apiVersion.isEmpty {
            let cols = await crdColumnsFor(spec, resourceTypeName: name, apiVersion: apiVersion)
            if !cols.isEmpty {
                for idx in list.indices {
                    items[idx]["crdColumns"] = .array(cols.map { c in
                        ["label": c["label"], "type": c["type"], "value": JSONPathLite.resolve(list[idx], c["jsonPath"].string) ?? .null]
                    })
                }
            }
        }
        // Most-recent-first, as every event feed does.
        if list.first?["kind"].string == "Event" {
            func t(_ j: JSON) -> Double { kubeParseDate(j["age"].string?.nilIfEmpty) ?? .nan }
            items = stableSorted(items) { a, b in
                let d = t(b) - t(a)
                return !d.isNaN && d < 0
            }
        }
        // Best-effort: metrics-server is an add-on; the list stands without it.
        if name == "pods" || name == "nodes" {
            let top = name == "pods" ? await topPods(spec, namespace: namespace) : await topNodes(spec)
            if top["ok"].truthy {
                func key(_ it: JSON) -> String { name == "pods" ? "\(it["namespace"].kStr)\u{1}\(it["name"].kStr)" : it["name"].kStr }
                var byKey: [String: JSON] = [:]
                for t in top["items"].items { byKey[key(t)] = t }
                for idx in items.indices {
                    guard let t = byKey[key(items[idx])] else { continue }
                    let d = items[idx]["detail"].kStr
                    items[idx]["detail"] = .string((d.isEmpty ? "" : d + " · ") + "cpu \(t["cpu"].kStr) · mem \(t["memory"].kStr)")
                }
            }
        }
        return kubeOk(["items": .array(items)])
    }

    /// Array.prototype.sort is stable; so is this. `less(a, b)` = a before b.
    static func stableSorted<T>(_ a: [T], _ less: (T, T) -> Bool) -> [T] {
        a.enumerated().sorted { x, y in
            if less(x.element, y.element) { return true }
            if less(y.element, x.element) { return false }
            return x.offset < y.offset
        }.map(\.element)
    }

    // MARK: - CRD printer columns

    private static let crdLock = NSLock()
    nonisolated(unsafe) private static var crdColumnsCache: [String: [JSON]] = [:]

    /// The matching version's additionalPrinterColumns out of a parsed CRD — pure.
    static func columnsFromCrdObject(_ crd: JSON, _ version: String?) -> [JSON] {
        let versions = crd["spec"]["versions"].items
        let v = versions.first { $0["name"].string == version } ?? versions.first
        return (v?["additionalPrinterColumns"].items ?? []).map { c in
            ["label": c["name"], "jsonPath": c["jsonPath"], "type": c["type"]]
        }
    }

    /// Cached per context and CRD: a schema does not change between renders.
    static func crdColumnsFor(_ spec: KubeSpec, resourceTypeName: String?, apiVersion: String?) async -> [JSON] {
        let av = apiVersion ?? ""
        let group = av.contains("/") ? av.components(separatedBy: "/")[0] : ""
        let version = av.contains("/") ? av.components(separatedBy: "/")[1] : av
        guard !group.isEmpty, let rtn = resourceTypeName, !rtn.isEmpty else { return [] }
        let crdName = "\(rtn).\(group)"
        let cacheKey = "\(spec.contextName ?? "")\u{1}\(crdName)"
        crdLock.lock()
        let cached = crdColumnsCache[cacheKey]
        crdLock.unlock()
        if let cached { return cached }
        let r = await run(clusterArgs(spec), ["get", "crd", crdName, "-o", "json"], timeout: 15)
        var cols: [JSON] = []
        if r.ok, let crd = try? JSON.parse(r.stdout) { cols = columnsFromCrdObject(crd, version) }
        crdLock.lock(); crdColumnsCache[cacheKey] = cols; crdLock.unlock()
        return cols
    }

    // MARK: - One object

    /// The full object plus where it leads (`{ok, object, related}`).
    static func getObject(_ spec: KubeSpec, name: String, resource: String, namespace: String? = nil) async -> JSON {
        let r = await run(argsFor(spec, namespace: namespace), ["get", resource, name, "-o", "json"], timeout: 20)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl get failed")) }
        guard let object = try? JSON.parse(r.stdout) else { return kubeFail("Unexpected output from kubectl") }
        return kubeOk(["object": object, "related": KubeRelations.relatedOf(object)])
    }

    static func getYaml(_ spec: KubeSpec, name: String, resource: String, namespace: String? = nil) async -> JSON {
        let r = await run(argsFor(spec, namespace: namespace), ["get", resource, name, "-o", "yaml"], timeout: 20)
        return r.ok ? kubeOk(["yaml": .string(r.stdout)]) : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl get -o yaml failed"))
    }

    // MARK: - top

    static func columns(_ line: String) -> [String] {
        line.trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func col(_ c: [String], _ i: Int) -> JSON { i < c.count ? .string(c[i]) : .null }

    private static func lines(_ s: String) -> [String] { kubePlain(s).components(separatedBy: "\n").filter { !$0.isEmpty } }

    /// `kubectl top pods`; the columns shift with -A, so each form is parsed on its own.
    static func topPods(_ spec: KubeSpec, namespace: String? = nil) async -> JSON {
        let ns = namespace?.nilIfEmpty
        let r = await run(Kube.kubectlArgsFor(spec.with(namespace: ns)), ["top", "pods"] + (ns == nil ? ["-A"] : []) + ["--no-headers"], timeout: 15)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl top pods failed (metrics-server may not be installed)"), ["items": []]) }
        let items: [JSON] = lines(r.stdout).map { line in
            let c = columns(line)
            if let ns { return ["namespace": .string(ns), "name": col(c, 0), "cpu": col(c, 1), "memory": col(c, 2)] }
            return ["namespace": col(c, 0), "name": col(c, 1), "cpu": col(c, 2), "memory": col(c, 3)]
        }
        return kubeOk(["items": .array(items)])
    }

    static func topNodes(_ spec: KubeSpec) async -> JSON {
        let r = await run(clusterArgs(spec), ["top", "nodes", "--no-headers"], timeout: 15)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl top nodes failed (metrics-server may not be installed)"), ["items": []]) }
        let items: [JSON] = lines(r.stdout).map { line in
            let c = columns(line)
            return ["name": col(c, 0), "cpu": col(c, 1), "cpuPercent": col(c, 2), "memory": col(c, 3), "memoryPercent": col(c, 4)]
        }
        return kubeOk(["items": .array(items)])
    }

    static func topPodContainers(_ spec: KubeSpec, name: String, namespace: String? = nil) async -> JSON {
        let r = await run(argsFor(spec, namespace: namespace), ["top", "pod", name, "--containers", "--no-headers"], timeout: 15)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl top pod --containers failed (metrics-server may not be installed)"), ["items": []]) }
        let items: [JSON] = lines(r.stdout).map { line in
            let c = columns(line)   // POD NAME CPU MEMORY
            return ["container": col(c, 1), "cpu": col(c, 2), "memory": col(c, 3)]
        }
        return kubeOk(["items": .array(items)])
    }

    /// `parseFloat`: the longest numeric prefix, NaN if none.
    static func jsParseFloat(_ s: String) -> Double {
        if let m = TPText.match(#"^\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)"#, s), let v = m[1], let d = Double(v) { return d }
        return .nan
    }

    /// `kubectl top` for the overview: nodes, and pods busiest first.
    static func top(_ spec: KubeSpec, namespace: String? = nil) async -> JSON {
        async let nodesR = topNodes(spec)
        async let podsR = topPods(spec, namespace: namespace)
        let nodes = await nodesR
        var pods = await podsR
        func milli(_ v: JSON) -> Double {
            let s = v.string ?? ""
            let x = s.hasSuffix("m") ? jsParseFloat(s) : jsParseFloat(s.isEmpty ? "0" : s) * 1000
            return x.isNaN ? 0 : x
        }
        if pods["ok"].truthy {
            pods["items"] = .array(stableSorted(pods["items"].items) { milli($0["cpu"]) > milli($1["cpu"]) })
        }
        return ["ok": .bool(nodes["ok"].truthy || pods["ok"].truthy), "nodes": nodes, "pods": pods]
    }

    // MARK: - Editing

    /// `kubectl diff -f -`; exit 1 means "there is a difference", not a failure.
    /// The manifest's own namespace governs, so the spec's is dropped.
    static func diffYaml(_ spec: KubeSpec, yaml: String?) async -> JSON {
        let r = await runWithStdin(clusterArgs(spec), ["diff", "-f", "-"], yaml, timeout: 20)
        if !r.ok && r.code != 1 { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl diff failed")) }
        return kubeOk(["diff": .string(kubeOr(kubePlain(r.stdout), "(no changes)"))])
    }

    /// `kubectl apply -f -` — only after diffYaml's result was shown and confirmed.
    static func applyYaml(_ spec: KubeSpec, yaml: String?) async -> JSON {
        let r = await runWithStdin(clusterArgs(spec), ["apply", "-f", "-"], yaml, timeout: 30)
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))]) : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl apply failed"))
    }

    /// A server-side dry-run apply: would the API server accept it at all.
    static func validateYaml(_ spec: KubeSpec, yaml: String?) async -> JSON {
        let r = await runWithStdin(clusterArgs(spec), ["apply", "--dry-run=server", "-f", "-"], yaml, timeout: 20)
        return r.ok ? kubeOk() : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl could not validate this"))
    }

    static func describe(_ spec: KubeSpec, name: String, resource: String, namespace: String? = nil) async -> JSON {
        let r = await run(argsFor(spec, namespace: namespace), ["describe", resource, name], timeout: 20)
        return r.ok ? kubeOk(["text": .string(r.stdout)]) : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl describe failed"))
    }

    static func deleteResource(_ spec: KubeSpec, name: String, resource: String, namespace: String? = nil) async -> JSON {
        let r = await run(argsFor(spec, namespace: namespace), ["delete", resource, name], timeout: 30)
        return r.ok ? kubeOk() : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl delete failed"))
    }

    static func cordonNode(_ spec: KubeSpec, name: String, uncordon: Bool = false) async -> JSON {
        let r = await run(clusterArgs(spec), [uncordon ? "uncordon" : "cordon", name], timeout: 20)
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))])
            : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl \(uncordon ? "un" : "")cordon failed"))
    }

    /// `kubectl drain` with `--ignore-daemonsets --delete-emptydir-data` (without
    /// them a DaemonSet or emptyDir pod blocks the drain forever).
    static func drainNode(_ spec: KubeSpec, name: String, force: Bool = false, timeoutSeconds: Int = 120) async -> JSON {
        var args = ["drain", name, "--ignore-daemonsets", "--delete-emptydir-data", "--timeout=\(timeoutSeconds)s"]
        if force { args.append("--force") }
        let r = await run(clusterArgs(spec), args, timeout: TimeInterval(timeoutSeconds + 30))
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))]) : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl drain failed"))
    }

    /// A merge patch's `stringData` — the API server does the base64.
    static func patchSecretStringData(_ spec: KubeSpec, name: String?, namespace: String? = nil, stringData: [String: String]?) async -> JSON {
        guard let name, !name.isEmpty else { return kubeFail("No secret given.") }
        guard let stringData, !stringData.isEmpty else { return kubeFail("Nothing changed.") }
        let patch = JSON.object(["stringData": .object(stringData.mapValues { .string($0) })]).text()
        let r = await run(argsFor(spec, namespace: namespace), ["patch", "secret", name, "--type=merge", "--patch=" + patch], timeout: 20)
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))]) : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl patch failed"))
    }

    /// A kind's full, untrimmed list (Roles/Bindings need their real rules).
    static func getRawList(_ spec: KubeSpec, name: String, namespaced: Bool = false, namespace: String? = nil) async -> JSON {
        let k = Kube.kubectlArgsFor(spec.scoped(namespace: namespace))
        let scope = !namespaced ? [] : (namespace?.isEmpty == false ? [] : ["-A"])
        let r = await run(k, ["get", name] + scope + ["-o", "json"], timeout: 20)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl get \(name) failed"), ["items": []]) }
        guard let data = try? JSON.parse(r.stdout) else { return kubeFail("Unexpected output from kubectl", ["items": []]) }
        return kubeOk(["items": .array(data["items"].array ?? (data["metadata"].isNull ? [] : [data]))])
    }
}
