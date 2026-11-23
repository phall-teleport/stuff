import Foundation
import Testing
@testable import ServerLife

/// tests/kubeexport.test.mjs (+ kubebin's humanizeKubectlError) and kubehelm.test.mjs.
@Suite struct KubeExportTests {
    static func y(_ s: String) -> YAMLValue { try! KubeYAML.orderedJSON(s) }
    static func j(_ v: YAMLValue) -> JSON { try! JSON.parse(kubeOrderedJSONText(v, indent: 0)) }

    static let deployment = y(#"""
    {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"web","namespace":"apps","uid":"u-1","resourceVersion":"42","generation":3,
     "creationTimestamp":"2026-11-01T00:00:00Z","managedFields":[{"manager":"kubectl"}],"labels":{"app":"web"},
     "annotations":{"kubectl.kubernetes.io/last-applied-configuration":"{}","deployment.kubernetes.io/revision":"3","team":"se"},
     "ownerReferences":[{"kind":"X","name":"x","uid":"o"}]},"spec":{"replicas":2},"status":{"readyReplicas":2}}
    """#)
    static let service = y(#"{"apiVersion":"v1","kind":"Service","metadata":{"name":"web","namespace":"apps"},"spec":{"type":"ClusterIP","clusterIP":"10.0.0.1","clusterIPs":["10.0.0.1"],"ports":[{"port":80,"nodePort":30000}]}}"#)

    @Test func listDocument() throws {
        for format in ["yaml", "json"] {
            let text = KubeExport.toDocument([Self.deployment, Self.service], format: format)
            let doc = format == "json" ? try JSON.parse(text) : try KubeYAML.load(text)
            #expect(doc["apiVersion"] == "v1" && doc["kind"] == "List" && doc["items"].items.count == 2)
            #expect(doc["items"].items.map { [$0["apiVersion"], $0["kind"], $0["metadata"]["name"]] } == [["apps/v1", "Deployment", "web"], ["v1", "Service", "web"]])
        }
        #expect(!KubeExport.toDocument([Self.deployment], format: "yaml").contains("&ref_"))
    }

    @Test func clean() {
        let c = Self.j(KubeExport.cleanObject(Self.deployment))
        #expect(c["status"].isNull)
        for k in ["uid", "resourceVersion", "generation", "creationTimestamp", "managedFields", "ownerReferences"] { #expect(c["metadata"][k].isNull, "\(k)") }
        #expect(c["metadata"]["annotations"] == ["team": "se"])
        #expect(c["metadata"]["labels"] == ["app": "web"])
        #expect(c["spec"]["replicas"] == 2)
        let s = Self.j(KubeExport.cleanObject(Self.service))
        #expect(s["spec"]["clusterIP"].isNull && s["spec"]["clusterIPs"].isNull && s["spec"]["ports"][0]["nodePort"].isNull)
        let np = Self.j(KubeExport.cleanObject(Self.y(#"{"apiVersion":"v1","kind":"Service","metadata":{"name":"web"},"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30000}]}}"#)))
        #expect(np["spec"]["ports"][0]["nodePort"] == 30000)
    }

    @Test func cleanPod() {
        let pod = Self.y(#"""
        {"apiVersion":"v1","kind":"Pod","metadata":{"name":"web-abc12","generateName":"web-","namespace":"apps","ownerReferences":[{"kind":"ReplicaSet","name":"web-7d9","controller":true}]},
         "spec":{"nodeName":"node-a","volumes":[{"name":"data","configMap":{"name":"cfg"}},{"name":"kube-api-access-x7k2p","projected":{"sources":[]}}],
         "containers":[{"name":"web","image":"nginx","volumeMounts":[{"name":"data","mountPath":"/d"},{"name":"kube-api-access-x7k2p","mountPath":"/var/run/secrets/kubernetes.io/serviceaccount"}]}],
         "ephemeralContainers":[{"name":"debugger","image":"busybox"}]}}
        """#)
        let c = Self.j(KubeExport.cleanObject(pod))
        #expect(c["spec"]["nodeName"].isNull && c["spec"]["ephemeralContainers"].isNull && c["metadata"]["generateName"].isNull)
        #expect(c["spec"]["volumes"].items.map { $0["name"] } == ["data"])
        #expect(c["spec"]["containers"][0]["volumeMounts"].items.map { $0["name"] } == ["data"])
        let own = Self.j(KubeExport.cleanObject(Self.y(#"{"kind":"Pod","metadata":{"name":"p"},"spec":{"volumes":[{"name":"kube-api-access-mine","secret":{"secretName":"s"}}]}}"#)))
        #expect(own["spec"]["volumes"].items.map { $0["name"] } == ["kube-api-access-mine"])
        #expect(KubeExport.controllerOf(pod) == "ReplicaSet/web-7d9")
        #expect(KubeExport.controllerOf(Self.y(#"{"metadata":{}}"#)) == nil)
    }

    @Test func refusals() async {
        #expect(await !KubeExport.exportResources(KubeSpec(), kind: "pods", format: "xml")["ok"].truthy)
        #expect(await !KubeExport.exportResources(KubeSpec(), kind: nil, format: "yaml")["ok"].truthy)
    }

    @Test func humanize() {
        let panic = "E1109 15:24:13.075244 72452 memcache.go:265] \"Unhandled Error\" err=\"couldn't get current server API group list: unknown\"\npanic: runtime error: index out of range [0] with length 0\ngoroutine 1 [running]:\nk8s.io/kubectl/pkg/cmd/apiresources.(*APIResourceOptions).RunAPIResources(0x1400095e180)"
        #expect(KubeBin.humanizeKubectlError(panic) == KubeBin.noAccess)
        #expect(KubeBin.humanizeKubectlError("Error from server (Forbidden): unknown") == KubeBin.noAccess)
        #expect(KubeBin.humanizeKubectlError("Error from server (Forbidden): pods is forbidden: User \"x\" cannot list resource \"pods\" in API group \"\" in the namespace \"kube-system\"")
                == "Not allowed: your role can't list pods in kube-system.")
        #expect(KubeBin.humanizeKubectlError("Error from server (Forbidden): nodes is forbidden: User \"x\" cannot list resource \"nodes\" in API group \"\" at the cluster scope")
                == "Not allowed: your role can't list nodes.")
        #expect(KubeBin.humanizeKubectlError("E1109 1 memcache.go:265] x\nUnable to connect to the server: dial tcp 127.0.0.1:52596: connect: connection refused").hasPrefix("Can't reach the cluster"))
        #expect(KubeBin.humanizeKubectlError("Error from server (NotFound): pods \"web-1\" not found") == "NotFound: pods \"web-1\" not found")
        #expect(KubeBin.humanizeKubectlError("error: the server doesn't have a resource type \"widgets\"") == "the server doesn't have a resource type \"widgets\"")
        let r = KubeBin.explainMissing(KubeRun(ok: false, stderr: "Error from server (Forbidden): unknown", code: 1))
        #expect(r.noAccess && r.rawStderr == "Error from server (Forbidden): unknown")
        #expect(KubeBin.explainMissing(KubeRun(ok: true, stdout: "x")).stdout == "x")
    }

    static let mysql = kj(#"""
    {"$schema":"http://json-schema.org/schema#","type":"object","properties":{
     "architecture":{"type":"string","title":"MySQL architecture","form":true,"description":"Allowed values: `standalone` or `replication`","enum":["standalone","replication"]},
     "auth":{"type":"object","title":"Authentication configuration","form":true,"properties":{"rootPassword":{"type":"string","title":"MySQL root password"},"username":{"type":"string","title":"MySQL custom username"}}},
     "primary":{"type":"object","title":"Primary database configuration","form":true,"properties":{
       "podSecurityContext":{"type":"object","title":"Pod security context","properties":{"enabled":{"type":"boolean","default":false},"fsGroup":{"type":"integer","default":1001}}},
       "extraVolumes":{"type":"array","title":"Extra volumes"}}}}}
    """#)

    @Test func helmSchemaFields() {
        let f = KubeHelm.fieldsFromSchema(Self.mysql)
        let by = Dictionary(f.map { ($0["path"].string ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        #expect(by["architecture"]?["type"] == "string" && by["architecture"]?["title"] == "MySQL architecture")
        #expect(by["architecture"]?["enum"] == ["standalone", "replication"])
        #expect(by["auth.rootPassword"]?["type"] == "string" && by["auth.username"]?["title"] == "MySQL custom username")
        #expect(by["primary.podSecurityContext.enabled"]?["default"] == false)
        #expect(by["primary.podSecurityContext.fsGroup"]?["default"] == 1001)
        #expect(by["primary.extraVolumes"]?["type"] == "array")
        #expect(!f.contains { ($0["path"].string ?? "").hasPrefix("primary.extraVolumes.") })
        let two = KubeHelm.fieldsFromSchema(Self.mysql, maxDepth: 2)
        #expect(two.contains { $0["path"] == "primary.podSecurityContext" && $0["type"] == "object" })
        #expect(!two.contains { $0["path"] == "primary.podSecurityContext.enabled" })
        #expect(KubeHelm.fieldsFromSchema([:]).isEmpty && KubeHelm.fieldsFromSchema(.null).isEmpty)
    }
}
