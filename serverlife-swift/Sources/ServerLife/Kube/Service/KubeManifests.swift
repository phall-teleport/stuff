import Foundation

// kubeops.js, second half: the "create" forms (a few fields in, a complete
// manifest out — shown as YAML before it goes through the browser's apply
// flow, diff and all), and the Teleport-group → cluster-permission bindings.
// Built as ordered YAMLValue maps, so the YAML reads in js-yaml's
// insertion order (apiVersion, kind, metadata, spec…).

extension KubeOps {
    private typealias Y = YAMLValue

    /// "K=V" lines → ordered pairs; a repeated key keeps its first place and its last value (Object.fromEntries).
    static func kvLines(_ text: String?) -> [(String, String)] {
        var out: [(String, String)] = []
        for raw in (text ?? "").components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = String(l[..<eq]).trimmingCharacters(in: .whitespaces), v = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1 = v } else { out.append((k, v)) }
        }
        return out
    }

    private static func smap(_ pairs: [(String, String)]) -> Y { .map(pairs.map { ($0.0, .string($0.1)) }) }
    private static func str(_ j: JSON) -> Y? { j.string.map { .string($0) } ?? j.stringish.map { .string($0) } }
    /// A map with nil values dropped (js-yaml skips undefined).
    private static func m(_ items: [(String, Y?)]) -> Y { .map(items.compactMap { k, v in v.map { (k, $0) } }) }

    /// `manifestFor(kind, fields)` → `{ok, yaml}` or `{ok:false, error}`.
    static func manifestFor(_ kind: String, _ f: JSON) -> JSON {
        let name = f["name"].stringish ?? ""
        let ns = f["namespace"].stringish?.nilIfEmpty ?? "default"
        let labels: Y = .map([("app", .string(name.isEmpty ? "app" : name))])
        let nameY = str(f["name"])
        var doc: Y
        switch kind {
        case "Deployment":
            let pn = kubeJSNumber(f["port"])
            let port: Double? = pn.isNaN || pn == 0 ? nil : pn
            let env = kvLines(f["env"].stringish)
            let rn = kubeJSNumber(f["replicas"])
            var container: [(String, Y?)] = [("name", nameY), ("image", str(f["image"]))]
            if let port { container.append(("ports", .seq([.map([("containerPort", kubeYNum(port))])]))) }
            if !env.isEmpty { container.append(("env", .seq(env.map { .map([("name", .string($0.0)), ("value", .string($0.1))]) }))) }
            doc = m([("apiVersion", .string("apps/v1")), ("kind", .string("Deployment")),
                     ("metadata", m([("name", nameY), ("namespace", .string(ns)), ("labels", labels)])),
                     ("spec", .map([
                        ("replicas", rn >= 0 ? kubeYNum(rn) : .int(1)),
                        ("selector", .map([("matchLabels", labels)])),
                        ("template", .map([("metadata", .map([("labels", labels)])),
                                           ("spec", .map([("containers", .seq([m(container)]))]))])),
                     ]))])
        case "Service":
            let sel = kvLines(f["selector"].stringish)
            let p = kubeJSNumber(f["port"]), tp = kubeJSNumber(f["targetPort"])
            let port = p.isNaN || p == 0 ? 80 : p
            let target = !(tp.isNaN || tp == 0) ? tp : port
            doc = m([("apiVersion", .string("v1")), ("kind", .string("Service")),
                     ("metadata", m([("name", nameY), ("namespace", .string(ns))])),
                     ("spec", .map([("type", .string(f["type"].stringish?.nilIfEmpty ?? "ClusterIP")),
                                    ("selector", sel.isEmpty ? m([("app", nameY)]) : smap(sel)),
                                    ("ports", .seq([.map([("port", kubeYNum(port)), ("targetPort", kubeYNum(target))])]))]))])
        case "ConfigMap":
            doc = m([("apiVersion", .string("v1")), ("kind", .string("ConfigMap")),
                     ("metadata", m([("name", nameY), ("namespace", .string(ns))])), ("data", smap(kvLines(f["data"].stringish)))])
        case "Secret":
            // stringData: the API server does the base64, so the form never shows an encoded value.
            doc = m([("apiVersion", .string("v1")), ("kind", .string("Secret")),
                     ("metadata", m([("name", nameY), ("namespace", .string(ns))])),
                     ("type", .string(f["type"].stringish?.nilIfEmpty ?? "Opaque")), ("stringData", smap(kvLines(f["data"].stringish)))])
        case "Role", "ClusterRole":
            let rules = parseRules(f["rules"].stringish)
            if rules.isEmpty { return kubeFail("At least one rule is needed — pick a common need, or fill in VERBS | APIGROUPS | RESOURCES.") }
            let meta = kind == "Role" ? m([("name", nameY), ("namespace", .string(ns))]) : m([("name", nameY)])
            doc = .map([("apiVersion", .string("rbac.authorization.k8s.io/v1")), ("kind", .string(kind)), ("metadata", meta),
                        ("rules", .seq(rules.map(ruleYAML)))])
        case "RoleBinding", "ClusterRoleBinding":
            let subjects = parseSubjects(f["subjects"].stringish, fallbackNamespace: ns)
            if subjects.isEmpty { return kubeFail("At least one subject is needed — one per line, KIND:name (a ServiceAccount also needs :namespace).") }
            guard let roleRefName = f["roleRefName"].stringish?.nilIfEmpty else { return kubeFail("A Role or ClusterRole to bind is needed.") }
            let roleRefKind = f["roleRefKind"].stringish?.nilIfEmpty ?? "Role"
            // A real Kubernetes constraint: a ClusterRoleBinding can only name a ClusterRole.
            if kind == "ClusterRoleBinding" && roleRefKind != "ClusterRole" {
                return kubeFail("A ClusterRoleBinding can only bind a ClusterRole, not a namespaced Role.")
            }
            let roleRef: Y = .map([("apiGroup", .string("rbac.authorization.k8s.io")), ("kind", .string(roleRefKind)), ("name", .string(roleRefName))])
            let meta = kind == "RoleBinding" ? m([("name", nameY), ("namespace", .string(ns))]) : m([("name", nameY)])
            doc = .map([("apiVersion", .string("rbac.authorization.k8s.io/v1")), ("kind", .string(kind)), ("metadata", meta),
                        ("subjects", .seq(subjects.map(subjectYAML))), ("roleRef", roleRef)])
        default:
            return kubeFail("No form for \(kind).")
        }
        if !TPText.test(dnsLabel, name) { return kubeFail("\"\(name)\" is not a valid name — lowercase letters, digits and \"-\".") }
        if kind == "Deployment" && !f["image"].truthy { return kubeFail("A Deployment needs an image.") }
        return kubeOk(["yaml": .string(KubeYAML.dump(doc))])
    }

    struct Rule: Equatable { var verbs: [String]; var apiGroups: [String]; var resources: [String] }
    struct Subject: Equatable { var kind: String; var name: String; var namespace: String? }

    private static func ruleYAML(_ r: Rule) -> Y {
        .map([("verbs", .seq(r.verbs.map { .string($0) })), ("apiGroups", .seq(r.apiGroups.map { .string($0) })),
              ("resources", .seq(r.resources.map { .string($0) }))])
    }
    private static func subjectYAML(_ s: Subject) -> Y {
        var o: [(String, Y)] = [("kind", .string(s.kind)), ("name", .string(s.name))]
        if let n = s.namespace { o.append(("namespace", .string(n))) }
        return .map(o)
    }

    /// One rule per line: `VERBS | APIGROUPS | RESOURCES`, comma-separated within
    /// each part. A blank APIGROUPS segment means the core group (`""`, kept —
    /// `apiGroups: []` means "nothing", not "core"); `*` means any.
    static func parseRules(_ text: String?) -> [Rule] {
        (text ?? "").components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }.map { line in
            let parts = line.components(separatedBy: "|")
            let part = { (i: Int) in i < parts.count ? parts[i] : "" }
            let split = { (s: String) in s.components(separatedBy: ",").map { $0.trimmed } }
            return Rule(verbs: split(part(0)).filter { !$0.isEmpty }, apiGroups: split(part(1)),
                        resources: split(part(2)).filter { !$0.isEmpty })
        }.filter { !$0.verbs.isEmpty && !$0.resources.isEmpty }
    }

    /// One subject per line: a bare name (a User), `KIND:name`, or
    /// `ServiceAccount:name:namespace` (falls back to the binding's namespace).
    static func parseSubjects(_ text: String?, fallbackNamespace: String?) -> [Subject] {
        (text ?? "").components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }.map { line in
            let parts = line.components(separatedBy: ":").map { $0.trimmed }
            let kindPart = parts.count == 1 ? "User" : parts[0]
            let namePart = parts.count == 1 ? parts[0] : parts[1]
            let nsPart = parts.count > 2 ? parts[2] : ""
            let kind = kindPart.isEmpty ? "User" : kindPart
            return Subject(kind: kind, name: namePart, namespace: kind == "ServiceAccount" ? (nsPart.nilIfEmpty ?? fallbackNamespace) : nil)
        }.filter { !$0.name.isEmpty }
    }

    // MARK: Teleport group → cluster permissions

    static func bindingName(_ group: String, _ clusterRole: String) -> String {
        var s = "teleport-\(group)-\(clusterRole)".lowercased()
            .replacingOccurrences(of: "[^a-z0-9.-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        if s.count > 253 { s = String(s.prefix(253)) }
        return s
    }

    /// In the cluster: a ClusterRoleBinding for the whole cluster, or one RoleBinding
    /// per namespace granting the same ClusterRole only there.
    /// `{ok, yaml, count, scope}` or `{ok:false, error}`.
    static func groupBinding(group: String?, clusterRole: String?, namespaces: [String] = [], name: String? = nil) -> JSON {
        let g = (group ?? "").trimmed, role = (clusterRole ?? "").trimmed
        if g.isEmpty { return kubeFail("Name the group.") }
        if TPText.test(#"\s"#, g) { return kubeFail("A group name has no spaces.") }
        if role.isEmpty { return kubeFail("Pick a ClusterRole.") }
        let bind = (name?.nilIfEmpty ?? bindingName(g, role)).trimmed
        if !TPText.test(#"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$"#, bind) {
            return kubeFail("\"\(bind)\" is not a valid binding name — lowercase letters, digits, \"-\" and \".\".")
        }
        let subjects: Y = .seq([.map([("apiGroup", .string("rbac.authorization.k8s.io")), ("kind", .string("Group")), ("name", .string(g))])])
        let roleRef: Y = .map([("apiGroup", .string("rbac.authorization.k8s.io")), ("kind", .string("ClusterRole")), ("name", .string(role))])
        let gl = String(g.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression).prefix(63))
        let labels: Y = .map([("app.kubernetes.io/managed-by", .string("serverlife")), ("serverlife.teleport/group", .string(gl))])
        let nss = namespaces.filter { !$0.isEmpty }
        let docs: [Y] = !nss.isEmpty
            ? nss.map { ns in .map([("apiVersion", .string("rbac.authorization.k8s.io/v1")), ("kind", .string("RoleBinding")),
                                    ("metadata", .map([("name", .string(bind)), ("namespace", .string(ns)), ("labels", labels)])),
                                    ("roleRef", roleRef), ("subjects", subjects)]) }
            : [.map([("apiVersion", .string("rbac.authorization.k8s.io/v1")), ("kind", .string("ClusterRoleBinding")),
                     ("metadata", .map([("name", .string(bind)), ("labels", labels)])), ("roleRef", roleRef), ("subjects", subjects)])]
        return kubeOk(["yaml": .string(docs.map { KubeYAML.dump($0) }.joined(separator: "---\n")),
                       "count": .number(Double(docs.count)), "scope": .string(nss.isEmpty ? "ClusterRoleBinding" : "RoleBinding")])
    }

    /// In Teleport: the role to go with it — the group under spec.allow.kubernetes_groups.
    /// Written out to copy or save, never applied from here. `{ok, name, yaml, broadLabels}`.
    static func teleportRoleFor(group: String?, roleName: String? = nil, clusterLabels: [(String, String)] = [],
                                kubeClusterName: String? = nil, namespaces: [String] = []) -> JSON {
        let g = (group ?? "").trimmed
        if g.isEmpty { return kubeFail("Name the group.") }
        let name = (roleName?.nilIfEmpty ?? "kube-\(g)").lowercased().replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
        // Labels this cluster really has; without any, every cluster.
        let labels = clusterLabels.filter { !$0.0.isEmpty && !$0.0.hasPrefix("teleport.internal/") && !$0.0.hasPrefix("teleport.dev/") }
        let ns = namespaces.filter { !$0.isEmpty }
        let on = kubeClusterName?.nilIfEmpty.map { " on \($0)" } ?? ""
        let role: Y = .map([
            ("kind", .string("role")), ("version", .string("v8")),
            ("metadata", .map([("name", .string(name)), ("description", .string("Kubernetes group \"\(g)\"\(on) — made with ServerLife"))])),
            ("spec", .map([
                ("allow", .map([
                    ("kubernetes_labels", labels.isEmpty ? .map([("*", .string("*"))]) : smap(labels)),
                    ("kubernetes_groups", .seq([.string(g)])),
                    // v8: plural kinds and an api_group; '*' everywhere is "whatever the group is bound to".
                    ("kubernetes_resources", .seq((ns.isEmpty ? ["*"] : ns).map { n in
                        .map([("kind", .string("*")), ("namespace", .string(n)), ("name", .string("*")), ("api_group", .string("*")),
                              ("verbs", .seq([.string("*")]))]) })),
                ])),
                ("deny", .map([])),
            ])),
        ])
        return kubeOk(["name": .string(name), "yaml": .string(KubeYAML.dump(role)), "broadLabels": .bool(labels.isEmpty)])
    }
}
