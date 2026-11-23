import Foundation

/// kubeexport.js — exporting resources as Kubernetes' own JSON or YAML: a
/// `kind: List` of full objects, the same document `kubectl get -o json|yaml`
/// writes, so kubectl, Helm, Kustomize or a GitOps repo read it as is. Only the
/// rows the browser is showing (or has ticked) are kept. `clean` strips what
/// the API server set on its own, ready to apply elsewhere.
///
/// Works on `YAMLValue` (ordered maps), so the file keeps kubectl's key order.
enum KubeExport {
    static let serverMetadata = ["uid", "resourceVersion", "creationTimestamp", "generation", "selfLink", "managedFields",
                                 "deletionTimestamp", "deletionGracePeriodSeconds"]
    static let lastApplied = "kubectl.kubernetes.io/last-applied-configuration"

    /// One object made ready to apply somewhere else.
    static func cleanObject(_ obj: YAMLValue) -> YAMLValue {
        var o = obj
        o.kRemove("status")
        if var md = o.kGet("metadata"), case .map = md {
            for k in serverMetadata { md.kRemove(k) }
            if var ann = md.kGet("annotations"), case .map = ann {
                ann.kRemove(lastApplied)
                ann.kRemove("deployment.kubernetes.io/revision")
                if case .map(let a) = ann, a.isEmpty { md.kRemove("annotations") } else { md.kSet("annotations", ann) }
            }
            // Owned objects belong to their owner by uid — meaningless anywhere else.
            md.kRemove("ownerReferences")
            o.kSet("metadata", md)
        }
        let kind = o.kGet("kind")?.kString
        // Addresses the cluster handed out are its, not the object's.
        if kind == "Service", var spec = o.kGet("spec"), case .map = spec {
            spec.kRemove("clusterIP"); spec.kRemove("clusterIPs")
            let type = spec.kGet("type")?.kString
            if type != "NodePort" && type != "LoadBalancer", case .seq(let ports)? = spec.kGet("ports") {
                spec.kSet("ports", .seq(ports.map { var p = $0; p.kRemove("nodePort"); return p }))
            }
            o.kSet("spec", spec)
        }
        if kind == "PersistentVolumeClaim", var spec = o.kGet("spec"), case .map = spec { spec.kRemove("volumeName"); o.kSet("spec", spec) }
        if kind == "Pod", let spec = o.kGet("spec"), case .map = spec { cleanPodSpec(&o) }
        return o
    }

    /// A running Pod carries where it was scheduled: nodeName, the injected
    /// service-account token volume (kube-api-access-xxxxx) and its mounts,
    /// ephemeralContainers, generateName — all go.
    private static func cleanPodSpec(_ o: inout YAMLValue) {
        guard var spec = o.kGet("spec") else { return }
        spec.kRemove("nodeName"); spec.kRemove("ephemeralContainers")
        if var md = o.kGet("metadata"), case .map = md { md.kRemove("generateName"); o.kSet("metadata", md) }
        let volumes = spec.kGet("volumes")?.kItems ?? []
        let injected = Set(volumes.filter { v in
            TPText.test(#"^kube-api-access-[a-z0-9]{5}$"#, v.kGet("name")?.kString ?? "") && (v.kGet("projected")?.kTruthy ?? false)
        }.compactMap { $0.kGet("name")?.kString })
        if injected.isEmpty { o.kSet("spec", spec); return }
        let kept = volumes.filter { !injected.contains($0.kGet("name")?.kString ?? "") }
        if kept.isEmpty { spec.kRemove("volumes") } else { spec.kSet("volumes", .seq(kept)) }
        for key in ["containers", "initContainers"] {
            guard case .seq(let cs)? = spec.kGet(key) else { continue }
            spec.kSet(key, .seq(cs.map { c in
                var c = c
                guard let mounts = c.kGet("volumeMounts") else { return c }
                let m = mounts.kItems.filter { !injected.contains($0.kGet("name")?.kString ?? "") }
                if m.isEmpty { c.kRemove("volumeMounts") } else { c.kSet("volumeMounts", .seq(m)) }
                return c
            }))
        }
        o.kSet("spec", spec)
    }

    /// What owns this object — a Pod's ReplicaSet, StatefulSet, DaemonSet or Job — as `Kind/name`.
    static func controllerOf(_ obj: YAMLValue) -> String? {
        let refs = obj.kGet("metadata")?.kGet("ownerReferences")?.kItems ?? []
        guard let r = refs.first(where: { $0.kGet("controller")?.kTruthy ?? false }) ?? refs.first else { return nil }
        return "\(r.kGet("kind")?.kText ?? "undefined")/\(r.kGet("name")?.kText ?? "undefined")"
    }

    /// The objects as a Kubernetes List document, in the format asked for.
    static func toDocument(_ items: [YAMLValue], format: String) -> String {
        let list: YAMLValue = .map([("apiVersion", .string("v1")), ("kind", .string("List")),
                                    ("metadata", .map([("resourceVersion", .string(""))])), ("items", .seq(items))])
        if format == "json" { return kubeOrderedJSONText(list, indent: 2) + "\n" }
        return KubeYAML.dump(list)
    }

    /// `rows` are the rows to keep (`(namespace, name)`); empty keeps everything
    /// the get returned. → `{ok, text, count, missing, owned:[{name, owner}]}`.
    static func exportResources(_ spec: KubeSpec, kind: String?, namespaced: Bool = true, namespace: String? = nil,
                                selector: String? = nil, apiVersion: String? = nil, rows: [(namespace: String?, name: String)] = [],
                                format: String = "yaml", clean: Bool = false) async -> JSON {
        guard let kind = kind?.nilIfEmpty else { return kubeFail("No kind to export.") }
        guard ["json", "yaml"].contains(format) else { return kubeFail("Unknown format \"\(format)\".") }
        let k = Kube.kubectlArgsFor(spec.scoped(namespace: namespace))
        // A CRD is named by its group, the way kubectl needs it to be unambiguous.
        let api = apiVersion ?? ""
        let group = api.contains("/") ? String(api.split(separator: "/", omittingEmptySubsequences: false)[0]) : ""
        let what = !group.isEmpty && !kind.contains(".") ? "\(kind).\(group)" : kind
        let scope = namespaced && (namespace ?? "").isEmpty ? ["-A"] : []
        let sel = selector?.nilIfEmpty.map { ["-l", $0] } ?? []
        let r = await KubeBin.run(k.bin, k.baseArgs + ["get", what] + scope + sel + ["-o", "json"], env: k.env, timeout: 60)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl get \(what) failed")) }
        guard let data = try? KubeYAML.orderedJSON(r.stdout) else { return kubeFail("Unexpected output from kubectl") }
        return kubeOk(build(data, namespaced: namespaced, apiVersion: apiVersion, rows: rows, format: format, clean: clean))
    }

    /// The pure part of exportResources, given kubectl's parsed output.
    static func build(_ data: YAMLValue, namespaced: Bool, apiVersion: String?, rows: [(namespace: String?, name: String)],
                      format: String, clean: Bool) -> [String: JSON] {
        let dataKind = data.kGet("kind")?.kString
        var items: [YAMLValue]
        if let its = data.kGet("items"), its.kTruthy { items = its.kItems }
        else if let dk = dataKind, !dk.isEmpty, dk != "List" { items = [data] }
        else { items = [] }
        var missing: [String] = []
        if !rows.isEmpty {
            func key(_ ns: String?, _ name: String?) -> String { "\(ns ?? "")\u{1}\(name ?? "undefined")" }
            var byKey: [String: YAMLValue] = [:]
            for o in items {
                byKey[key(namespaced ? o.kGet("metadata")?.kGet("namespace")?.kString : "", o.kGet("metadata")?.kGet("name")?.kString)] = o
            }
            let wanted = rows.map { key(namespaced ? $0.namespace : "", $0.name) }
            items = wanted.compactMap { byKey[$0] }
            missing = zip(rows, wanted).filter { byKey[$0.1] == nil }.map { x, _ in
                (x.namespace?.isEmpty == false) ? "\(x.namespace!)/\(x.name)" : x.name
            }
        }
        // A List whose items lack apiVersion/kind will not apply; make sure of them.
        let firstApi = data.kGet("items")?.kItems.first?.kGet("apiVersion")?.kString
        let fallbackApi = apiVersion?.nilIfEmpty ?? firstApi?.nilIfEmpty ?? ""
        let fallbackKind = dataKind.map { $0.replacingOccurrences(of: "List$", with: "", options: .regularExpression) }?.nilIfEmpty ?? ""
        items = items.map { o in
            guard case .map(let pairs) = o else { return o }
            let a = o.kGet("apiVersion").flatMap { $0.kTruthy ? $0 : nil } ?? .string(fallbackApi)
            let k = o.kGet("kind").flatMap { $0.kTruthy ? $0 : nil } ?? .string(fallbackKind)
            return .map([("apiVersion", a), ("kind", k)] + pairs.filter { $0.0 != "apiVersion" && $0.0 != "kind" })
        }
        // Owned objects, said before anything is stripped.
        let owned: [JSON] = items.compactMap { o in
            controllerOf(o).map { ["name": o.kGet("metadata")?.kGet("name")?.kString.map { .string($0) } ?? .null, "owner": .string($0)] }
        }
        if clean { items = items.map(cleanObject) }
        return ["text": .string(toDocument(items, format: format)), "count": .number(Double(items.count)),
                "missing": JSON(missing), "owned": .array(owned)]
    }
}

// MARK: - YAMLValue helpers (ordered maps)

extension YAMLValue {
    func kGet(_ key: String) -> YAMLValue? {
        if case .map(let p) = self { return p.first { $0.0 == key }?.1 }
        return nil
    }
    mutating func kRemove(_ key: String) {
        if case .map(let p) = self { self = .map(p.filter { $0.0 != key }) }
    }
    mutating func kSet(_ key: String, _ v: YAMLValue) {
        guard case .map(var p) = self else { return }
        if let i = p.firstIndex(where: { $0.0 == key }) { p[i].1 = v } else { p.append((key, v)) }
        self = .map(p)
    }
    var kString: String? { if case .string(let s) = self { return s }; return nil }
    var kItems: [YAMLValue] { if case .seq(let a) = self { return a }; return [] }
    /// The value as JS template text.
    var kText: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return YAMLValue.jsNumber(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        default: return "[object Object]"
        }
    }
    var kTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }
}

/// `JSON.stringify(v, null, indent)` for an ordered value.
func kubeOrderedJSONText(_ v: YAMLValue, indent: Int = 2, level: Int = 0) -> String {
    let pad = String(repeating: " ", count: indent * (level + 1)), close = String(repeating: " ", count: indent * level)
    let nl = indent > 0 ? "\n" : "", sep = indent > 0 ? ": " : ":"
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return d.isFinite ? YAMLValue.jsNumber(d) : "null"
    case .string(let s): return JSON.string(s).jsText()
    case .seq(let a):
        if a.isEmpty { return "[]" }
        return "[" + nl + a.map { pad + kubeOrderedJSONText($0, indent: indent, level: level + 1) }.joined(separator: "," + nl) + nl + close + "]"
    case .map(let p):
        if p.isEmpty { return "{}" }
        return "{" + nl + p.map { pad + JSON.string($0.0).jsText() + sep + kubeOrderedJSONText($0.1, indent: indent, level: level + 1) }
            .joined(separator: "," + nl) + nl + close + "}"
    }
}

// MARK: - kubekustomize.js, kubeexplain.js

enum KubeKustomize {
    /// `kubectl kustomize <dir>` — built into kubectl; a pure local render.
    static func build(_ spec: KubeSpec, dir: String?) async -> JSON {
        guard let dir = dir?.nilIfEmpty else { return kubeFail("No kustomization directory given.") }
        let k = Kube.kubectlArgsFor(spec)
        let r = await KubeBin.run(k.bin, k.baseArgs + ["kustomize", dir], env: k.env, timeout: 20, explain: false)
        return r.ok ? kubeOk(["yaml": .string(r.stdout)]) : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl kustomize failed"))
    }
}

/// Field names for the YAML editor's autocomplete — from `kubectl explain <kind> --recursive`.
enum KubeExplain {
    /// The plaintext tree, one field per line (`name\t<type>`), nested by indentation.
    static func parseExplainFields(_ text: String?) -> [JSON] {
        let lines = (text ?? "").components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmed == "FIELDS:" }) else { return [] }
        var fields: [JSON] = []
        var stack: [(indent: Int, name: String)] = []
        for l in lines[(start + 1)...] {
            guard let m = TPText.match(#"^(\s*)([A-Za-z0-9_-]+)\t<([^>]+)>"#, l) else { continue }
            let indent = (m[1] ?? "").utf16.count, name = m[2] ?? ""
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            fields.append(["path": .string((stack.map(\.name) + [name]).joined(separator: ".")), "type": .string(m[3] ?? "")])
            stack.append((indent, name))
        }
        return fields
    }

    /// `--api-version` disambiguates a kind in more than one group/version.
    static func explainFields(_ spec: KubeSpec, kind: String?, apiVersion: String? = nil) async -> JSON {
        guard let kind = kind?.nilIfEmpty else { return kubeFail("No kind to explain.", ["fields": []]) }
        let k = Kube.kubectlArgsFor(spec)
        var args = k.baseArgs + ["explain", kind, "--recursive"]
        if let a = apiVersion?.nilIfEmpty { args.append("--api-version=\(a)") }
        let r = await KubeBin.run(k.bin, args, env: k.env, timeout: 15, explain: false)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl explain failed"), ["fields": []]) }
        return kubeOk(["fields": .array(parseExplainFields(r.stdout))])
    }
}
