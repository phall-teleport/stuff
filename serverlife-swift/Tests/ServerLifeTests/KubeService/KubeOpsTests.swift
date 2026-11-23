import Foundation
import Testing
@testable import ServerLife

/// tests/kubeops.test.mjs — validation and manifest generation, no cluster.
@Suite struct KubeOpsTests {
    let spec = KubeSpec()

    @Test func refusals() async {
        for r: JSON in ["three", -1, 1.5] {
            #expect(await !KubeOps.scale(spec, resource: "deployments", name: "x", namespace: nil, replicas: r)["ok"].truthy)
        }
        let r = await KubeOps.rollout(spec, action: "cancel", resource: "deployments", name: "x", namespace: nil)
        #expect(!r["ok"].truthy && (r["error"].string ?? "").contains("Unknown rollout action"))
        #expect(await !KubeOps.setImage(spec, resource: "deployments", name: "x", namespace: nil, container: "app", image: nil)["ok"].truthy)
        #expect(await !KubeOps.setImage(spec, resource: "deployments", name: "x", namespace: nil, container: nil, image: "nginx")["ok"].truthy)
        let e = await KubeOps.setEnv(spec, resource: "deployments", name: "x", namespace: nil)
        #expect(!e["ok"].truthy && (e["error"].string ?? "").contains("No variables"))
        #expect(await !KubeOps.setResources(spec, resource: "deployments", name: "x", namespace: nil)["ok"].truthy)
        let c = await KubeOps.cronTrigger(spec, name: "nightly", namespace: nil, jobName: "Not Valid!")
        #expect(!c["ok"].truthy && (c["error"].string ?? "").contains("not a valid job name"))
        let d = await KubeOps.deleteMany(spec, resource: "pods", namespace: nil, names: [])
        #expect(!d["ok"].truthy && (d["error"].string ?? "").contains("Nothing selected"))
    }

    static func doc(_ r: JSON) -> JSON { (try? KubeYAML.load(r["yaml"].string ?? "")) ?? .null }

    @Test func deployment() {
        let r = KubeOps.manifestFor("Deployment", ["name": "web", "namespace": "ns1", "image": "nginx:1.27", "replicas": "3", "port": "8080", "env": "LOG_LEVEL=debug"])
        #expect(r["ok"].truthy)
        let d = Self.doc(r), c = d["spec"]["template"]["spec"]["containers"][0]
        #expect(d["kind"].string == "Deployment")
        #expect(d["spec"]["replicas"] == 3)
        #expect(c["image"].string == "nginx:1.27")
        #expect(c["ports"][0]["containerPort"] == 8080)
        #expect(c["env"] == [["name": "LOG_LEVEL", "value": "debug"]])
        let n = KubeOps.manifestFor("Deployment", ["name": "web"])
        #expect(!n["ok"].truthy && (n["error"].string ?? "").contains("needs an image"))
        #expect(!KubeOps.manifestFor("ConfigMap", ["name": "Not Valid", "data": "a=b"])["ok"].truthy)
        #expect(!KubeOps.manifestFor("Pod", ["name": "x"])["ok"].truthy)
    }

    @Test func serviceConfigSecret() {
        let s = KubeOps.manifestFor("Service", ["name": "web", "port": "80"])
        #expect(s["ok"].truthy)
        #expect(Self.doc(s)["spec"]["selector"] == ["app": "web"])
        #expect(Self.doc(s)["spec"]["ports"][0]["targetPort"] == 80)
        let c = KubeOps.manifestFor("ConfigMap", ["name": "cfg", "data": "A=1\nB=2"])
        #expect(Self.doc(c)["data"] == ["A": "1", "B": "2"])
        let x = KubeOps.manifestFor("Secret", ["name": "creds", "data": "PASSWORD=hunter2"])
        #expect(Self.doc(x)["stringData"] == ["PASSWORD": "hunter2"])
        #expect(Self.doc(x)["data"].isNull)
    }

    @Test func rules() {
        #expect(KubeOps.parseRules("get,list,watch | | pods,pods/log") == [.init(verbs: ["get", "list", "watch"], apiGroups: [""], resources: ["pods", "pods/log"])])
        #expect(KubeOps.parseRules("get | | pods")[0].apiGroups == [""])
        #expect(KubeOps.parseRules("get,list | apps, | deployments,pods")[0].apiGroups == ["apps", ""])
        let r = KubeOps.parseRules("get | | pods\ncreate,get | | pods/exec\n   \nnoverbshere | | ")
        #expect(r.count == 2 && r[1].resources == ["pods/exec"])
    }

    @Test func subjects() {
        #expect(KubeOps.parseSubjects("User:alice\nGroup:devs", fallbackNamespace: "ns1") == [.init(kind: "User", name: "alice"), .init(kind: "Group", name: "devs")])
        #expect(KubeOps.parseSubjects("bare-name", fallbackNamespace: "ns1") == [.init(kind: "User", name: "bare-name")])
        #expect(KubeOps.parseSubjects("ServiceAccount:ci-bot:other-ns", fallbackNamespace: "ns1") == [.init(kind: "ServiceAccount", name: "ci-bot", namespace: "other-ns")])
        #expect(KubeOps.parseSubjects("ServiceAccount:ci-bot", fallbackNamespace: "ns1") == [.init(kind: "ServiceAccount", name: "ci-bot", namespace: "ns1")])
    }

    @Test func rbacManifests() {
        let role = Self.doc(KubeOps.manifestFor("Role", ["name": "pod-reader", "namespace": "ns1", "rules": "get,list,watch | | pods"]))
        #expect(role["kind"].string == "Role" && role["metadata"]["namespace"].string == "ns1")
        #expect(role["rules"] == [["verbs": ["get", "list", "watch"], "apiGroups": [""], "resources": ["pods"]]])
        let cr = KubeOps.manifestFor("ClusterRole", ["name": "viewer", "rules": "get | | pods"])
        #expect(cr["ok"].truthy && Self.doc(cr)["kind"].string == "ClusterRole" && Self.doc(cr)["metadata"]["namespace"].isNull)
        #expect(!KubeOps.manifestFor("Role", ["name": "empty", "rules": ""])["ok"].truthy)
        let rb = Self.doc(KubeOps.manifestFor("RoleBinding", ["name": "read-pods", "namespace": "ns1", "roleRefKind": "Role", "roleRefName": "pod-reader", "subjects": "ServiceAccount:ci-bot"]))
        #expect(rb["roleRef"] == ["apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "pod-reader"])
        #expect(rb["subjects"] == [["kind": "ServiceAccount", "name": "ci-bot", "namespace": "ns1"]])
        #expect(!KubeOps.manifestFor("RoleBinding", ["name": "x", "namespace": "ns1", "subjects": "User:alice"])["ok"].truthy)
        #expect(!KubeOps.manifestFor("RoleBinding", ["name": "x", "namespace": "ns1", "roleRefName": "y", "subjects": ""])["ok"].truthy)
        #expect(!KubeOps.manifestFor("ClusterRoleBinding", ["name": "x", "roleRefKind": "Role", "roleRefName": "y", "subjects": "User:alice"])["ok"].truthy)
        let crb = KubeOps.manifestFor("ClusterRoleBinding", ["name": "admins", "roleRefKind": "ClusterRole", "roleRefName": "cluster-admin", "subjects": "Group:platform-team"])
        #expect(crb["ok"].truthy && Self.doc(crb)["metadata"]["namespace"].isNull)
        #expect(Self.doc(crb)["roleRef"] == ["apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cluster-admin"])
    }

    /// tests/kubegroupmap.test.mjs — Teleport group → ClusterRole.
    @Test func groupBindings() throws {
        let whole = try KubeYAML.loadAll(KubeOps.groupBinding(group: "viewers", clusterRole: "view")["yaml"].string ?? "")
        #expect(whole.count == 1 && whole[0]["kind"] == "ClusterRoleBinding" && whole[0]["metadata"]["name"] == "teleport-viewers-view")
        #expect(whole[0]["roleRef"] == ["apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "view"])
        #expect(whole[0]["subjects"] == [["apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "viewers"]])
        let some = try KubeYAML.loadAll(KubeOps.groupBinding(group: "developers", clusterRole: "edit", namespaces: ["dev", "staging"])["yaml"].string ?? "")
        #expect(some.map { [$0["kind"], $0["metadata"]["namespace"], $0["roleRef"]["kind"], $0["roleRef"]["name"]] }
                == [["RoleBinding", "dev", "ClusterRole", "edit"], ["RoleBinding", "staging", "ClusterRole", "edit"]])
        #expect(!KubeOps.groupBinding(group: "my devs", clusterRole: "view")["ok"].truthy)
        #expect(!KubeOps.groupBinding(group: nil, clusterRole: "view")["ok"].truthy)
        #expect(!KubeOps.groupBinding(group: "devs", clusterRole: nil)["ok"].truthy)
        let r = KubeOps.teleportRoleFor(group: "developers", clusterLabels: [("env", "dev"), ("teleport.internal/resource-id", "x")], namespaces: ["dev"])
        let role = try KubeYAML.load(r["yaml"].string ?? "")
        #expect(role["kind"] == "role" && role["version"] == "v8")
        #expect(role["spec"]["allow"]["kubernetes_groups"] == ["developers"])
        #expect(role["spec"]["allow"]["kubernetes_labels"] == ["env": "dev"])
        #expect(role["spec"]["allow"]["kubernetes_resources"].items.map { $0["namespace"] } == ["dev"])
        #expect(r["broadLabels"] == false)
        let broad = KubeOps.teleportRoleFor(group: "viewers")
        #expect(try KubeYAML.load(broad["yaml"].string ?? "")["spec"]["allow"]["kubernetes_labels"] == ["*": "*"])
        #expect(broad["broadLabels"] == true)
    }
}
