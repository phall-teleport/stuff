import Foundation

/// kubeops.js — KubeLife's write actions on workloads: scale, rollout
/// restart/status/history/undo, pause/resume, set image/env/resources, run a
/// CronJob now or suspend it, force-delete, evict, delete several at once —
/// plus the manifests the "create" forms write.
///
/// Each action is one kubectl argv built in one place, so the same function
/// answers "what would this run" (`preview: true` → `{ok, command}`) and runs
/// it (`{ok, output}` / `{ok:false, error}`) — what is shown is what runs.
enum KubeOps {
    static func run(_ bin: String, _ args: [String], env: [String: String?], timeout: TimeInterval = 60, stdin: String? = nil) async -> KubeRun {
        await KubeBin.run(bin, args, env: env, timeout: timeout, stdin: stdin)
    }

    /// `kubectl …` as text to read and copy — the context and namespace spelled out, values on a heredoc.
    static func preview(_ args: [String], env: [String: String?] = [:], stdin: String? = nil) -> String {
        let kc = (env["KUBECONFIG"] ?? nil) ?? ""
        let prefix = kc.isEmpty ? "" : "KUBECONFIG=\(Kube.shellQuote(kc)) "
        let cmd = prefix + (["kubectl"] + args).map(Kube.shellQuote).joined(separator: " ")
        guard let stdin, !stdin.isEmpty else { return cmd }
        return "\(cmd) <<'YAML'\n\(stdin.hasSuffix("\n") ? stdin : stdin + "\n")YAML"
    }

    /// The one shape every action takes: build argv against a spec, then preview or run it.
    static func act(_ spec: KubeSpec, namespace: String?, preview wantPreview: Bool, stdin: String? = nil,
                    timeout: TimeInterval = 60, _ argv: [String]?) async -> JSON {
        let k = Kube.kubectlArgsFor(spec.scoped(namespace: namespace))
        guard let argv else { return kubeFail("Nothing to do.") }
        // baseArgs may begin with "kubectl" itself (the tsh kubectl fallback);
        // the preview always reads as plain kubectl, which is what someone would type.
        let shown = k.baseArgs.first == "kubectl" ? Array(k.baseArgs.dropFirst()) : k.baseArgs
        if wantPreview { return kubeOk(["command": .string(preview(shown + argv, env: k.env, stdin: stdin))]) }
        let r = await run(k.bin, k.baseArgs + argv, env: k.env, timeout: timeout, stdin: stdin)
        if r.ok { return kubeOk(["output": .string(kubeOr(kubePlain(r.stdout), kubePlain(r.stderr)))]) }
        return kubeFail(kubeOr(kubeOr(kubePlain(r.stderr), kubePlain(r.stdout)), "kubectl failed"))
    }

    static func ref(_ resource: String?, _ name: String?) -> String { "\((resource ?? "").lowercased())/\(name ?? "")" }
    static let dnsLabel = #"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$"#

    /// `kubectl scale --replicas=N`.
    static func scale(_ spec: KubeSpec, resource: String?, name: String?, namespace: String?, replicas: JSON, preview p: Bool = false) async -> JSON {
        let n = kubeJSNumber(replicas)
        guard n.isFinite, n == n.rounded(), n >= 0 else { return kubeFail("Replicas must be a whole number, 0 or more.") }
        return await act(spec, namespace: namespace, preview: p, ["scale", ref(resource, name), "--replicas=\(Int(n))"])
    }

    static let rolloutActions = ["restart", "status", "history", "undo", "pause", "resume"]

    /// `kubectl rollout <action>` — undo can name the revision to go back to.
    static func rollout(_ spec: KubeSpec, action: String, resource: String?, name: String?, namespace: String?,
                        revision: String? = nil, preview p: Bool = false) async -> JSON {
        guard rolloutActions.contains(action) else { return kubeFail("Unknown rollout action \"\(action)\".") }
        var a = ["rollout", action, ref(resource, name)]
        // status waits for the rollout by default; a dialog wants the answer now.
        if action == "status" { a.append("--watch=false") }
        if action == "undo", let r = revision?.nilIfEmpty { a.append("--to-revision=\(r)") }
        return await act(spec, namespace: namespace, preview: p, timeout: action == "status" ? 20 : 60, a)
    }

    /// `kubectl rollout history` with each revision's change cause, parsed for a picker.
    static func rolloutHistory(_ spec: KubeSpec, resource: String?, name: String?, namespace: String?) async -> JSON {
        var r = await rollout(spec, action: "history", resource: resource, name: name, namespace: namespace)
        guard r["ok"].truthy else { r["revisions"] = []; return r }
        let output = r["output"].string ?? ""
        return kubeOk(["revisions": .array(parseRolloutHistory(output)), "output": .string(output)])
    }

    static func parseRolloutHistory(_ output: String) -> [JSON] {
        output.components(separatedBy: "\n").dropFirst().compactMap { l -> JSON? in
            guard let m = TPText.match(#"^\s*(\d+)\s+(.*)$"#, l), let n = m[1], let rev = Double(n) else { return nil }
            let cause = (m[2] ?? "").trimmed
            return ["revision": .number(rev), "cause": .string(cause == "<none>" ? "" : cause)]
        }
    }

    /// `kubectl set image <ref> <container>=<image>`.
    static func setImage(_ spec: KubeSpec, resource: String?, name: String?, namespace: String?, container: String?, image: String?,
                         preview p: Bool = false) async -> JSON {
        guard let c = container?.nilIfEmpty, let i = image?.nilIfEmpty else { return kubeFail("Pick a container and give an image.") }
        return await act(spec, namespace: namespace, preview: p, ["set", "image", ref(resource, name), "\(c)=\(i)"])
    }

    /// `kubectl set env` — `set` is NAME → value pairs, `unset` names to remove (NAME-).
    static func setEnv(_ spec: KubeSpec, resource: String?, name: String?, namespace: String?, container: String? = nil,
                       set: [(String, String)] = [], unset: [String] = [], preview p: Bool = false) async -> JSON {
        let pairs = set.filter { !$0.0.isEmpty }.map { "\($0.0)=\($0.1)" }
        let gone = unset.filter { !$0.isEmpty }.map { "\($0)-" }
        if pairs.isEmpty && gone.isEmpty { return kubeFail("No variables to set or remove.") }
        let c = container?.nilIfEmpty.map { ["--containers=\($0)"] } ?? []
        return await act(spec, namespace: namespace, preview: p, ["set", "env", ref(resource, name)] + c + pairs + gone)
    }

    /// `kubectl set resources` — requests/limits as `cpu=…,memory=…`.
    static func setResources(_ spec: KubeSpec, resource: String?, name: String?, namespace: String?, container: String? = nil,
                             requests: String = "", limits: String = "", preview p: Bool = false) async -> JSON {
        if requests.isEmpty && limits.isEmpty { return kubeFail("Give requests, limits, or both.") }
        let c = container?.nilIfEmpty.map { ["--containers=\($0)"] } ?? []
        return await act(spec, namespace: namespace, preview: p, ["set", "resources", ref(resource, name)] + c
            + (requests.isEmpty ? [] : ["--requests=\(requests)"]) + (limits.isEmpty ? [] : ["--limits=\(limits)"]))
    }

    /// What a workload's containers are now — the image, env and resources dialogs start from it.
    static func containersOf(_ spec: KubeSpec, resource: String?, name: String?, namespace: String?) async -> JSON {
        let k = Kube.kubectlArgsFor(spec.scoped(namespace: namespace))
        let r = await run(k.bin, k.baseArgs + ["get", ref(resource, name), "-o", "json"], env: k.env, timeout: 20)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl get failed"), ["containers": []]) }
        guard let d = try? JSON.parse(r.stdout), d.object != nil else { return kubeFail("Unexpected output from kubectl", ["containers": []]) }
        return kubeOk(containersFrom(d))
    }

    /// The pure half of containersOf.
    static func containersFrom(_ d: JSON) -> [String: JSON] {
        let kind = d["kind"].string
        let podSpec = kind == "Pod" ? d["spec"] : kind == "CronJob" ? d["spec"]["jobTemplate"]["spec"]["template"]["spec"] : d["spec"]["template"]["spec"]
        let containers: [JSON] = podSpec["containers"].items.map { c in
            let env = c["env"].items
            return ["name": c["name"], "image": .string(c["image"].string ?? ""),
                    "env": .array(env.filter { $0.object?["value"] != nil }.map { ["name": $0["name"], "value": $0["value"]] }),
                    "envFrom": .array(env.filter { $0["valueFrom"].truthy }.map { $0["name"] }),
                    "requests": c["resources"]["requests"].truthy ? c["resources"]["requests"] : [:],
                    "limits": c["resources"]["limits"].truthy ? c["resources"]["limits"] : [:]]
        }
        var o: [String: JSON] = ["containers": .array(containers), "paused": .bool(d["spec"]["paused"].truthy),
                                 "suspend": .bool(d["spec"]["suspend"].truthy)]
        if let r = d["spec"].object?["replicas"] { o["replicas"] = r }
        return o
    }

    /// Run a CronJob now: `kubectl create job --from=cronjob/<name> <name>-manual-<time>`.
    static func cronTrigger(_ spec: KubeSpec, name: String, namespace: String?, jobName: String? = nil, preview p: Bool = false) async -> JSON {
        let job = jobName?.nilIfEmpty ?? defaultJobName(name)
        guard TPText.test(dnsLabel, job) else { return kubeFail("\"\(job)\" is not a valid job name.") }
        return await act(spec, namespace: namespace, preview: p, ["create", "job", job, "--from=cronjob/\(name)"])
    }

    static func defaultJobName(_ name: String, now: Double = nowMs()) -> String {
        var s = String("\(name)-manual-\(Int((now / 1000).rounded(.down)))".prefix(63))
        while s.hasSuffix("-") { s.removeLast() }
        return s
    }

    /// Suspend or resume a CronJob's schedule.
    static func cronSuspend(_ spec: KubeSpec, name: String, namespace: String?, suspend: Bool = true, preview p: Bool = false) async -> JSON {
        await act(spec, namespace: namespace, preview: p, ["patch", "cronjob", name, "--type=merge", "-p", "{\"spec\":{\"suspend\":\(suspend)}}"])
    }

    /// Delete one or several, of one kind, in one call. `force` is the stuck-pod
    /// case — `--grace-period=0 --force` — and is only offered for pods.
    static func deleteMany(_ spec: KubeSpec, resource: String, namespace: String?, names: [String], force: Bool = false, preview p: Bool = false) async -> JSON {
        let list = names.filter { !$0.isEmpty }
        if list.isEmpty { return kubeFail("Nothing selected.") }
        return await act(spec, namespace: namespace, preview: p, timeout: 120,
                         ["delete", resource.lowercased()] + list + (force ? ["--grace-period=0", "--force"] : ["--wait=false"]))
    }

    /// Evict a pod through the Eviction API — what drain does, so a PodDisruptionBudget is respected.
    static func evict(_ spec: KubeSpec, name: String, namespace: String, preview p: Bool = false) async -> JSON {
        // JSON.stringify's key order: apiVersion, kind, metadata{name, namespace}.
        let text = "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\(JSON.string(name).jsText()),\"namespace\":\(JSON.string(namespace).jsText())}}"
        return await act(spec, namespace: namespace, preview: p, stdin: text,
                         ["create", "--raw", "/api/v1/namespaces/\(namespace)/pods/\(name)/eviction", "-f", "-"])
    }
}

/// JavaScript `Number(x)` for a form value: "" → 0, junk → NaN, missing → NaN.
func kubeJSNumber(_ v: JSON) -> Double {
    switch v {
    case .number(let n): return n
    case .bool(let b): return b ? 1 : 0
    case .string(let s):
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 0 }
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return Int(t.dropFirst(2), radix: 16).map(Double.init) ?? .nan }
        if t == "Infinity" || t == "+Infinity" { return .infinity }
        if t == "-Infinity" { return -.infinity }
        if t.lowercased().contains("inf") || t.lowercased().contains("nan") { return .nan }
        return Double(t) ?? .nan
    default: return .nan
    }
}

/// A JS number as YAML: integral → int.
func kubeYNum(_ d: Double) -> YAMLValue {
    d == d.rounded() && abs(d) < 9e15 ? .int(Int(d)) : .double(d)
}
