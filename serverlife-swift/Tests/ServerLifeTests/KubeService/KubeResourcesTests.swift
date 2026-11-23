import Foundation
import Testing
@testable import ServerLife

func kj(_ s: String) -> JSON { try! JSON.parse(s) }

/// tests/kuberesources.test.mjs
@Suite struct KubeResourcesTests {
    static let cols: [(String, Int)] = [("NAME", 0), ("SHORTNAMES", 36), ("APIVERSION", 89), ("NAMESPACED", 123), ("KIND", 136), ("VERBS", 171), ("CATEGORIES", 232)]
    static func row(_ fields: [String]) -> String {
        var line = ""
        for (i, c) in cols.enumerated() {
            if line.count < c.1 { line += String(repeating: " ", count: c.1 - line.count) }
            line += fields[i]
        }
        return line
    }
    static let all = "create,delete,deletecollection,get,list,patch,update,watch"
    static let sample = [
        row(cols.map { $0.0 }),
        row(["bindings", "", "v1", "true", "Binding", "create", ""]),
        row(["configmaps", "cm", "v1", "true", "ConfigMap", all, ""]),
        row(["pods", "po", "v1", "true", "Pod", all, "all"]),
        row(["nodes", "no", "v1", "false", "Node", all, ""]),
        row(["ingresses", "ing", "networking.k8s.io/v1", "true", "Ingress", all, ""]),
    ].joined(separator: "\n")

    @Test func apiResources() {
        let t = KubeResources.parseApiResources(Self.sample)
        let b = t.first { $0["name"].string == "bindings" }
        #expect(b == kj(#"{"name":"bindings","shortNames":[],"apiVersion":"v1","namespaced":true,"kind":"Binding","verbs":["create"],"categories":[]}"#))
        let pods = t.first { $0["name"].string == "pods" }!
        #expect(pods["shortNames"][0].string == "po")
        #expect(pods["kind"].string == "Pod")
        #expect(pods["categories"] == ["all"])
        #expect(t.first { $0["name"].string == "nodes" }?["namespaced"] == .bool(false))
        #expect(KubeResources.parseApiResources("garbage\nmore garbage").isEmpty)
        #expect(KubeResources.parseApiResources("").isEmpty)
    }

    @Test func categories() {
        func c(_ k: String, _ v: String) -> String { KubeResources.categorize(["kind": .string(k), "apiVersion": .string(v)]) }
        #expect(c("Pod", "v1") == "Workloads")
        #expect(c("Secret", "v1") == "Config")
        #expect(c("Ingress", "networking.k8s.io/v1") == "Network")
        #expect(c("PersistentVolumeClaim", "v1") == "Storage")
        #expect(c("ClusterRole", "rbac.authorization.k8s.io/v1") == "Access Control")
        #expect(c("Namespace", "v1") == "Cluster")
        #expect(c("Widget", "example.io/v1alpha1") == "Custom Resources: example.io")
        #expect(c("Certificate", "cert-manager.io/v1") == "Custom Resources: cert-manager.io")
        #expect(c("Application", "argoproj.io/v1alpha1") == "GitOps")
        #expect(c("AppProject", "argoproj.io/v1alpha1") == "GitOps")
        #expect(c("Kustomization", "kustomize.toolkit.fluxcd.io/v1") == "GitOps")
        #expect(c("HelmRelease", "helm.toolkit.fluxcd.io/v2") == "GitOps")
        #expect(c("GitRepository", "source.toolkit.fluxcd.io/v1") == "GitOps")
        #expect(c("Kustomization", "example.io/v1") == "Custom Resources: example.io")
        #expect(c("SomethingNew", "v1") == "Custom Resources")
    }

    @Test func details() {
        let d = KubeResources.detailOf
        #expect(d("Pod", kj(#"{"kind":"Pod","status":{"containerStatuses":[{"ready":true,"restartCount":0}]}}"#)) == "1/1 ready")
        #expect(d("Pod", kj(#"{"kind":"Pod","status":{"containerStatuses":[{"ready":true,"restartCount":29}]}}"#)) == "1/1 ready, 29 restarts")
        #expect(d("Deployment", kj(#"{"status":{"readyReplicas":1},"spec":{"replicas":1}}"#)) == "1/1 ready")
        #expect(d("Deployment", kj(#"{"status":{},"spec":{"replicas":3}}"#)) == "0/3 ready")
        #expect(d("DaemonSet", kj(#"{"status":{"numberReady":2,"desiredNumberScheduled":2}}"#)) == "2/2 ready")
        #expect(d("Node", kj(#"{"metadata":{"labels":{}},"status":{"nodeInfo":{"kubeletVersion":"v1.35.8-gke.1796000"}}}"#)) == "worker · v1.35.8-gke.1796000")
        #expect(d("Node", kj(#"{"metadata":{"labels":{"node-role.kubernetes.io/control-plane":""}},"status":{"nodeInfo":{}}}"#)) == "control-plane · ")
        #expect(d("WidgetThing", [:]) == "")
        #expect(d("ResourceQuota", kj(#"{"status":{"hard":{"pods":"20","requests.cpu":"4","requests.memory":"8Gi","limits.cpu":"8"},"used":{"pods":"12","requests.cpu":"2500m"}}}"#))
                == "0/8 limits.cpu · 12/20 pods · 2500m/4 requests.cpu")
        // ^ JS keeps the fixture's insertion order; JSON here is sorted, which is
        //   also the order the API server sends (Go marshals map keys sorted).
        #expect(d("ResourceQuota", kj(#"{"status":{"hard":{"pods":"20","requests.cpu":"4","requests.memory":"8Gi"},"used":{"pods":"12","requests.cpu":"2500m"}}}"#))
                == "12/20 pods · 2500m/4 requests.cpu · 0/8Gi requests.memory")
        #expect(d("ResourceQuota", kj(#"{"status":{}}"#)) == "no limits set")
        #expect(d("LimitRange", kj(#"{"spec":{"limits":[{"type":"Container","default":{"cpu":"500m","memory":"256Mi"}},{"type":"Pod"}]}}"#))
                == "Container: cpu 500m, memory 256Mi (+1 more)")
        #expect(d("LimitRange", kj(#"{"spec":{"limits":[{"type":"Container","defaultRequest":{"cpu":"100m"}}]}}"#)) == "Container: cpu 100m")
        #expect(d("LimitRange", kj(#"{"spec":{}}"#)) == "no limits defined")
        #expect(d("Role", kj(#"{"rules":[{},{}]}"#)) == "2 rules")
        #expect(d("ClusterRole", kj(#"{"rules":[{}]}"#)) == "1 rule")
        #expect(d("Role", [:]) == "0 rules")
        #expect(d("RoleBinding", kj(#"{"roleRef":{"kind":"ClusterRole","name":"view"},"subjects":[{"kind":"User","name":"alice"},{"kind":"Group","name":"devs"}]}"#))
                == "ClusterRole/view → 2 subjects")
        #expect(d("ClusterRoleBinding", kj(#"{"roleRef":{"kind":"Role","name":"x"},"subjects":[{}]}"#)) == "Role/x → 1 subject")
        #expect(d("Application", kj(#"{"apiVersion":"argoproj.io/v1alpha1","status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}"#)) == "Synced, Healthy")
        #expect(d("Application", kj(#"{"apiVersion":"argoproj.io/v1alpha1"}"#)) == "Unknown, Unknown")
        #expect(d("Kustomization", kj(#"{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","status":{"conditions":[{"type":"Ready","status":"True"}]}}"#)) == "Ready")
        #expect(d("Kustomization", kj(#"{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","status":{"conditions":[{"type":"Ready","status":"False","reason":"BuildFailed"}]}}"#)) == "Not ready: BuildFailed")
        #expect(d("HelmRelease", kj(#"{"apiVersion":"helm.toolkit.fluxcd.io/v2","status":{}}"#)) == "Unknown")
        #expect(d("Widget", kj(#"{"apiVersion":"example.io/v1alpha1","status":{"conditions":[{"type":"Ready","status":"True"}]}}"#)) == "")
    }

    @Test func conditions() {
        #expect(KubeResources.conditionStatus(kj(#"{"status":{"conditions":[{"type":"MemoryPressure","status":"False"},{"type":"Ready","status":"True"}]}}"#)) == "Ready")
        #expect(KubeResources.conditionStatus(kj(#"{"status":{"conditions":[{"type":"Ready","status":"False"}]}}"#)) == "NotReady")
        #expect(KubeResources.conditionStatus(kj(#"{"status":{"conditions":[{"type":"Available","status":"True"}]}}"#)) == "Available")
    }

    @Test func rows() {
        let row = KubeResources.rowFrom(kj(#"{"kind":"Pod","metadata":{"name":"web-1","namespace":"ns","creationTimestamp":"2026-01-01T00:00:00Z"},"status":{"phase":"Running"},"spec":{"containers":[{"name":"app"},{"name":"sidecar"}]}}"#))
        #expect(row["name"].string == "web-1")
        #expect(row["namespace"].string == "ns")
        #expect(row["status"].string == "Running")
        #expect(row["containers"] == ["app", "sidecar"])
        let ev = KubeResources.rowFrom(kj(#"{"kind":"Event","type":"Warning","metadata":{"name":"e1","namespace":"ns","creationTimestamp":"2026-01-01T00:00:00Z"},"lastTimestamp":"2026-01-02T00:00:00Z"}"#))
        #expect(ev["status"].string == "Warning")
        #expect(ev["age"].string == "2026-01-02T00:00:00Z")
    }

    @Test func crdColumns() {
        let crd = kj(#"{"spec":{"versions":[{"name":"v1","additionalPrinterColumns":[{"name":"Ready","type":"string","jsonPath":".status.conditions[?(@.type == \"Ready\")].status"},{"name":"Secret","type":"string","jsonPath":".spec.secretName"}]},{"name":"v1alpha2","additionalPrinterColumns":[{"name":"Old","type":"string","jsonPath":".spec.old"}]}]}}"#)
        let want = [kj(#"{"label":"Ready","jsonPath":".status.conditions[?(@.type == \"Ready\")].status","type":"string"}"#),
                    kj(#"{"label":"Secret","jsonPath":".spec.secretName","type":"string"}"#)]
        #expect(KubeResources.columnsFromCrdObject(crd, "v1") == want)
        #expect(KubeResources.columnsFromCrdObject(crd, "v2-does-not-exist") == want)
        #expect(KubeResources.columnsFromCrdObject(kj(#"{"spec":{"versions":[{"name":"v1"}]}}"#), "v1").isEmpty)
        #expect(KubeResources.columnsFromCrdObject([:], "v1").isEmpty)
    }

    @Test func sampleChecks() {
        let s = KubeResources.sampleChecksFromRules
        #expect(s(kj(#"[{"verbs":["get","list"],"resources":["pods","nodes"]},{"verbs":["create"],"resources":["secrets"]}]"#), "ns1")
                == [kj(#"{"verb":"get","resource":"pods","namespace":"ns1"}"#), kj(#"{"verb":"create","resource":"secrets","namespace":"ns1"}"#)])
        let w = s(kj(#"[{"verbs":["*"],"resources":["*"]}]"#), nil)
        #expect(w.count == 1 && w[0]["verb"].string == "get" && w[0]["resource"].string == "pods" && w[0]["namespace"].string == nil)
        #expect(s(kj(#"[{"verbs":[],"resources":["pods"]},{"verbs":["get"],"resources":[]}]"#), "ns1").isEmpty)
        #expect(s(.array((0..<15).map { ["verbs": ["get"], "resources": .array([.string("r\($0)")])] }), "ns1").count == 10)
        #expect(s(.null, "ns1").isEmpty)
    }
}
