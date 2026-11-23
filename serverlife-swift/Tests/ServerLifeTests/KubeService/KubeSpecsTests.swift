import Foundation
import Testing
@testable import ServerLife

/// tests/kube.test.mjs and kubecontexts.test.mjs — terminal argv shapes and
/// recognising a context tsh created. Only the tail from the kubectl
/// subcommand is checked (the leading plumbing depends on what is installed).
@Suite struct KubeSpecsTests {
    static func spec(_ f: (inout KubeSpec) -> Void) -> KubeSpec { var s = KubeSpec(); f(&s); return s }
    static func tail(_ args: [String], _ token: String) -> [String] {
        guard let i = args.firstIndex(of: token) else { return ["<\(token) missing>"] + args }
        return Array(args[i...])
    }

    @Test func attach() {
        #expect(Self.tail(Kube.attachSpec(Self.spec { $0.podName = "web-1"; $0.containerName = "app" }).args, "attach") == ["attach", "web-1", "-c", "app", "-i"])
        let a = Kube.attachSpec(Self.spec { $0.podName = "web-1" }).args
        #expect(Self.tail(a, "attach") == ["attach", "web-1", "-i"])
        #expect(!a.contains("-it") && !a.contains("-t"))
    }

    @Test func debug() throws {
        #expect(throws: (any Error).self) { try Kube.debugSpec(Self.spec { $0.image = "busybox" }) }
        #expect(throws: (any Error).self) { try Kube.debugSpec(Self.spec { $0.podName = "web-1" }) }
        let d = try Kube.debugSpec(Self.spec { $0.podName = "web-1"; $0.containerName = "app"; $0.image = "nicolaka/netshoot:latest" })
        #expect(Self.tail(d.args, "debug") == ["debug", "-it", "web-1", "--image=nicolaka/netshoot:latest", "--target=app", "--", "/bin/sh"])
        let b = try Kube.debugSpec(Self.spec { $0.podName = "web-1"; $0.image = "busybox"; $0.shell = "/bin/bash" })
        #expect(Self.tail(b.args, "debug") == ["debug", "-it", "web-1", "--image=busybox", "--", "/bin/bash"])
        #expect(throws: (any Error).self) { try Kube.nodeDebugSpec(Self.spec { $0.image = "busybox" }) }
        #expect(throws: (any Error).self) { try Kube.nodeDebugSpec(Self.spec { $0.nodeName = "node-1" }) }
        let n = try Kube.nodeDebugSpec(Self.spec { $0.nodeName = "ip-10-0-0-1"; $0.image = "nicolaka/netshoot:latest" })
        #expect(Self.tail(n.args, "debug") == ["debug", "node/ip-10-0-0-1", "-it", "--image=nicolaka/netshoot:latest", "--", "/bin/sh"])
    }

    @Test func logs() throws {
        #expect(throws: (any Error).self) { try Kube.logArgs(KubeSpec()) }
        #expect(throws: (any Error).self) { try Kube.logArgs(Self.spec { $0.podName = "web-1"; $0.selector = "app=web" }) }
        let one = try Kube.logArgs(Self.spec { $0.podName = "web-1"; $0.containerName = "app" }, follow: true, tail: 50)
        #expect(Self.tail(one.args, "logs") == ["logs", "web-1", "-c", "app", "-f", "--tail=50", "--timestamps"])
        let all = try Kube.logArgs(Self.spec { $0.podName = "web-1" }, tail: nil, allContainers: true)
        #expect(Self.tail(all.args, "logs") == ["logs", "web-1", "--all-containers=true", "--prefix", "-f", "--timestamps"])
        let sel = try Kube.logArgs(Self.spec { $0.selector = "app=web" }, tail: 100)
        #expect(Self.tail(sel.args, "logs") == ["logs", "-l", "app=web", "--all-containers=true", "--prefix", "-f", "--tail=100", "--timestamps"])
        let s = try Kube.logSpec(Self.spec { $0.podName = "web-1" }, tail: 10)
        #expect(!s.command.isEmpty)
        #expect(Self.tail(s.args, "logs") == ["logs", "web-1", "-f", "--tail=10", "--timestamps"])
    }

    @Test func teleportOrigin() {
        let u: JSON = ["exec": ["command": "/usr/local/bin/tsh", "args": ["kube", "credentials", "--kube-cluster=dev", "--teleport-cluster=teleport.example.com", "--proxy=teleport.example.com"]]]
        let o = Kube.teleportOriginOf(u)
        #expect(o?.kubeCluster == "dev" && o?.cluster == "teleport.example.com" && o?.proxy == "teleport.example.com")
        #expect(Kube.teleportOriginOf(["exec": ["command": "tsh", "args": ["kube", "credentials", "--kube-cluster=dev", "--teleport-cluster=foo"]]])?.proxy == "foo")
        #expect(Kube.teleportOriginOf(["exec": ["command": "aws", "args": ["--region", "us-west-2", "eks", "get-token", "--cluster-name", "se-na-shared"]]]) == nil)
        #expect(Kube.teleportOriginOf(["exec": ["command": "gke-gcloud-auth-plugin", "args": nil]]) == nil)
        #expect(Kube.teleportOriginOf(["client-certificate": "/x", "client-key": "/y"]) == nil)
        #expect(Kube.teleportOriginOf(.null) == nil)
        #expect(Kube.teleportOriginOf(["exec": ["command": "tsh", "args": ["kube", "credentials"]]]) == nil)
    }
}

/// tests/kubekeys.test.mjs's store.js half: a cluster keyed by its Teleport cluster, then its group.
@Suite struct KubeKeysTests {
    @Test func prefKeys() {
        let g = "tp:prod.example.com:443", old = "kube:tsh:prod.example.com:prod.example.com:dev"
        #expect(KubeKeys.prefKey(["kind": "kube", "id": .string(old), "name": "dev", "groupKey": .string(g), "teleportCluster": "prod"]) == "kube:prod:dev")
        #expect(KubeKeys.prefKey(["kind": "kube", "id": .string(old), "name": "dev", "groupKey": .string(g)]) == "kube:\(g):dev")
        #expect(KubeKeys.prefKey(["kind": "kube", "id": "kube:direct:minikube", "name": "minikube"]) == "kube:direct:minikube")
        #expect(KubeKeys.prefKey(["kind": "node", "id": "x"]) == nil)
    }
}
