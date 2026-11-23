import Foundation
import Testing
@testable import ServerLife

/// tests/kubescan.test.mjs, kubetest.test.mjs, kuberbac.test.mjs, kuberelations.test.mjs.
@Suite struct KubeScanTests {
    @Test func scene() {
        let s = KubeScan.buildScene(pods: [
            ["name": "b-pod", "namespace": "ns2", "phase": "Running", "ready": 1, "total": 1, "restarts": 0, "containers": ["c1"], "node": "n1"],
            ["name": "a-pod", "namespace": "ns1", "phase": "Running", "ready": 1, "total": 1, "restarts": 0, "containers": ["c1"], "node": "n1"],
            ["name": "c-pod", "namespace": "ns1", "phase": "Pending", "ready": 0, "total": 1, "restarts": 0, "containers": ["c1"], "node": "n1"],
        ])
        #expect(s["podCount"] == 3)
        #expect(s["namespaces"].items.map { $0["name"] } == ["ns1", "ns2"])
        #expect(s["namespaces"][0]["pods"].items.map { $0["name"] } == ["a-pod", "c-pod"])
        #expect(s["namespaces"][0]["podCount"] == 2)
        #expect(KubeScan.buildScene(pods: [["name": "x", "namespace": "", "phase": "Running", "containers": []]])["namespaces"][0]["name"] == "default")
        let quiet = KubeScan.heightOf(["phase": "Running", "total": 1, "restarts": 0])
        let flaky = KubeScan.heightOf(["phase": "Running", "total": 1, "restarts": 500])
        #expect(flaky > quiet && flaky - quiet <= 3.1)
        #expect(KubeScan.footprintOf(["phase": "Running"]) == 1)
        #expect(KubeScan.buildScene() == ["namespaces": [], "podCount": 0])
    }

    @Test func workloads() {
        let s = KubeScan.buildScene(pods: [["name": "web-1", "namespace": "app", "phase": "Running", "containers": ["c"]]],
                                    deployments: [["name": "web", "namespace": "app", "detail": "2/3 ready"], ["name": "api", "namespace": "app", "detail": "1/1 ready"]],
                                    services: [["name": "web-svc", "namespace": "app", "detail": "ClusterIP"]])
        let ns = s["namespaces"][0]
        #expect(ns["deployments"] == [["name": "api", "ready": 1, "desired": 1], ["name": "web", "ready": 2, "desired": 3]])
        #expect(ns["services"] == [["name": "web-svc", "detail": "ClusterIP"]])
        #expect(ns["podCount"] == 1 && s["podCount"] == 1)
        let q = KubeScan.buildScene(deployments: [["name": "idle", "namespace": "quiet", "detail": "0/0 ready"]])
        #expect(q["namespaces"].items.map { $0["name"] } == ["quiet"] && q["namespaces"][0]["podCount"] == 0)
        func rr(_ s: String?) -> [Double] { let r = KubeScan.readyRatioOf(s); return [r.ready, r.desired] }
        #expect(rr("3/3 ready") == [3, 3] && rr("0/2 ready · cpu 1m") == [0, 2] && rr("Running") == [0, 0] && rr(nil) == [0, 0])
    }

    @Test func links() {
        let s = KubeScan.buildScene(pods: [
            ["name": "web-1", "namespace": "app", "labels": ["app": "web", "tier": "fe"]],
            ["name": "web-2", "namespace": "app", "labels": ["app": "web", "tier": "fe"]],
            ["name": "db-0", "namespace": "app", "labels": ["app": "db"]],
            ["name": "stray", "namespace": "app", "labels": ["app": "other"]],
        ], deployments: [["name": "web", "namespace": "app", "selectorLabels": ["app": "web"]]],
           services: [["name": "web-svc", "namespace": "app", "selectorLabels": ["app": "web"]], ["name": "db-svc", "namespace": "app", "selectorLabels": ["app": "db"]]])
        #expect(s["namespaces"][0]["links"] == [["from": "Deployment/web", "to": "Pod/web-1"], ["from": "Deployment/web", "to": "Pod/web-2"],
                                                ["from": "Service/web-svc", "to": "Deployment/web"], ["from": "Service/db-svc", "to": "Pod/db-0"]])
        let t = KubeScan.buildScene(pods: [["name": "a", "namespace": "one", "labels": ["app": "x"]], ["name": "b", "namespace": "two", "labels": ["app": "x"]]],
                                    services: [["name": "s", "namespace": "one", "selectorLabels": ["app": "x"]], ["name": "manual", "namespace": "two", "selectorLabels": [:]]])
        #expect(t["namespaces"].items.first { $0["name"] == "one" }?["links"] == [["from": "Service/s", "to": "Pod/a"]])
        #expect(t["namespaces"].items.first { $0["name"] == "two" }?["links"] == [])
        #expect(!KubeScan.selects(["app": "x", "tier": "fe"], ["app": "x"]))
    }

    typealias C = KubeTest.Check
    @Test func selfCheckScript() {
        let s = KubeTest.buildSelfCheckScript([C(verb: "get", resource: "pods", namespace: "ns1"), C(verb: "list", resource: "secrets")])
        #expect(s.contains("CHECK get pods") && s.contains("CHECK list secrets"))
        #expect(s.components(separatedBy: "curl").count - 1 == 2)
        #expect(s.contains("/var/run/secrets/kubernetes.io/serviceaccount/token") && s.contains("kubernetes.default.svc"))
        let d = KubeTest.buildSelfCheckScript([C(verb: "delete", resource: "pods", namespace: "ns1")])
        for part in [#""kind":"SelfSubjectAccessReview""#, #""verb":"delete""#, #""resource":"pods""#, #""namespace":"ns1""#] { #expect(d.contains(part), "\(part)") }
        #expect(KubeTest.buildSelfCheckScript([C(verb: "get", resource: "nodes")]).contains(#""namespace":"""#))
        #expect(KubeTest.buildSelfCheckScript([C(verb: "ge't", resource: "pods")]).contains("'\\''"))
        let e = KubeTest.buildSelfCheckScript([])
        #expect(e.contains("TOKEN=") && e.contains("CACERT=") && e.contains("API=") && !e.contains("CHECK"))
    }

    @Test func checkResults() async {
        typealias R = KubeTest.Result
        let out = ["CHECK get pods", #"{"status":{"allowed":true}}"#, "", "CHECK delete secrets", #"{"status":{"allowed":false,"reason":"no matching rule"}}"#, ""].joined(separator: "\n")
        #expect(KubeTest.parseCheckResults(out, [C(verb: "get", resource: "pods"), C(verb: "delete", resource: "secrets")])
                == [R(verb: "get", resource: "pods", allowed: true, error: nil), R(verb: "delete", resource: "secrets", allowed: false, error: nil)])
        let err = KubeTest.parseCheckResults("CHECK get pods\n{\"message\":\"connection refused\"}\n", [C(verb: "get", resource: "pods")])
        #expect(err[0].allowed == nil && err[0].error == "connection refused")
        #expect(KubeTest.parseCheckResults("", [C(verb: "get", resource: "pods")]) == [R(verb: "get", resource: "pods", allowed: nil, error: nil)])
        let two = ["CHECK get pods", #"{"status":{"allowed":true}}"#, "CHECK get pods", #"{"status":{"allowed":false}}"#].joined(separator: "\n")
        #expect(KubeTest.parseCheckResults(two, [C(verb: "get", resource: "pods"), C(verb: "get", resource: "pods")]).map { $0.allowed } == [true, false])
        let pods = [C(verb: "get", resource: "pods")]
        #expect(await !KubeTest.testServiceAccountAccess(KubeSpec(), namespace: "", serviceAccountName: "sa1", checks: pods)["ok"].truthy)
        #expect(await !KubeTest.testServiceAccountAccess(KubeSpec(), namespace: "ns1", serviceAccountName: "", checks: pods)["ok"].truthy)
        let none = await KubeTest.testServiceAccountAccess(KubeSpec(), namespace: "ns1", serviceAccountName: "sa1", checks: [])
        #expect(!none["ok"].truthy && (none["error"].string ?? "").lowercased().contains("nothing to check"))
    }

    typealias Q = KubeRBAC.Query
    @Test func rbacRules() {
        let rule: JSON = ["verbs": ["get", "list"], "apiGroups": [""], "resources": ["pods"]]
        #expect(KubeRBAC.ruleAllows(rule, Q(verb: "get", resource: "pods")))
        #expect(!KubeRBAC.ruleAllows(rule, Q(verb: "delete", resource: "pods")))
        #expect(!KubeRBAC.ruleAllows(rule, Q(verb: "get", resource: "secrets")))
        #expect(KubeRBAC.ruleAllows(["verbs": ["*"], "apiGroups": [""], "resources": ["pods"]], Q(verb: "delete", resource: "pods")))
        #expect(KubeRBAC.ruleAllows(["verbs": ["get"], "apiGroups": ["*"], "resources": ["pods"]], Q(verb: "get", resource: "pods", apiGroup: "apps")))
        #expect(KubeRBAC.ruleAllows(["verbs": ["get"], "apiGroups": [""], "resources": ["*"]], Q(verb: "get", resource: "secrets")))
        let named: JSON = ["verbs": ["get"], "apiGroups": [""], "resources": ["secrets"], "resourceNames": ["db-creds"]]
        #expect(KubeRBAC.ruleAllows(named, Q(verb: "get", resource: "secrets", resourceName: "db-creds")))
        #expect(!KubeRBAC.ruleAllows(named, Q(verb: "get", resource: "secrets", resourceName: "other-secret")))
        #expect(KubeRBAC.ruleAllows(named, Q(verb: "get", resource: "secrets")))
        #expect(!KubeRBAC.ruleAllows(["verbs": [], "apiGroups": [""], "resources": ["pods"]], Q(verb: "get", resource: "pods")))
        let role: JSON = ["rules": [["verbs": ["get"], "apiGroups": [""], "resources": ["configmaps"]], ["verbs": ["get", "list"], "apiGroups": [""], "resources": ["pods"]]]]
        #expect(KubeRBAC.roleAllows(role, Q(verb: "list", resource: "pods")) && !KubeRBAC.roleAllows(role, Q(verb: "delete", resource: "pods")))
    }

    static let roles: [JSON] = [["metadata": ["name": "pod-reader", "namespace": "ns1"], "rules": [["verbs": ["get", "list", "watch"], "apiGroups": [""], "resources": ["pods"]]]]]
    static let clusterRoles: [JSON] = [["metadata": ["name": "cluster-admin-ish"], "rules": [["verbs": ["*"], "apiGroups": ["*"], "resources": ["*"]]]]]
    static let roleBindings: [JSON] = [["metadata": ["name": "read-pods", "namespace": "ns1"], "roleRef": ["kind": "Role", "name": "pod-reader"],
                                        "subjects": [["kind": "ServiceAccount", "name": "ci-bot", "namespace": "ns1"]]]]
    static let crbs: [JSON] = [["metadata": ["name": "admins"], "roleRef": ["kind": "ClusterRole", "name": "cluster-admin-ish"], "subjects": [["kind": "Group", "name": "platform-team"]]]]

    @Test func whoCan() {
        func who(_ q: Q, roles: [JSON] = KubeScanTests.roles, rbs: [JSON] = KubeScanTests.roleBindings) -> [JSON] {
            KubeRBAC.whoCan(q, roles: roles, clusterRoles: Self.clusterRoles, roleBindings: rbs, clusterRoleBindings: Self.crbs)
        }
        let sa = who(Q(verb: "get", resource: "pods")).first { $0["subject"]["kind"] == "ServiceAccount" }
        #expect(sa?["subject"] == ["kind": "ServiceAccount", "name": "ci-bot", "namespace": "ns1"])
        #expect(sa?["binding"] == ["kind": "RoleBinding", "name": "read-pods", "namespace": "ns1"])
        #expect(who(Q(verb: "delete", resource: "secrets")).first { $0["subject"]["kind"] == "Group" }?["binding"]["kind"] == "ClusterRoleBinding")
        #expect(who(Q(verb: "delete", resource: "pods")).filter { $0["subject"]["kind"] == "ServiceAccount" }.isEmpty)
        let m = who(Q(verb: "delete", resource: "pods"),
                    roles: Self.roles + [["metadata": ["name": "pod-reader", "namespace": "ns2"], "rules": [["verbs": ["delete"], "apiGroups": [""], "resources": ["pods"]]]]],
                    rbs: Self.roleBindings + [["metadata": ["name": "other", "namespace": "ns2"], "roleRef": ["kind": "Role", "name": "pod-reader"], "subjects": [["kind": "User", "name": "alice"]]]])
        #expect(m.contains { $0["subject"]["name"] == "alice" } && !m.contains { $0["subject"]["name"] == "ci-bot" })
        #expect(KubeRBAC.whoCan(Q(verb: "get", resource: "pods")).isEmpty)
    }

    @Test func relations() {
        let pod: JSON = ["kind": "Pod", "metadata": ["name": "web-57fdfc7498-b925x", "namespace": "default",
                         "ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-57fdfc7498", "controller": true]]]]
        #expect(KubeRelations.relatedOf(pod) == [["kind": "ReplicaSet", "name": "web-57fdfc7498", "namespace": "default", "via": "owner"]])
        let several: JSON = ["kind": "Pod", "metadata": ["name": "x", "namespace": "ns", "ownerReferences": [
            ["kind": "SomeWebhookWatcher", "name": "not-the-controller", "controller": false], ["kind": "ReplicaSet", "name": "the-real-owner", "controller": true]]]]
        #expect(KubeRelations.relatedOf(several)[0] == ["kind": "ReplicaSet", "name": "the-real-owner", "namespace": "ns", "via": "owner"])
        #expect(KubeRelations.relatedOf(["kind": "Pod", "metadata": ["name": "x", "namespace": "ns"]]) == [])
        #expect(KubeRelations.relatedOf(["kind": "PersistentVolumeClaim", "metadata": ["name": "data", "namespace": "ns"], "spec": ["volumeName": "pv-0123"]])
                == [["kind": "PersistentVolume", "name": "pv-0123", "namespace": nil, "via": "volumeName"]])
        #expect(KubeRelations.relatedOf(["kind": "PersistentVolumeClaim", "metadata": ["name": "data", "namespace": "ns"], "spec": [:]]) == [])
        #expect(KubeRelations.relatedOf(["kind": "Service", "metadata": ["name": "web", "namespace": "ns"], "spec": ["selector": ["app": "web"]]])
                == [["kind": "Endpoints", "name": "web", "namespace": "ns", "via": "same name"]])
        #expect(KubeRelations.relatedOf(["kind": "Service", "metadata": ["name": "web", "namespace": "ns", "ownerReferences": [["kind": "Ingress", "name": "web-ingress", "controller": true]]]])
                == [["kind": "Ingress", "name": "web-ingress", "namespace": "ns", "via": "owner"], ["kind": "Endpoints", "name": "web", "namespace": "ns", "via": "same name"]])
        #expect(KubeRelations.relatedOf(.null) == [])
    }
}
