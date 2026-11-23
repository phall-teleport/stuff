import Foundation

/// Which cloud (or local tool) a cluster runs on (kubeprovider.js). Evidence
/// comes from what is already at hand — the kubeconfig, Teleport's labels,
/// the nodes' providerID and labels, the server version — then the name as
/// a guess, said as one. No cloud API is ever called.
///
/// Answers are JSON objects `{provider, how, short, name, cloud, color, region?,
/// account?, project?, location?, resourceGroup?, subscription?, clusterName?,
/// guess?, managed?}`, exactly as the original's.
enum KubeProvider {
    static let providers: [String: (short: String, name: String, cloud: String, color: String)] = [
        "eks": ("EKS", "Amazon EKS", "AWS", "#ff9900"),
        "gke": ("GKE", "Google GKE", "Google Cloud", "#4285f4"),
        "aks": ("AKS", "Azure AKS", "Azure", "#0078d4"),
        "minikube": ("mk", "minikube", "local", "#326ce5"),
        "kind": ("kind", "kind", "local", "#326ce5"),
        "docker-desktop": ("DD", "Docker Desktop", "local", "#1d63ed"),
        "k3s": ("k3s", "k3s", "local", "#ffc61c"),
    ]

    static let confidence: [String: Int] = ["manual": 5, "kubeconfig": 3, "labels": 3, "cluster": 4, "name": 1]

    static func result(_ provider: String?, _ how: String, _ extra: [String: String?] = [:]) -> JSON? {
        guard let provider else { return nil }
        var out: [String: JSON] = ["provider": .string(provider), "how": .string(how)]
        if let p = providers[provider] {
            out["short"] = .string(p.short); out["name"] = .string(p.name)
            out["cloud"] = .string(p.cloud); out["color"] = .string(p.color)
        }
        for (k, v) in extra { if let v, !v.isEmpty { out[k] = .string(v) } }
        return .object(out)
    }

    /// `arn:aws:eks:us-west-2:123456789012:cluster/name` → its parts.
    static func parseEksArn(_ s: String?) -> [String: String?]? {
        guard let m = TPText.match(#"^arn:aws(?:-[a-z]+)*:eks:([a-z0-9-]+):(\d{12}):cluster/(.+)$"#, s ?? "") else { return nil }
        return ["region": m[1], "account": m[2], "clusterName": m[3]]
    }

    /// An argument's value from an exec plugin's args: `--region x` or `--region=x`.
    static func argValue(_ args: [String], _ names: String...) -> String {
        for i in args.indices {
            for n in names {
                if args[i] == n && i + 1 < args.count { return args[i + 1] }
                if args[i].hasPrefix(n + "=") { return String(args[i].dropFirst(n.count + 1)) }
            }
        }
        return ""
    }

    /// From a kubeconfig context: its name, its cluster's server, and its user's exec plugin.
    static func fromKubeconfig(contextName: String = "", clusterName: String = "", server: String = "", exec: JSON = .null) -> JSON? {
        let cmd = exec["command"].kStr.components(separatedBy: "/").last ?? ""
        let args = exec["args"].items.map { $0.stringish ?? "" }
        if let arn = parseEksArn(contextName) ?? parseEksArn(clusterName) { return result("eks", "kubeconfig", arn) }
        let eksHost = TPText.match(#"\.([a-z]{2}(?:-gov)?-[a-z]+-\d)\.eks\.amazonaws\.com(?:\.cn)?(?::\d+)?/?$"#, server, .caseInsensitive)
        if eksHost != nil || (cmd == "aws" && args.contains("eks")) || cmd == "aws-iam-authenticator" {
            let region = kubeOr(eksHost?[1] ?? nil, argValue(args, "--region"))
            return result("eks", "kubeconfig", ["region": region, "clusterName": argValue(args, "--cluster-name", "-i", "--cluster-id")])
        }
        let gkeRe = #"^gke_([^_]+)_([^_]+)_(.+)$"#
        if let g = TPText.match(gkeRe, contextName) ?? TPText.match(gkeRe, clusterName) {
            return result("gke", "kubeconfig", ["project": g[1], "location": g[2], "clusterName": g[3]])
        }
        if cmd == "gke-gcloud-auth-plugin" || TPText.test(#"\.gke\.goog\b|container\.googleapis\.com"#, server) { return result("gke", "kubeconfig") }
        let aksHost = TPText.match(#"^https?://([^.]+)\.(?:hcp|privatelink)\.([a-z0-9]+)\.azmk8s\.io"#, server, .caseInsensitive)
        if aksHost != nil || TPText.test(#"\.azmk8s\.io"#, server, .caseInsensitive) || cmd == "kubelogin" {
            return result("aks", "kubeconfig", ["region": aksHost?[2] ?? nil, "clusterName": kubeOr(clusterName, contextName)])
        }
        if let local = fromLocalName(contextName) ?? fromLocalName(clusterName) { return result(local, "kubeconfig") }
        return nil
    }

    static func fromLocalName(_ name: String?) -> String? {
        let n = (name ?? "").lowercased()
        if n == "minikube" { return "minikube" }
        if n == "docker-desktop" || n == "docker-for-desktop" { return "docker-desktop" }
        if n.hasPrefix("kind-") { return "kind" }
        if TPText.test(#"^k3d-|^k3s\b"#, n) { return "k3s" }
        return nil
    }

    /// From the labels Teleport has for a cluster.
    static func fromLabels(_ labels: JSON) -> JSON? {
        let l = labels.entries
        func v(_ ks: String...) -> String { for k in ks { if let s = l[k]?.kStr, !s.isEmpty { return s } }; return "" }
        let cloud = v("teleport.dev/cloud", "cloud", "cloud-provider").lowercased()
        let extra: [String: String?] = [
            "region": v("region", "aws/region", "location", "gcp/location", "azure/location"),
            "account": v("account-id", "aws/account-id"),
            "project": v("project-id", "gcp/project-id"),
            "resourceGroup": v("resource-group", "azure/resource-group"),
            "subscription": v("subscription-id", "azure/subscription-id"),
        ]
        let keys = Array(l.keys)
        if cloud == "aws" || cloud == "eks" || keys.contains(where: { $0.hasPrefix("aws/") }) { return result("eks", "labels", extra) }
        if cloud == "gcp" || cloud == "gke" || cloud == "google" || keys.contains(where: { $0.hasPrefix("gcp/") }) { return result("gke", "labels", extra) }
        if cloud == "azure" || cloud == "aks" || keys.contains(where: { $0.hasPrefix("azure/") }) { return result("aks", "labels", extra) }
        return nil
    }

    /// From a name alone — a guess, said as one.
    static func fromName(_ name: String?) -> JSON? {
        let n = (name ?? "").lowercased()
        if let local = fromLocalName(n) { return result(local, "name") }
        if TPText.test(#"(^|[^a-z])eks([^a-z]|$)"#, n) { return result("eks", "name") }
        if TPText.test(#"(^|[^a-z])gke([^a-z]|$)"#, n) { return result("gke", "name") }
        if TPText.test(#"(^|[^a-z])aks([^a-z]|$)"#, n) { return result("aks", "name") }
        return nil
    }

    /// From the cluster itself: its nodes (providerID, labels) and its version.
    static func fromCluster(nodes: [JSON] = [], version: String = "") -> JSON? {
        let v = version
        let ids = nodes.map { $0["spec"]["providerID"].kStr }
        var labelKeys = Set<String>()
        for n in nodes { labelKeys.formUnion(n["metadata"]["labels"].entries.keys) }
        func label(_ k: String) -> String { nodes.map { $0["metadata"]["labels"][k].kStr }.first { !$0.isEmpty } ?? "" }
        let region = kubeOr(label("topology.kubernetes.io/region"), label("failure-domain.beta.kubernetes.io/region"))
        let r: [String: String?] = ["region": region]
        if TPText.test("-eks-", v) || labelKeys.contains(where: { $0.hasPrefix("eks.amazonaws.com/") })
            || ids.contains(where: { $0.hasPrefix("aws://") && TPText.test("eks|fargate", $0, .caseInsensitive) }) { return result("eks", "cluster", r) }
        if TPText.test(#"-gke\."#, v) || labelKeys.contains(where: { $0.hasPrefix("cloud.google.com/gke-") }) { return result("gke", "cluster", r) }
        if labelKeys.contains(where: { $0.hasPrefix("kubernetes.azure.com/") })
            || ids.contains(where: { $0.hasPrefix("azure://") && TPText.test("aks|virtualMachineScaleSets", $0, .caseInsensitive) }) { return result("aks", "cluster", r) }
        if labelKeys.contains("minikube.k8s.io/name") { return result("minikube", "cluster") }
        if ids.contains(where: { $0.hasPrefix("kind://") }) { return result("kind", "cluster") }
        if TPText.test(#"\+k3s"#, v) || ids.contains(where: { $0.hasPrefix("k3s://") }) { return result("k3s", "cluster") }
        if nodes.contains(where: { $0["metadata"]["name"].string == "docker-desktop" }) { return result("docker-desktop", "cluster") }
        func unmanaged(_ p: String, _ short: String, _ name: String) -> JSON? {
            guard var o = result(p, "cluster", r) else { return nil }
            o["short"] = .string(short); o["name"] = .string(name); o["managed"] = false
            return o
        }
        if ids.contains(where: { $0.hasPrefix("aws://") }) { return unmanaged("eks", "AWS", "Kubernetes on AWS") }
        if ids.contains(where: { $0.hasPrefix("gce://") }) { return unmanaged("gke", "GCP", "Kubernetes on Google Cloud") }
        if ids.contains(where: { $0.hasPrefix("azure://") }) { return unmanaged("aks", "Azure", "Kubernetes on Azure") }
        return nil
    }

    /// The most confident answer, filled in with whatever the others agree on.
    static func combine(_ answers: JSON?...) -> JSON? { combine(list: answers) }

    static func combine(list answers: [JSON?]) -> JSON? {
        let found = answers.compactMap { $0 }.filter { $0.truthy }
        guard !found.isEmpty else { return nil }
        // A stable sort, as Array.prototype.sort is.
        let best = found.enumerated().sorted { a, b in
            let ca = confidence[a.element["how"].kStr] ?? 0, cb = confidence[b.element["how"].kStr] ?? 0
            return ca != cb ? ca > cb : a.offset < b.offset
        }[0].element
        var out = best
        for a in found where a["provider"] == best["provider"] {
            for k in ["region", "account", "project", "location", "resourceGroup", "subscription", "clusterName"]
            where !out[k].truthy && a[k].truthy { out[k] = a[k] }
        }
        out["guess"] = .bool(best["how"].string == "name")
        return out
    }

    private static func enc(_ s: String) -> String {
        // encodeURIComponent
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// The cluster's page in its cloud's console, when enough is known to build one.
    static func consoleUrl(_ p: JSON?, clusterName: String = "") -> String {
        guard let p, p.truthy else { return "" }
        let name = enc(kubeOr(p["clusterName"].string, clusterName))
        if name.isEmpty { return "" }
        let managed = p["managed"].bool != false
        let provider = p["provider"].kStr
        let region = p["region"].kStr
        if provider == "eks", !region.isEmpty, managed {
            let host = region.hasPrefix("us-gov-") ? "console.amazonaws-us-gov.com" : "console.aws.amazon.com"
            return "https://\(host)/eks/home?region=\(region)#/clusters/\(name)"
        }
        let loc = kubeOr(p["location"].string, region)
        if provider == "gke", !p["project"].kStr.isEmpty, !loc.isEmpty, managed {
            return "https://console.cloud.google.com/kubernetes/clusters/details/\(loc)/\(name)/details?project=\(enc(p["project"].kStr))"
        }
        if provider == "aks", !p["subscription"].kStr.isEmpty, !p["resourceGroup"].kStr.isEmpty, managed {
            return "https://portal.azure.com/#@/resource/subscriptions/\(p["subscription"].kStr)/resourceGroups/\(enc(p["resourceGroup"].kStr))/providers/Microsoft.ContainerService/managedClusters/\(name)/overview"
        }
        return ""
    }

    // MARK: - What is worth knowing once the cluster can be read

    private static func L(_ n: JSON, _ k: String) -> String { n["metadata"]["labels"][k].kStr }
    private static func ready(_ n: JSON) -> Bool {
        n["status"]["conditions"].items.contains { $0["type"].string == "Ready" && $0["status"].string == "True" }
    }

    /// Which pool a node is in, and what kind of capacity, on its provider.
    static func poolOf(_ n: JSON, _ provider: String?) -> [String: String] {
        switch provider {
        case "eks":
            if L(n, "eks.amazonaws.com/compute-type") == "fargate" {
                return ["pool": "Fargate", "kind": "fargate", "capacity": "Fargate", "selector": "eks.amazonaws.com/compute-type=fargate"]
            }
            if !L(n, "karpenter.sh/nodepool").isEmpty || !L(n, "karpenter.sh/provisioner-name").isEmpty {
                let key = !L(n, "karpenter.sh/nodepool").isEmpty ? "karpenter.sh/nodepool" : "karpenter.sh/provisioner-name"
                return ["pool": L(n, key), "kind": "karpenter", "capacity": L(n, "karpenter.sh/capacity-type"), "selector": "\(key)=\(L(n, key))"]
            }
            let np = L(n, "eks.amazonaws.com/nodepool")
            if L(n, "eks.amazonaws.com/compute-type") == "auto" || !np.isEmpty {
                return ["pool": kubeOr(np, "Auto Mode"), "kind": "auto", "capacity": L(n, "karpenter.sh/capacity-type"),
                        "selector": !np.isEmpty ? "eks.amazonaws.com/nodepool=\(np)" : "eks.amazonaws.com/compute-type=auto"]
            }
            let ng = L(n, "eks.amazonaws.com/nodegroup")
            if !ng.isEmpty {
                return ["pool": ng, "kind": "nodegroup", "capacity": L(n, "eks.amazonaws.com/capacityType"), "selector": "eks.amazonaws.com/nodegroup=\(ng)"]
            }
            return ["pool": "self-managed", "kind": "self-managed", "capacity": "", "selector": "!eks.amazonaws.com/nodegroup,!karpenter.sh/nodepool"]
        case "gke":
            let spot = L(n, "cloud.google.com/gke-spot") == "true" ? "Spot"
                : L(n, "cloud.google.com/gke-preemptible") == "true" ? "Preemptible" : "Standard"
            let pool = L(n, "cloud.google.com/gke-nodepool")
            return ["pool": kubeOr(pool, "default"), "kind": "nodepool", "capacity": spot, "selector": pool.isEmpty ? "" : "cloud.google.com/gke-nodepool=\(pool)"]
        case "aks":
            let key = !L(n, "kubernetes.azure.com/agentpool").isEmpty ? "kubernetes.azure.com/agentpool" : "agentpool"
            return ["pool": kubeOr(L(n, key), "default"), "kind": "agentpool",
                    "capacity": L(n, "kubernetes.azure.com/scalesetpriority") == "spot" ? "Spot" : "Regular",
                    "mode": L(n, "kubernetes.azure.com/mode"), "selector": L(n, key).isEmpty ? "" : "\(key)=\(L(n, key))"]
        default:
            return ["pool": "nodes", "kind": "nodes", "capacity": "", "selector": ""]
        }
    }

    /// Node pools: what each holds, how much of it is ready, on what machines and where.
    static func nodePools(_ nodes: [JSON], _ provider: String?) -> [JSON] {
        final class Pool {
            var name = "", kind = "", mode = "", selector = ""
            var capacity: [String] = [], types: [String] = [], zones: [String] = [], versions: [String] = [], arch: [String] = []
            var nodes = 0, ready = 0
            func add(_ list: inout [String], _ v: String) { if !list.contains(v) { list.append(v) } }
        }
        var order: [String] = []
        var pools: [String: Pool] = [:]
        for n in nodes {
            let p = poolOf(n, provider)
            let key = "\(p["kind"] ?? ""):\(p["pool"] ?? "")"
            if pools[key] == nil {
                let e = Pool()
                e.name = p["pool"] ?? ""; e.kind = p["kind"] ?? ""; e.mode = p["mode"] ?? ""; e.selector = p["selector"] ?? ""
                pools[key] = e; order.append(key)
            }
            let e = pools[key]!
            e.nodes += 1
            if ready(n) { e.ready += 1 }
            if let c = p["capacity"], !c.isEmpty { e.add(&e.capacity, c) }
            let t = kubeOr(L(n, "node.kubernetes.io/instance-type"), L(n, "beta.kubernetes.io/instance-type"))
            if !t.isEmpty { e.add(&e.types, t) }
            let z = kubeOr(L(n, "topology.kubernetes.io/zone"), L(n, "failure-domain.beta.kubernetes.io/zone"))
            if !z.isEmpty && !TPText.test(#"^\d+$"#, z) { e.add(&e.zones, z) }
            let kv = n["status"]["nodeInfo"]["kubeletVersion"].kStr
            if !kv.isEmpty { e.add(&e.versions, kv) }
            if !L(n, "kubernetes.io/arch").isEmpty { e.add(&e.arch, L(n, "kubernetes.io/arch")) }
        }
        let list = order.compactMap { pools[$0] }.sorted { a, b in
            a.nodes != b.nodes ? a.nodes > b.nodes : a.name.localizedCompare(b.name) == .orderedAscending
        }
        return list.map { e in
            ["name": .string(e.name), "kind": .string(e.kind), "mode": .string(e.mode), "selector": .string(e.selector),
             "capacity": JSON(e.capacity), "types": JSON(e.types), "zones": JSON(e.zones.sorted()),
             "versions": JSON(e.versions), "arch": JSON(e.arch), "nodes": JSON(e.nodes), "ready": JSON(e.ready)]
        }
    }

    /// Service accounts mapped to a cloud identity: IRSA, GKE Workload Identity, Azure Workload Identity.
    static func cloudIdentities(_ serviceAccounts: [JSON]) -> [JSON] {
        var out: [JSON] = []
        for sa in serviceAccounts {
            let a = sa["metadata"]["annotations"]
            let ns = sa["metadata"]["namespace"].kStr, name = sa["metadata"]["name"].kStr
            func add(_ cloud: String, _ via: String, _ id: String) {
                out.append(["namespace": .string(ns), "name": .string(name), "cloud": .string(cloud), "via": .string(via), "identity": .string(id)])
            }
            if a["eks.amazonaws.com/role-arn"].truthy { add("eks", "IRSA", a["eks.amazonaws.com/role-arn"].kStr) }
            if a["iam.gke.io/gcp-service-account"].truthy { add("gke", "Workload Identity", a["iam.gke.io/gcp-service-account"].kStr) }
            if a["azure.workload.identity/client-id"].truthy { add("aks", "Workload Identity", a["azure.workload.identity/client-id"].kStr) }
        }
        return out.enumerated().sorted { x, y in
            let a = x.element["namespace"].kStr + x.element["name"].kStr, b = y.element["namespace"].kStr + y.element["name"].kStr
            let c = a.localizedCompare(b)
            return c == .orderedSame ? x.offset < y.offset : c == .orderedAscending
        }.map(\.element)
    }

    /// EKS's kube-system/aws-auth ConfigMap: which IAM roles and users are which Kubernetes users and groups.
    static func awsAuthMappings(_ configMap: JSON?) -> [JSON]? {
        guard let cm = configMap, cm["data"].truthy else { return nil }
        func read(_ k: String) -> [JSON] {
            guard let v = try? YAMLReader.load(cm["data"][k].kStr) else { return [] }
            return v.json.items
        }
        let roles = read("mapRoles").map { r -> JSON in
            ["kind": "role", "arn": .string(r["rolearn"].kStr), "username": .string(r["username"].kStr), "groups": r["groups"].truthy ? r["groups"] : []]
        }
        let users = read("mapUsers").map { u -> JSON in
            ["kind": "user", "arn": .string(u["userarn"].kStr), "username": .string(u["username"].kStr), "groups": u["groups"].truthy ? u["groups"] : []]
        }
        let accounts = read("mapAccounts").map { a -> JSON in
            ["kind": "account", "arn": .string(a.stringish ?? ""), "username": "", "groups": []]
        }
        return roles + users + accounts
    }

    /// Everything the Cloud view shows, from what was read of the cluster.
    static func summarize(provider known: JSON? = nil, nodes: [JSON] = [], serviceAccounts: [JSON] = [], awsAuth: JSON? = nil, version: String = "") -> JSON {
        let seen = fromCluster(nodes: nodes, version: version)
        let p = combine(known, seen)
        let provider = p?["provider"].string
        let autopilot = provider == "gke" && nodes.contains { $0["metadata"]["labels"].entries.keys.contains { $0.hasPrefix("autopilot.gke.io") } }
        var aws: JSON = .null
        if provider == "eks", let m = awsAuthMappings(awsAuth) { aws = .array(m) }
        return ["provider": p ?? .null, "version": .string(version),
                "nodes": JSON(nodes.count), "readyNodes": JSON(nodes.filter(ready).count),
                "pools": .array(nodePools(nodes, provider)),
                "identities": .array(cloudIdentities(serviceAccounts)),
                "awsAuth": aws, "autopilot": .bool(autopilot)]
    }
}
