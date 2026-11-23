import Foundation
import Testing
@testable import ServerLife

/// tests/kubemetrics.test.mjs, kubewatch.test.mjs, kubelogs.test.mjs, jsonpath-lite.test.mjs —
/// the pure halves and the guards that run before anything is spawned.
@Suite struct KubeStreamsTests {
    typealias M = KubeMetrics

    @Test func parsing() {
        #expect(M.parseCpu("123m") == 123 && M.parseCpu("5m") == 5 && M.parseCpu("2") == 2000 && M.parseCpu("0.5") == 500)
        #expect(M.parseCpu("<unknown>") == 0 && M.parseCpu(nil) == 0 && M.parseCpu("") == 0)
        #expect(M.parseMemBytes("1Ki") == 1024 && M.parseMemBytes("456Mi") == (456 * pow(1024, 2)).rounded())
        #expect(M.parseMemBytes("1Gi") == pow(1024, 3) && M.parseMemBytes("2Ti") == 2 * pow(1024, 4))
        #expect(M.parseMemBytes("1K") == 1000 && M.parseMemBytes("1M") == 1e6 && M.parseMemBytes("2048") == 2048)
        #expect(M.parseMemBytes("<unknown>") == 0 && M.parseMemBytes(nil) == 0)
        #expect(M.parsePercent("45%") == 45 && M.parsePercent("100%") == 100 && M.parsePercent("45") == 45)
        #expect(M.parsePercent("<unknown>") == 0 && M.parsePercent(nil) == 0)
    }

    @Test func snapshots() {
        let snap = M.snapshotFrom(["nodes": ["ok": true, "items": [["name": "node-1", "cpu": "250m", "cpuPercent": "12%", "memory": "1Gi", "memoryPercent": "40%"]]],
                                   "pods": ["ok": true, "items": [["namespace": "ns", "name": "web-1", "cpu": "5m", "memory": "64Mi"]]]])
        #expect(snap["ok"] == true)
        #expect(snap["nodes"] == [["name": "node-1", "cpuM": 250, "cpuPercent": 12, "memBytes": .number(pow(1024, 3)), "memPercent": 40]])
        #expect(snap["pods"] == [["namespace": "ns", "name": "web-1", "cpuM": 5, "memBytes": .number(64 * pow(1024, 2))]])
        let none = M.snapshotFrom(["nodes": ["ok": false, "items": []], "pods": ["ok": false, "items": []]])
        #expect(none["ok"] == false && none["nodes"] == [] && none["pods"] == [])
        #expect(M.snapshotFrom(["nodes": ["ok": true, "items": []], "pods": ["ok": false, "items": []]])["ok"] == true)
    }

    @Test func splitDocuments() {
        func split(_ s: String) -> ([String], String) { let r = KubeWatch.splitDocuments(s); return (r.complete, r.remainder) }
        #expect(split("kind: Pod\nmetadata:\n  name: a\n") == ([], "kind: Pod\nmetadata:\n  name: a\n"))
        #expect(split("kind: Pod\nmetadata:\n  name: a\n---\nkind: Pod\nmetadata:\n  name: b\n") == (["kind: Pod\nmetadata:\n  name: a"], "kind: Pod\nmetadata:\n  name: b\n"))
        #expect(split("name: a\n---\nname: b\n---\nname: c-still-arri") == (["name: a", "name: b"], "name: c-still-arri"))
        let early = split("kind: Pod\nmetadata:\n  annotations:\n    note: \"see --- section 3\"\n---\nkind: Pod\nmetadata:\n  name: b\n").0
        #expect(early.count == 1 && early[0].contains("see --- section 3"))
        #expect(split("name: a\n---  \r\nname: b\n") == (["name: a"], "name: b\n"))
        #expect(split("") == ([], ""))
    }

    @MainActor @Test func guards() {
        let watchNoId = KubeWatch.shared.start(KubeSpec(), id: "", kind: "pods") { _ in }
        #expect(watchNoId["ok"] == false && (watchNoId["error"].string ?? "").contains("id"))
        let watchNoKind = KubeWatch.shared.start(KubeSpec(), id: "x", kind: nil) { _ in }
        #expect(watchNoKind["ok"] == false && (watchNoKind["error"].string ?? "").contains("kind"))
        #expect(KubeWatch.shared.stop("not-a-real-watch") == false)
        let logsNoId = KubeLogs.shared.start(KubeSpec(), id: "", podName: "web-1") { _ in }
        #expect(logsNoId["ok"] == false && (logsNoId["error"].string ?? "").contains("id"))
        #expect(KubeLogs.shared.stop("not-a-real-session") == false)
        let metricsNoId = M.shared.start(KubeSpec(), id: "") { _ in }
        #expect(metricsNoId["ok"] == false && (metricsNoId["error"].string ?? "").contains("id"))
        #expect(M.shared.stop("not-a-real-poll") == false)
        KubeWatch.shared.stopAll(); KubeLogs.shared.stopAll(); M.shared.stopAll()
    }

    static let certificate: JSON = [
        "status": ["conditions": [["type": "Ready", "status": "True", "message": "Certificate is up to date and has not expired"],
                                  ["type": "Issuing", "status": "False", "message": "Not issuing"]]],
        "spec": ["secretName": "web-tls", "issuerRef": ["name": "letsencrypt-prod"], "containers": [["image": "nginx:1.27"]]],
    ]

    @Test func jsonPath() {
        let c = Self.certificate
        func r(_ p: String, _ o: JSON = Self.certificate) -> JSON? { JSONPathLite.resolve(o, p) }
        #expect(r(".spec.secretName") == "web-tls" && r(".spec.issuerRef.name") == "letsencrypt-prod")
        #expect(r(".spec.containers[0].image") == "nginx:1.27")
        #expect(r(#".status.conditions[?(@.type == "Ready")].status"#) == "True")
        #expect(r(#".status.conditions[?(@.type == "Ready")].message"#) == "Certificate is up to date and has not expired")
        #expect(r(#".status.conditions[?(@.type=="Issuing")].status"#) == "False")
        #expect(r(#".status.conditions[?(@.type != "Ready")].type"#) == "Issuing")
        #expect(r(#".status.conditions[?(@.type == "DoesNotExist")].status"#) == nil)
        #expect(r(#".status.conditions[?(@.type == "Ready")].status"#, [:]) == nil)
        #expect(r(".spec.nope.alsoNope") == nil)
        #expect(r("{.spec.secretName}") == "web-tls")
        #expect(r("spec.secretName", c) == r(".spec.secretName", c))
    }
}
