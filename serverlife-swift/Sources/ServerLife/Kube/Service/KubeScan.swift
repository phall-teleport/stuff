import Foundation

/// kubescan.js — pods/deployments/services reshaped into the 3D scene's data
/// (the kube3d counterpart to cityscan). Pure: the inputs are `Kube.listPods`
/// pods and `KubeResources.getResources` rows.
enum KubeScan {
    /// Rough footprint, for the tower's floor count.
    static func footprintOf(_ pod: JSON) -> Double {
        let t = pod["total"].double ?? 0
        let n = t != 0 ? t : (pod["containers"].array.map { Double($0.count) } ?? 0)
        return max(1, n != 0 ? n : 1)
    }

    static let phaseWeight: [String: Double] = ["Running": 3, "Pending": 1, "Succeeded": 1, "Unknown": 1]
    static func heightOf(_ pod: JSON) -> Double {
        let base = phaseWeight[pod["phase"].string ?? ""] ?? 2
        return base + footprintOf(pod) + min(pod["restarts"].double ?? 0, 10) * 0.3
    }

    /// "3/3 ready" (the detail of a workload row) → `(ready, desired)`; anything else 0/0.
    static func readyRatioOf(_ detail: String?) -> (ready: Double, desired: Double) {
        guard let m = TPText.match(#"^(\d+)\/(\d+) ready"#, detail ?? "") else { return (0, 0) }
        return (Double(m[1] ?? "") ?? 0, Double(m[2] ?? "") ?? 0)
    }

    /// Every key must match; an empty selector picks nothing.
    static func selects(_ selector: JSON, _ labels: JSON) -> Bool {
        let e = selector.kSortedEntries
        return !e.isEmpty && e.allSatisfy { labels[$0.0] == $0.1 }
    }

    /// Service → Deployment, Deployment → Pod, Service → Pod (no owning Deployment).
    static func linksOf(pods: [JSON], deployments: [JSON], services: [JSON]) -> [JSON] {
        var links: [JSON] = []
        var ownerOf: [String: String] = [:]
        for d in deployments {
            for p in pods {
                let pn = p["name"].stringish ?? "undefined"
                if ownerOf[pn] == nil && selects(d["selectorLabels"], p["labels"]) {
                    ownerOf[pn] = d["name"].stringish ?? "undefined"
                    links.append(["from": .string("Deployment/\(d["name"].stringish ?? "undefined")"), "to": .string("Pod/\(pn)")])
                }
            }
        }
        for s in services {
            var via = Set<String>()
            let sn = s["name"].stringish ?? "undefined"
            for p in pods where selects(s["selectorLabels"], p["labels"]) {
                let pn = p["name"].stringish ?? "undefined"
                if let o = ownerOf[pn] { via.insert(o) } else { links.append(["from": .string("Service/\(sn)"), "to": .string("Pod/\(pn)")]) }
            }
            for d in via.sorted() { links.append(["from": .string("Service/\(sn)"), "to": .string("Deployment/\(d)")]) }
        }
        return links
    }

    /// `{namespaces:[{name, pods, deployments, services, podCount, links}], podCount}`.
    static func buildScene(pods: [JSON] = [], deployments: [JSON] = [], services: [JSON] = []) -> JSON {
        struct Entry { var pods: [JSON] = [], deps: [JSON] = [], svcs: [JSON] = [], rawP: [JSON] = [], rawD: [JSON] = [], rawS: [JSON] = [] }
        var by: [String: Entry] = [:]
        func ns(_ j: JSON) -> String { j["namespace"].stringish?.nilIfEmpty ?? "default" }
        for p in pods {
            by[ns(p), default: Entry()].rawP.append(p)
            by[ns(p)]!.pods.append(["name": p["name"], "phase": .string(p["phase"].stringish?.nilIfEmpty ?? "Unknown"),
                                     "restarts": .number(p["restarts"].double ?? 0), "footprint": .number(footprintOf(p)),
                                     "height": .number(heightOf(p)), "node": .string(p["node"].stringish ?? ""),
                                     "containers": p["containers"].truthy ? p["containers"] : []])
        }
        for d in deployments {
            let r = readyRatioOf(d["detail"].string)
            by[ns(d), default: Entry()].rawD.append(d)
            by[ns(d)]!.deps.append(["name": d["name"], "ready": .number(r.ready), "desired": .number(r.desired)])
        }
        for s in services {
            by[ns(s), default: Entry()].rawS.append(s)
            by[ns(s)]!.svcs.append(["name": s["name"], "detail": .string(s["detail"].stringish ?? "")])
        }
        let byName = { (a: JSON, b: JSON) in (a["name"].stringish ?? "").localizedCompare(b["name"].stringish ?? "") == .orderedAscending }
        let namespaces: [JSON] = by.keys.sorted { $0.localizedCompare($1) == .orderedAscending }.map { name in
            let e = by[name]!
            return ["name": .string(name), "pods": .array(e.pods.sorted(by: byName)), "deployments": .array(e.deps.sorted(by: byName)),
                    "services": .array(e.svcs.sorted(by: byName)), "podCount": .number(Double(e.pods.count)),
                    "links": .array(linksOf(pods: e.rawP, deployments: e.rawD, services: e.rawS))]
        }
        return ["namespaces": .array(namespaces), "podCount": .number(Double(pods.count))]
    }
}

/// kubelint.js — a Popeye scan. Popeye exits non-zero whenever it found
/// anything (it is meant for CI gating), so success is "stdout parsed as JSON".
enum KubeLint {
    /// Popeye's argv — pure, so the shape is testable.
    static func buildArgs(_ spec: KubeSpec?, namespace: String? = nil, logFile: String) -> [String] {
        (spec?.contextName?.nilIfEmpty.map { ["--context", $0] } ?? [])
            + (namespace?.nilIfEmpty.map { ["-n", $0] } ?? ["-A"])
            + ["-o", "json", "--logs", logFile]
    }

    /// → `{ok, report}` (Popeye's own `popeye` object) or `{ok:false, error}`.
    static func scan(_ spec: KubeSpec, namespace: String? = nil) async -> JSON {
        if !KubeBin.kubectlAvailable() {
            return kubeFail("Popeye needs a working kubectl on this machine to read your kubeconfig directly — install kubectl to enable cluster scans.")
        }
        let bin = KubeBin.findTool("popeye")
        if !KubeBin.toolAvailable("popeye") {
            return kubeFail("Popeye is not installed. Get it from https://github.com/derailed/popeye and it will be picked up automatically.")
        }
        let env = Kube.kubeconfigEnvFor(spec)
        let logFile = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("serverlife-popeye-\(Int64(nowMs()))-\(UUID().uuidString.prefix(10).lowercased()).log")
        let r = await Proc.run(bin, buildArgs(spec, namespace: namespace, logFile: logFile), env: env, timeout: 120)
        // A log file is harmless clutter once read.
        try? FileManager.default.removeItem(atPath: logFile)
        guard let data = try? JSON.parse(r.out) else { return kubeFail(kubeOr(kubePlain(r.err), "Could not read Popeye's own output.")) }
        return kubeOk(["report": data["popeye"]])
    }
}
