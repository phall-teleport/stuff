import Foundation

/// kubetest.js — "Does this Role actually work?" for a ServiceAccount, tested
/// from inside the cluster as that ServiceAccount: a short-lived pod asks
/// `SelfSubjectAccessReview` with its own mounted token (not `--as`, which
/// needs the Teleport role to permit impersonation). `nicolaka/netshoot` has curl.
enum KubeTest {
    struct Check: Equatable { var verb: String; var resource: String; var namespace: String? }

    /// A POSIX single-quoted shell literal.
    static func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// One curl per check, each after a `CHECK verb resource` marker line.
    static func buildSelfCheckScript(_ checks: [Check]) -> String {
        let lines = checks.map { c -> String in
            let body = kubeOrderedJSONText(.map([
                ("apiVersion", .string("authorization.k8s.io/v1")), ("kind", .string("SelfSubjectAccessReview")),
                ("spec", .map([("resourceAttributes", .map([("verb", .string(c.verb)), ("resource", .string(c.resource)),
                                                            ("namespace", .string(c.namespace ?? ""))]))])),
            ]), indent: 0)
            return [
                "echo \(shQuote("CHECK " + c.verb + " " + c.resource))",
                "curl -sk --cacert \"$CACERT\" -H \"Authorization: Bearer $TOKEN\" -H \"Content-Type: application/json\" "
                    + "-X POST \"$API/apis/authorization.k8s.io/v1/selfsubjectaccessreviews\" -d \(shQuote(body))",
                "echo",
            ].joined(separator: "\n")
        }
        return ([
            "TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)",
            "CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
            "API=https://kubernetes.default.svc",
        ] + lines).joined(separator: "\n")
    }

    struct Result: Equatable { var verb: String; var resource: String; var allowed: Bool?; var error: String? }

    /// The script's stdout → one result per check.
    static func parseCheckResults(_ output: String?, _ checks: [Check]) -> [Result] {
        var results = checks.map { Result(verb: $0.verb, resource: $0.resource, allowed: nil, error: nil) }
        var current: Int?
        for line in (output ?? "").components(separatedBy: "\n") {
            if let m = TPText.match(#"^CHECK (\S+) (\S+)$"#, line) {
                current = results.firstIndex { $0.allowed == nil && $0.verb == m[1] && $0.resource == m[2] }
                continue
            }
            guard let i = current else { continue }
            if let a = TPText.match(#""allowed"\s*:\s*(true|false)"#, line) { results[i].allowed = a[1] == "true"; continue }
            if let r = TPText.match(#""message"\s*:\s*"([^"]*)""#, line), results[i].allowed == nil { results[i].error = r[1] }
        }
        return results
    }

    static func resultJSON(_ r: Result) -> JSON {
        ["verb": .string(r.verb), "resource": .string(r.resource), "allowed": r.allowed.map { .bool($0) } ?? .null,
         "error": r.error.map { .string($0) } ?? .null]
    }

    /// Runs the checks for real, then always deletes the pod (awaited).
    /// → `{ok, phase, checks, output}` or `{ok:false, error, output?}`.
    static func testServiceAccountAccess(_ spec: KubeSpec, namespace: String?, serviceAccountName: String?, checks: [Check]) async -> JSON {
        guard let namespace = namespace?.nilIfEmpty, let sa = serviceAccountName?.nilIfEmpty else { return kubeFail("No ServiceAccount to test.") }
        if checks.isEmpty { return kubeFail("Nothing to check — this Role has no rules to sample.") }
        let k = Kube.kubectlArgsFor(spec.with(namespace: namespace))
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let name = "klife-rbac-test-" + String((0..<8).map { _ in alphabet.randomElement()! })
        let doc: JSON = [
            "apiVersion": "v1", "kind": "Pod",
            "metadata": ["name": .string(name), "namespace": .string(namespace), "labels": ["app.kubernetes.io/managed-by": "serverlife-rbac-test"]],
            "spec": ["serviceAccountName": .string(sa), "restartPolicy": "Never",
                     "containers": [["name": "test", "image": "nicolaka/netshoot:latest",
                                     "command": ["/bin/sh", "-c", .string(buildSelfCheckScript(checks))]]]],
        ]
        func kc(_ args: [String], timeout: TimeInterval, stdin: String? = nil) async -> KubeRun {
            await KubeBin.run(k.bin, k.baseArgs + args, env: k.env, timeout: timeout, stdin: stdin, explain: false)
        }
        let applyR = await kc(["apply", "-f", "-"], timeout: 20, stdin: doc.jsText())
        if !applyR.ok { return kubeFail(kubeOr(kubePlain(applyR.stderr), "Could not create the test pod.")) }

        let deadline = Date().addingTimeInterval(30)
        var phase = ""
        while Date() < deadline {
            phase = await kc(["get", "pod", name, "-o", "jsonpath={.status.phase}"], timeout: 5).stdout.trimmed
            if phase == "Succeeded" || phase == "Failed" { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let logs = await kc(["logs", name], timeout: 10).stdout
        // Awaited, even with --wait=false: the delete request must be sent before control returns.
        _ = await kc(["delete", "pod", name, "--ignore-not-found", "--wait=false"], timeout: 15)
        if phase != "Succeeded" && phase != "Failed" {
            return kubeFail("The test pod never finished (last seen: \(phase.nilIfEmpty ?? "not scheduled yet")).", ["output": .string(logs)])
        }
        return kubeOk(["phase": .string(phase), "checks": .array(parseCheckResults(logs, checks).map(resultJSON)), "output": .string(logs)])
    }
}
