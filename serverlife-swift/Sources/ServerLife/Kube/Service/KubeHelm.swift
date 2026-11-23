import Foundation

/// kubehelm.js — Helm release management in the full cluster browser. The
/// context goes through `Kube.helmArgsFor` (Helm's own `--kube-context`).
enum KubeHelm {
    static let missing = "helm was not found on this machine. Install it first (e.g. \"brew install helm\"), then try again."

    static func run(_ args: [String], env: [String: String?], timeout: TimeInterval = 20, stdin: String? = nil) async -> KubeRun {
        guard KubeBin.toolAvailable("helm") else {
            return KubeRun(ok: false, stderr: missing)
        }
        // Feeding stdin ('' when none was given) only where the JS used runWithStdin.
        return KubeRun(await Proc.run(KubeBin.findTool("helm"), args, env: env, stdin: stdin.map { Data($0.utf8) }, timeout: timeout))
    }

    private static func fail(_ r: KubeRun, _ fallback: String, _ extra: [String: JSON] = [:]) -> JSON {
        kubeFail(kubeOr(kubePlain(r.stderr), fallback), extra)
    }
    private static func nsArgs(_ namespace: String?) -> [String] { namespace?.nilIfEmpty.map { ["-n", $0] } ?? ["-A"] }
    private static func parseList(_ s: String) -> [JSON]? {
        guard let d = try? JSON.parse(s.isEmpty ? "[]" : s), case .array(let a) = d else { return nil }
        return a
    }

    /// `helm list [-n ns | -A] -o json` → `{ok, releases:[{name, namespace, chart, appVersion, revision, status, updated}]}`.
    static func listReleases(_ spec: KubeSpec, namespace: String? = nil) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        let r = await run(h.contextArgs + ["list"] + nsArgs(namespace) + ["-o", "json"], env: h.env)
        if !r.ok { return fail(r, "helm list failed", ["releases": []]) }
        guard let data = parseList(r.stdout) else { return kubeFail("Unexpected output from helm", ["releases": []]) }
        let rel: [JSON] = data.map { x in
            let rv = kubeJSNumber(x["revision"])
            return ["name": x["name"], "namespace": x["namespace"], "chart": x["chart"], "appVersion": x["app_version"],
                    "revision": .number(rv.isNaN ? 0 : rv), "status": x["status"], "updated": x["updated"]]
        }
        return kubeOk(["releases": .array(rel)])
    }

    /// `helm history <release> -n ns -o json` — every revision, for a rollback target.
    static func history(_ spec: KubeSpec, release: String, namespace: String) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        let r = await run(h.contextArgs + ["history", release, "-n", namespace, "-o", "json"], env: h.env)
        if !r.ok { return fail(r, "helm history failed", ["revisions": []]) }
        guard let data = parseList(r.stdout) else { return kubeFail("Unexpected output from helm", ["revisions": []]) }
        return kubeOk(["revisions": .array(data.map { x in
            ["revision": x["revision"], "updated": x["updated"], "status": x["status"], "chart": x["chart"], "description": x["description"]]
        })])
    }

    /// `helm get values <release> -n ns -o yaml [--all] [--revision N]`.
    static func getValues(_ spec: KubeSpec, release: String, namespace: String, all: Bool = false, revision: String? = nil) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        var args = h.contextArgs + ["get", "values", release, "-n", namespace, "-o", "yaml"]
        if all { args.append("--all") }
        if let rv = revision?.nilIfEmpty { args += ["--revision", rv] }
        let r = await run(args, env: h.env)
        return r.ok ? kubeOk(["yaml": .string(r.stdout)]) : fail(r, "helm get values failed")
    }

    /// `helm get manifest <release> -n ns` — every object the release rendered and applied.
    static func getManifest(_ spec: KubeSpec, release: String, namespace: String) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        let r = await run(h.contextArgs + ["get", "manifest", release, "-n", namespace], env: h.env)
        return r.ok ? kubeOk(["yaml": .string(r.stdout)]) : fail(r, "helm get manifest failed")
    }

    /// `helm rollback <release> <revision> -n ns`.
    static func rollback(_ spec: KubeSpec, release: String, namespace: String, revision: String) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        let r = await run(h.contextArgs + ["rollback", release, revision, "-n", namespace], env: h.env, timeout: 60)
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))]) : fail(r, "helm rollback failed")
    }

    /// `helm uninstall <release> -n ns` — removes the release and everything it owns.
    static func uninstall(_ spec: KubeSpec, release: String, namespace: String) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        let r = await run(h.contextArgs + ["uninstall", release, "-n", namespace], env: h.env, timeout: 60)
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))]) : fail(r, "helm uninstall failed")
    }

    /// `helm repo add <name> <url>` + `repo update`; "already exists" is success.
    static func addRepo(_ spec: KubeSpec, name: String, url: String) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        let add = await run(h.contextArgs + ["repo", "add", name, url], env: h.env, timeout: 20)
        if !add.ok && !TPText.test("already exists", add.stderr, .caseInsensitive) { return fail(add, "helm repo add failed") }
        let update = await run(h.contextArgs + ["repo", "update", name], env: h.env, timeout: 30)
        return update.ok ? kubeOk() : fail(update, "helm repo update failed")
    }

    /// `helm install <release> <chartRef> -n ns [--create-namespace] [--dry-run] [-f -]`.
    /// `chartRef` is `<repo>/<chart>` or a local chart path. `repo` only shapes the preview.
    static func install(_ spec: KubeSpec, release: String, namespace: String, chartRef: String, valuesYaml: String? = nil,
                        createNamespace: Bool = false, dryRun: Bool = false, preview: Bool = false,
                        repo: (name: String, url: String)? = nil) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        var args = h.contextArgs + ["install", release, chartRef, "-n", namespace]
        if createNamespace { args.append("--create-namespace") }
        if dryRun { args.append("--dry-run") }
        let hasValues = !(valuesYaml ?? "").trimmed.isEmpty
        if hasValues { args += ["-f", "-"] }
        if preview {
            var steps: [(args: [String], stdin: String?)] = []
            if let repo, !repo.name.isEmpty, !repo.url.isEmpty {
                steps = [(h.contextArgs + ["repo", "add", repo.name, repo.url], nil), (h.contextArgs + ["repo", "update", repo.name], nil)]
            }
            steps.append((args, hasValues ? valuesYaml : nil))
            return kubeOk(["command": .string(Kube.commandPreview(steps, env: h.env))])
        }
        let r = await run(args, env: h.env, timeout: 90, stdin: hasValues ? valuesYaml : nil)
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))]) : fail(r, "helm install failed")
    }

    /// A release's `chart` (`<name>-<version>`) split back into the two.
    static func splitChart(_ chart: String?) -> (name: String, version: String) {
        let c = chart ?? ""
        if let m = TPText.match(#"^(.*)-(v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]*)?)$"#, c) { return (m[1] ?? "", m[2] ?? "") }
        return (c, "")
    }

    /// `helm search repo` across the local repos, matched on the chart's own name;
    /// `versionsOf` lists every version of one exact `repo/chart`.
    static func searchCharts(_ spec: KubeSpec, name: String? = nil, versionsOf: String? = nil, refresh: Bool = false) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        if refresh { _ = await run(["repo", "update"], env: h.env, timeout: 60) }
        let args = versionsOf?.nilIfEmpty.map { ["search", "repo", $0, "--versions", "-o", "json"] } ?? ["search", "repo", name ?? "", "-o", "json"]
        let r = await run(args, env: h.env, timeout: 30)
        if !r.ok { return fail(r, "helm search repo failed", ["charts": []]) }
        guard let data = parseList(r.stdout) else { return kubeFail("Unexpected output from helm", ["charts": []]) }
        var charts: [JSON] = data.map { ["ref": $0["name"], "version": $0["version"], "appVersion": $0["app_version"], "description": $0["description"]] }
        if let v = versionsOf?.nilIfEmpty { charts = charts.filter { $0["ref"].string == v } }
        else if let n = name?.nilIfEmpty { charts = charts.filter { ($0["ref"].string ?? "").components(separatedBy: "/").last == n } }
        return kubeOk(["charts": .array(charts)])
    }

    /// `helm upgrade <release> <chart> -n ns [--version V] [--reset-values] [--dry-run] [-f -]`.
    /// The values given are the whole answer, so `--reset-values` by default.
    static func upgrade(_ spec: KubeSpec, release: String, namespace: String, chartRef: String, version: String? = nil,
                        valuesYaml: String? = nil, dryRun: Bool = false, preview: Bool = false, resetValues: Bool = true) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        var args = h.contextArgs + ["upgrade", release, chartRef, "-n", namespace]
        if let v = version?.nilIfEmpty { args += ["--version", v] }
        if resetValues { args.append("--reset-values") }
        if dryRun { args.append("--dry-run") }
        let t = (valuesYaml ?? "").trimmed
        let hasValues = !t.isEmpty && t != "null"
        if hasValues { args += ["-f", "-"] }
        if preview { return kubeOk(["command": .string(Kube.commandPreview([(args, hasValues ? valuesYaml : nil)], env: h.env))]) }
        let r = await run(args, env: h.env, timeout: 120, stdin: hasValues ? valuesYaml : nil)
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))]) : fail(r, "helm upgrade failed")
    }

    /// `helm show readme <chartRef>`.
    static func showReadme(_ spec: KubeSpec, chartRef: String) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        let r = await run(["show", "readme", chartRef], env: h.env, timeout: 30)
        return r.ok ? kubeOk(["text": .string(r.stdout)]) : fail(r, "helm show readme failed")
    }

    /// A chart's own `values.schema.json` (`schema: null` when it has none — most
    /// don't). A repo ref is pulled into a scratch directory, always removed after.
    static func getValuesSchema(_ spec: KubeSpec, chartRef: String, local: Bool = false) async -> JSON {
        func readSchema(_ dir: String) -> JSON {
            let p = (dir as NSString).appendingPathComponent("values.schema.json")
            guard let d = FileManager.default.contents(atPath: p), let s = try? JSON.parse(String(decoding: d, as: UTF8.self)) else { return kubeOk(["schema": .null]) }
            return kubeOk(["schema": s])
        }
        if local { return readSchema(chartRef) }
        let h = Kube.helmArgsFor(spec)
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("serverlife-helm-schema-" + UUID().uuidString.prefix(6))
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = await run(["pull", chartRef, "--untar", "-d", tmp], env: h.env, timeout: 30)
        if !r.ok { return fail(r, "helm pull failed") }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []
        let dir = names.map { (tmp as NSString).appendingPathComponent($0) }.first { p in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }
        guard let dir else { return kubeOk(["schema": .null]) }
        return readSchema(dir)
    }

    /// The schema's nested `properties` flattened into one entry per scalar leaf
    /// (`{path, type, title, description, default, enum}`); arrays are listed, not descended.
    static func fieldsFromSchema(_ schema: JSON, maxDepth: Int = 4) -> [JSON] {
        var fields: [JSON] = []
        func walk(_ props: JSON, _ prefix: String, _ depth: Int) {
            for (key, def) in props.kSortedEntries {
                let p = prefix.isEmpty ? key : "\(prefix).\(key)"
                if def["type"].string == "object" && depth < maxDepth { walk(def["properties"], p, depth + 1); continue }
                var o: [String: JSON] = ["path": .string(p), "type": .string(def["type"].string?.nilIfEmpty ?? "string"),
                                         "title": .string(def["title"].string ?? ""), "description": .string(def["description"].string ?? ""),
                                         "enum": def["enum"].truthy ? def["enum"] : .null]
                if let d = def.object?["default"] { o["default"] = d }
                fields.append(.object(o))
            }
        }
        walk(schema["properties"], "", 1)
        return fields
    }

    /// `helm test <release> -n ns [--logs]` → `{ok, output}`.
    static func test(_ spec: KubeSpec, release: String, namespace: String, logs: Bool = true) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        var args = h.contextArgs + ["test", release, "-n", namespace]
        if logs { args.append("--logs") }
        let r = await run(args, env: h.env, timeout: 120)
        return ["ok": .bool(r.ok), "output": .string(kubeOr(kubePlain(r.ok ? r.stdout : r.stderr), r.ok ? "" : "helm test failed"))]
    }

    /// `helm template <name> <chartRef> [-f -]` — rendered locally; nothing touches the cluster.
    static func renderTemplate(_ spec: KubeSpec, name: String, chartRef: String, valuesYaml: String? = nil) async -> JSON {
        let h = Kube.helmArgsFor(spec)
        var args = h.contextArgs + ["template", name, chartRef]
        let hasValues = !(valuesYaml ?? "").trimmed.isEmpty
        if hasValues { args += ["-f", "-"] }
        let r = await run(args, env: h.env, timeout: 30, stdin: hasValues ? valuesYaml : nil)
        return r.ok ? kubeOk(["yaml": .string(r.stdout)]) : fail(r, "helm template failed")
    }
}
