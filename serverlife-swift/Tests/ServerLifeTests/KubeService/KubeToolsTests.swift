import Foundation
import Testing
@testable import ServerLife

/// tests/kubebin.test.mjs, kubeexplain.test.mjs, kubefs.test.mjs,
/// kubekustomize.test.mjs, kubelint.test.mjs.
@Suite struct KubeToolsTests {
    @Test func kubectlVersion() {
        let banner = "Client Version: v1.34.1\nKustomize Version: v5.7.1"
        #expect(KubeBin.parseKubectlVersion(banner) == ["raw": .string(banner), "major": 1, "minor": 34, "patch": 1])
        #expect(KubeBin.parseKubectlVersion("something unexpected v1.2.3 trailing")
                == ["raw": "something unexpected v1.2.3 trailing", "major": 1, "minor": 2, "patch": 3])
        #expect(KubeBin.parseKubectlVersion("")["major"].isNull)
        #expect(KubeBin.parseKubectlVersion("not kubectl at all")["major"].isNull)
        for name in ["helm", "k9s", "stern", "kubectx", "kubens", "kind", "k3d", "minikube", "kustomize"] { #expect(KubeBin.ecosystemTools.contains(name)) }
    }

    static let pod = "KIND:       Pod\nVERSION:    v1\n\nDESCRIPTION:\n    Pod is a collection of containers that can run on a host.\n\nFIELDS:\n"
        + "  apiVersion\t<string>\n  kind\t<string>\n  metadata\t<ObjectMeta>\n    annotations\t<map[string]string>\n"
        + "    managedFields\t<[]ManagedFieldsEntry>\n      apiVersion\t<string>\n      manager\t<string>\n    name\t<string>\n"
        + "  spec\t<PodSpec>\n    containers\t<[]Container> -required-\n      image\t<string>\n      name\t<string> -required-\n"
        + "    nodeSelector\t<map[string]string>\n"

    @Test func explain() async {
        let f = KubeExplain.parseExplainFields(Self.pod)
        let by = Dictionary(f.map { ($0["path"].string ?? "", $0["type"].string ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(by["apiVersion"] == "string" && by["metadata.annotations"] == "map[string]string")
        #expect(by["metadata.managedFields.apiVersion"] == "string" && by["metadata.managedFields.manager"] == "string")
        #expect(by["metadata.name"] == "string" && by["spec.containers.image"] == "string" && by["spec.nodeSelector"] == "map[string]string")
        #expect(by["spec.containers.nodeSelector"] == nil)
        let withEnum = Self.pod.replacingOccurrences(of: "name\t<string> -required-", with: "name\t<string> -required-\n      enum: A, B, C....")
        #expect(!KubeExplain.parseExplainFields(withEnum).contains { ($0["path"].string ?? "").contains("enum") })
        #expect(KubeExplain.parseExplainFields("KIND: Pod\nVERSION: v1\n").isEmpty)
        #expect(KubeExplain.parseExplainFields("").isEmpty && KubeExplain.parseExplainFields(nil).isEmpty)
        let r = await KubeExplain.explainFields(KubeSpec(), kind: nil)
        #expect(r["ok"] == false && r["fields"] == [])
    }

    @Test func fsTypes() {
        #expect(KubeFS.parseType("directory") == "directory" && KubeFS.parseType("regular file") == "file")
        #expect(KubeFS.parseType("regular empty file") == "file" && KubeFS.parseType("symbolic link") == "symlink")
        #expect(KubeFS.parseType("") == "file" && KubeFS.parseType("socket") == "file")
    }

    @Test func kustomizeRefuses() async {
        let r = await KubeKustomize.build(KubeSpec(), dir: nil)
        #expect(r["ok"] == false && (r["error"].string ?? "").lowercased().contains("directory"))
    }

    @Test func popeyeArgs() {
        var s = KubeSpec(); s.contextName = "my-ctx"
        #expect(KubeLint.buildArgs(s, namespace: "ns1", logFile: "/tmp/log") == ["--context", "my-ctx", "-n", "ns1", "-o", "json", "--logs", "/tmp/log"])
        #expect(KubeLint.buildArgs(s, logFile: "/tmp/log") == ["--context", "my-ctx", "-A", "-o", "json", "--logs", "/tmp/log"])
        #expect(KubeLint.buildArgs(KubeSpec(), namespace: "ns1", logFile: "/tmp/log") == ["-n", "ns1", "-o", "json", "--logs", "/tmp/log"])
        let a = KubeLint.buildArgs(KubeSpec(), logFile: "/tmp/popeye-xyz.log")
        #expect(a.firstIndex(of: "--logs").map { a[$0 + 1] } == "/tmp/popeye-xyz.log")
    }
}
