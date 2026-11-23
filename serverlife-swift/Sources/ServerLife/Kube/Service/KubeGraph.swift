import Foundation

/// kubegraph.js — a set of manifests as a graph (what a Helm release installs
/// and how the pieces point at each other) and that graph as Mermaid. Pure.
/// The edges are the references Kubernetes itself follows, read from the
/// fields that make them, not guessed from names.
enum KubeGraph {
    static let workloads = ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod"]

    struct Node: Equatable { var id, kind, name, namespace, detail: String; var rank = 6 }
    struct Edge: Equatable { var from, to, label: String }
    struct Graph { var nodes: [Node]; var edges: [Edge]; var external: [String] }

    /// Every document with a kind and a name; a List is its items. (js-yaml's
    /// loadAll parses the whole stream first, so text that will not parse gives none.)
    static func parseManifests(_ text: String?) -> [JSON] {
        let docs = (try? KubeYAML.loadAll(text ?? "")) ?? []
        let named = { (d: JSON) in d["kind"].truthy && d["metadata"]["name"].truthy }
        return docs.filter(named).flatMap { d in d["kind"].string == "List" ? d["items"].items : [d] }.filter(named)
    }

    /// The pod spec and pod labels of anything that runs pods.
    static func podTemplateOf(_ d: JSON) -> (spec: JSON, labels: JSON) {
        if d["kind"].string == "Pod" { return (d["spec"], d["metadata"]["labels"]) }
        let t = d["kind"].string == "CronJob" ? d["spec"]["jobTemplate"]["spec"]["template"] : d["spec"]["template"]
        return (t["spec"], t["metadata"]["labels"])
    }

    static func matchLabelsOf(_ selector: JSON) -> JSON {
        guard selector.truthy else { return [:] }
        if selector["matchLabels"].truthy { return selector["matchLabels"] }
        return selector["matchExpressions"].truthy ? [:] : selector
    }

    static func selects(_ selector: JSON, _ labels: JSON) -> Bool {
        let e = selector.kSortedEntries
        if e.isEmpty { return false }
        return e.allSatisfy { k, v in labels[k] == v }
    }

    static func idOf(_ kind: String, _ name: String) -> String { "\(kind)/\(name)" }

    private static func s(_ j: JSON) -> String? { j.stringish?.nilIfEmpty }

    /// One short line of what matters about a resource.
    static func detailOf(_ d: JSON) -> String {
        let spec = d["spec"], kind = d["kind"].string ?? ""
        func images(_ pod: JSON) -> String {
            var seen: [String] = []
            for c in pod["initContainers"].items + pod["containers"].items {
                let i = (c["image"].stringish ?? "").components(separatedBy: "/").last ?? ""
                if !i.isEmpty && !seen.contains(i) { seen.append(i) }
            }
            return seen.joined(separator: ", ")
        }
        switch kind {
        case "Deployment", "StatefulSet", "ReplicaSet":
            let r = spec.object?["replicas"].map { "\($0.stringish ?? "null")×" }
            return [r, images(podTemplateOf(d).spec).nilIfEmpty].compactMap { $0 }.joined(separator: " ")
        case "DaemonSet", "Job", "Pod": return images(podTemplateOf(d).spec)
        case "CronJob": return [s(spec["schedule"]), images(podTemplateOf(d).spec).nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
        case "Service":
            let ports = spec["ports"].items.map { p -> String in
                p["targetPort"].truthy && p["targetPort"] != p["port"]
                    ? "\(p["port"].stringish ?? "undefined")→\(p["targetPort"].stringish ?? "")" : (p["port"].stringish ?? "undefined")
            }.joined(separator: ",")
            let t = spec["clusterIP"].string == "None" ? "headless" : (s(spec["type"]) ?? "ClusterIP")
            return [t, ports.nilIfEmpty].compactMap { $0 }.joined(separator: " ")
        case "Ingress":
            return spec["rules"].items.compactMap { s($0["host"]) }.joined(separator: ", ").nilIfEmpty ?? (spec["ingressClassName"].stringish ?? "")
        case "PersistentVolumeClaim":
            return [s(spec["resources"]["requests"]["storage"]), s(spec["storageClassName"])].compactMap { $0 }.joined(separator: " · ")
        case "HorizontalPodAutoscaler":
            let mn = spec["minReplicas"].isNull ? "1" : (spec["minReplicas"].stringish ?? "1")
            let mx = spec["maxReplicas"].isNull ? "?" : (spec["maxReplicas"].stringish ?? "?")
            return "\(mn)–\(mx) replicas"
        case "ConfigMap", "Secret":
            let keys = Set((d["data"].object ?? [:]).keys).union((d["stringData"].object ?? [:]).keys)
            return keys.isEmpty ? (d["type"].stringish ?? "") : "\(keys.count) key\(keys.count == 1 ? "" : "s")"
        default: return ""
        }
    }

    /// `{nodes, edges, external}`. An edge is kept only when both ends are in
    /// the manifests; a reference to something else is listed in `external`.
    static func buildGraph(_ docs: [JSON]) -> Graph {
        var nodes: [Node] = [], have = Set<String>()
        func addNode(_ n: Node) { if have.insert(n.id).inserted { nodes.append(n) } }
        for d in docs {
            let k = d["kind"].string ?? "", n = d["metadata"]["name"].stringish ?? ""
            addNode(Node(id: idOf(k, n), kind: k, name: n, namespace: d["metadata"]["namespace"].stringish ?? "", detail: detailOf(d)))
        }
        // A StatefulSet's volumeClaimTemplates: one node each, named the way its claims are.
        for d in docs where d["kind"].string == "StatefulSet" {
            for t in d["spec"]["volumeClaimTemplates"].items {
                let name = "\(t["metadata"]["name"].stringish ?? "undefined")-\(d["metadata"]["name"].stringish ?? "")-*"
                addNode(Node(id: idOf("PersistentVolumeClaim", name), kind: "PersistentVolumeClaim", name: name,
                             namespace: d["metadata"]["namespace"].stringish ?? "",
                             detail: ["per replica", s(t["spec"]["resources"]["requests"]["storage"]), s(t["spec"]["storageClassName"])]
                                .compactMap { $0 }.joined(separator: " · ")))
            }
        }
        var edges: [Edge] = [], external = Set<String>(), seen = Set<String>()
        func add(_ from: String, _ toKind: String?, _ toName: JSON, _ label: String) {
            guard let name = toName.stringish?.nilIfEmpty else { return }
            let to = idOf(toKind ?? "undefined", name)
            if !have.contains(to) { external.insert(to); return }
            if seen.insert("\(from)>\(to)>\(label)").inserted { edges.append(Edge(from: from, to: to, label: label)) }
        }
        func refKind(_ ref: JSON, _ fallback: String) -> String { s(ref["kind"]) ?? fallback }
        let wls = docs.filter { workloads.contains($0["kind"].string ?? "") }

        for d in docs {
            let kind = d["kind"].string ?? ""
            let me = idOf(kind, d["metadata"]["name"].stringish ?? ""), spec = d["spec"]
            if kind == "Ingress" {
                let backends = [spec["defaultBackend"], spec["backend"]] + spec["rules"].items.flatMap { $0["http"]["paths"].items.map { $0["backend"] } }
                for b in backends { add(me, "Service", b["service"]["name"].truthy ? b["service"]["name"] : b["serviceName"], "routes") }
                for t in spec["tls"].items { add(me, "Secret", t["secretName"], "TLS") }
            }
            // Gateway API: a route sends to Services and hangs off a Gateway.
            if ["HTTPRoute", "GRPCRoute", "TCPRoute", "TLSRoute", "UDPRoute"].contains(kind) {
                for r in spec["rules"].items { for b in r["backendRefs"].items { add(me, refKind(b, "Service"), b["name"], "routes") } }
                for ref in spec["parentRefs"].items { add(me, refKind(ref, "Gateway"), ref["name"], "attached to") }
            }
            if kind == "Gateway" {
                for l in spec["listeners"].items { for c in l["tls"]["certificateRefs"].items { add(me, refKind(c, "Secret"), c["name"], "TLS") } }
            }
            // Things the API server itself calls: admission webhooks, aggregated APIs.
            if kind == "MutatingWebhookConfiguration" || kind == "ValidatingWebhookConfiguration" {
                for w in d["webhooks"].items { add(me, "Service", w["clientConfig"]["service"]["name"], "calls") }
            }
            if kind == "APIService" { add(me, "Service", spec["service"]["name"], "serves") }
            // Prometheus Operator: what gets scraped.
            if kind == "ServiceMonitor" {
                let sel = matchLabelsOf(spec["selector"])
                for svc in docs where svc["kind"].string == "Service" && selects(sel, svc["metadata"]["labels"]) {
                    add(me, "Service", svc["metadata"]["name"], "scrapes")
                }
            }
            if kind == "PodMonitor" {
                let sel = matchLabelsOf(spec["selector"])
                for w in wls where selects(sel, podTemplateOf(w).labels) { add(me, w["kind"].string, w["metadata"]["name"], "scrapes") }
            }
            // cert-manager: a Certificate writes its Secret, from an Issuer.
            if kind == "Certificate" {
                add(me, "Secret", spec["secretName"], "writes")
                add(me, s(spec["issuerRef"]["kind"]) ?? "Issuer", spec["issuerRef"]["name"], "issued by")
            }
            // KEDA, the same shape as an HPA.
            if kind == "ScaledObject" { add(me, s(spec["scaleTargetRef"]["kind"]) ?? "Deployment", spec["scaleTargetRef"]["name"], "scales") }
            if kind == "PersistentVolumeClaim" { add(me, "StorageClass", spec["storageClassName"], "class") }
            if kind == "Service" {
                for w in wls where selects(spec["selector"], podTemplateOf(w).labels) { add(me, w["kind"].string, w["metadata"]["name"], "selects") }
            }
            if workloads.contains(kind) {
                let pod = podTemplateOf(d).spec
                for v in pod["volumes"].items {
                    if v["configMap"].truthy { add(me, "ConfigMap", v["configMap"]["name"], "mounts") }
                    if v["secret"].truthy { add(me, "Secret", v["secret"]["secretName"], "mounts") }
                    if v["persistentVolumeClaim"].truthy { add(me, "PersistentVolumeClaim", v["persistentVolumeClaim"]["claimName"], "mounts") }
                    for src in v["projected"]["sources"].items {
                        if src["configMap"].truthy { add(me, "ConfigMap", src["configMap"]["name"], "mounts") }
                        if src["secret"].truthy { add(me, "Secret", src["secret"]["name"], "mounts") }
                    }
                }
                for c in pod["containers"].items + pod["initContainers"].items {
                    for e in c["env"].items {
                        add(me, "ConfigMap", e["valueFrom"]["configMapKeyRef"]["name"], "env")
                        add(me, "Secret", e["valueFrom"]["secretKeyRef"]["name"], "env")
                    }
                    for e in c["envFrom"].items {
                        add(me, "ConfigMap", e["configMapRef"]["name"], "env")
                        add(me, "Secret", e["secretRef"]["name"], "env")
                    }
                }
                add(me, "ServiceAccount", pod["serviceAccountName"].truthy ? pod["serviceAccountName"] : pod["serviceAccount"], "runs as")
                for s2 in pod["imagePullSecrets"].items { add(me, "Secret", s2["name"], "pulls with") }
                if kind == "StatefulSet" {
                    add(me, "Service", spec["serviceName"], "governed by")
                    for t in spec["volumeClaimTemplates"].items {
                        let claim = "\(t["metadata"]["name"].stringish ?? "undefined")-\(d["metadata"]["name"].stringish ?? "")-*"
                        add(me, "PersistentVolumeClaim", .string(claim), "claims")
                        add(idOf("PersistentVolumeClaim", claim), "StorageClass", t["spec"]["storageClassName"], "class")
                    }
                }
            }
            if kind == "RoleBinding" || kind == "ClusterRoleBinding" {
                add(me, s(d["roleRef"]["kind"]) ?? "Role", d["roleRef"]["name"], "grants")
                for sub in d["subjects"].items where sub["kind"].string == "ServiceAccount" { add(me, "ServiceAccount", sub["name"], "to") }
            }
            if kind == "HorizontalPodAutoscaler" { add(me, spec["scaleTargetRef"]["kind"].stringish, spec["scaleTargetRef"]["name"], "scales") }
            if kind == "PodDisruptionBudget" || kind == "NetworkPolicy" {
                let sel = matchLabelsOf(kind == "NetworkPolicy" ? spec["podSelector"] : spec["selector"])
                for w in wls where selects(sel, podTemplateOf(w).labels) {
                    add(me, w["kind"].string, w["metadata"]["name"], kind == "NetworkPolicy" ? "guards" : "protects")
                }
            }
        }
        return Graph(nodes: nodes, edges: edges, external: external.sorted())
    }

    /// Left to right, the way traffic and dependency read.
    static let ranks: [String: Int] = [
        "Gateway": 0, "Ingress": 0, "HTTPRoute": 0, "GRPCRoute": 0, "TCPRoute": 0, "TLSRoute": 0, "UDPRoute": 0,
        "HorizontalPodAutoscaler": 0, "ScaledObject": 0, "NetworkPolicy": 0, "PodDisruptionBudget": 0,
        "ServiceMonitor": 0, "PodMonitor": 0, "MutatingWebhookConfiguration": 0, "ValidatingWebhookConfiguration": 0, "APIService": 0,
        "Service": 1,
        "Deployment": 2, "StatefulSet": 2, "DaemonSet": 2, "ReplicaSet": 2, "Job": 2, "CronJob": 2, "Pod": 2,
        "ConfigMap": 3, "Secret": 3, "PersistentVolumeClaim": 3, "ServiceAccount": 3, "Certificate": 3,
        "StorageClass": 4, "Issuer": 4, "ClusterIssuer": 4, "RoleBinding": 4, "ClusterRoleBinding": 4,
        "Role": 5, "ClusterRole": 5,
    ]
    static func rankOf(_ kind: String) -> Int { ranks[kind] ?? 6 }

    /// Mermaid ids are letters, digits and underscores; names are not.
    static func mermaidId(_ id: String) -> String { "n_" + id.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression) }
    static func mermaidText(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "#quot;") }

    static let mermaidClass: [String: String] = [
        "Ingress": "fill:#3b2f5c,stroke:#a371f7,color:#fff",
        "Service": "fill:#123b4a,stroke:#4fd1ff,color:#fff",
        "workload": "fill:#16351f,stroke:#3fb950,color:#fff",
        "config": "fill:#3a2f12,stroke:#d29922,color:#fff",
        "rbac": "fill:#3a1a1a,stroke:#f85149,color:#fff",
        "other": "fill:#24292f,stroke:#8b949e,color:#fff",
    ]
    static func classOf(_ kind: String) -> String {
        if kind == "Ingress" || kind == "Gateway" || kind.hasSuffix("Route") { return "Ingress" }
        if kind == "Service" { return "Service" }
        if workloads.contains(kind) { return "workload" }
        if ["ConfigMap", "Secret", "PersistentVolumeClaim", "ServiceAccount", "Certificate", "StorageClass"].contains(kind) { return "config" }
        if kind.contains("Role") { return "rbac" }
        return "other"
    }

    /// A Mermaid flowchart of the graph — pasteable into GitHub, Notion, Markdown.
    static func toMermaid(_ g: Graph, title: String? = nil) -> String {
        var lines: [String] = []
        if let t = title?.nilIfEmpty { lines += ["---", "title: \(mermaidText(t))", "---"] }
        lines.append("flowchart LR")
        var classes: [(String, [String])] = []
        let sorted = g.nodes.sorted { a, b in
            let ra = rankOf(a.kind), rb = rankOf(b.kind)
            return ra != rb ? ra < rb : a.id.localizedCompare(b.id) == .orderedAscending
        }
        for n in sorted {
            let extra = n.detail.isEmpty ? "" : "<br/><small>\(mermaidText(n.detail))</small>"
            lines.append("  \(mermaidId(n.id))[\"\(mermaidText(n.kind))<br/><b>\(mermaidText(n.name))</b>\(extra)\"]")
            let c = classOf(n.kind)
            if let i = classes.firstIndex(where: { $0.0 == c }) { classes[i].1.append(mermaidId(n.id)) } else { classes.append((c, [mermaidId(n.id)])) }
        }
        for e in g.edges { lines.append("  \(mermaidId(e.from)) -->|\(mermaidText(e.label))| \(mermaidId(e.to))") }
        for (c, ids) in classes {
            lines.append("  classDef \(c) \(mermaidClass[c] ?? "")")
            lines.append("  class \(ids.joined(separator: ",")) \(c)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Helm manifest straight to the graph the diagram draws (each node with
    /// its column, `rank`) and the Mermaid it exports.
    static func manifestGraph(_ text: String?, title: String? = nil) -> (graph: Graph, mermaid: String) {
        var g = buildGraph(parseManifests(text))
        let m = toMermaid(g, title: title)
        g.nodes = g.nodes.map { var n = $0; n.rank = rankOf(n.kind); return n }
        return (g, m)
    }

    /// The same as JSON: `{nodes:[{id,kind,name,namespace,detail,rank}], edges, external, mermaid}`.
    static func manifestGraphJSON(_ text: String?, title: String? = nil) -> JSON {
        let (g, m) = manifestGraph(text, title: title)
        return ["nodes": .array(g.nodes.map { ["id": .string($0.id), "kind": .string($0.kind), "name": .string($0.name),
                                               "namespace": .string($0.namespace), "detail": .string($0.detail), "rank": .number(Double($0.rank))] }),
                "edges": .array(g.edges.map { ["from": .string($0.from), "to": .string($0.to), "label": .string($0.label)] }),
                "external": JSON(g.external), "mermaid": .string(m)]
    }
}
