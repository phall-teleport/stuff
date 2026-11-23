import Foundation

// The small pure modules: jsonpath-lite.js, kuberelations.js, kuberbac.js.

/// jsonpath-lite.js — just enough JSONPath to read a CRD's own
/// `additionalPrinterColumns` (dot paths, `[n]`, and one
/// `[?(@.field ==|!= value)]` filter), not a general engine.
enum JSONPathLite {
    enum Token: Equatable {
        case field(String)
        case index(Int)
        case filter(field: String, op: String, value: JSON)
        case unknown
    }

    /// A dotted-but-bracketless lookup, for a filter's own `@.field`.
    static func getPlain(_ obj: JSON, _ dotted: String) -> JSON? {
        var cur: JSON? = obj
        for k in dotted.components(separatedBy: ".") {
            guard let c = cur, case .object(let o) = c else { return nil }
            cur = o[k]
        }
        return cur
    }

    static func parseBracket(_ inner: String) -> Token {
        let s = inner.trimmed
        if let m = TPText.match(#"^\?\(\s*@\.([\w.-]+)\s*(==|!=)\s*(.+?)\s*\)$"#, s), let field = m[1], let op = m[2], let raw = m[3] {
            var value: JSON = .string(raw)
            if TPText.test(#"^"[^"]*"$"#, raw) || TPText.test(#"^'[^']*'$"#, raw) { value = .string(String(raw.dropFirst().dropLast())) }
            else if raw == "true" { value = true }
            else if raw == "false" { value = false }
            else if let n = jsNumber(raw) { value = .number(n) }
            return .filter(field: field, op: op, value: value)
        }
        if TPText.test(#"^-?\d+$"#, s), let n = Int(s) { return .index(n) }
        return .unknown
    }

    /// `Number(raw)` that is not NaN.
    private static func jsNumber(_ raw: String) -> Double? {
        let t = raw.trimmed
        if t.isEmpty { return 0 }
        if t.lowercased().hasPrefix("0x"), let n = Int(t.dropFirst(2), radix: 16) { return Double(n) }
        if t == "Infinity" || t == "+Infinity" { return .infinity }
        if t == "-Infinity" { return -.infinity }
        guard TPText.test(#"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, t) else { return nil }
        return Double(t)
    }

    /// A jsonPath string into field/index/filter tokens, left to right.
    static func tokenize(_ jsonPath: String?) -> [Token] {
        var s = Array((jsonPath ?? "").trimmed)
        if s.first == "{" && s.last == "}" && s.count >= 2 { s = Array(s[1..<(s.count - 1)]) }
        if s.first == "." { s.removeFirst() }
        var tokens: [Token] = []
        var i = 0
        while i < s.count {
            if s[i] == "." { i += 1; continue }
            if s[i] == "[" {
                var depth = 1; var j = i + 1
                while j < s.count && depth > 0 {
                    if s[j] == "[" { depth += 1 } else if s[j] == "]" { depth -= 1 }
                    j += 1
                }
                let end = max(i + 1, j - 1)
                tokens.append(parseBracket(String(s[(i + 1)..<min(end, s.count)])))
                i = j
                continue
            }
            var j = i
            while j < s.count && s[j] != "." && s[j] != "[" { j += 1 }
            tokens.append(.field(String(s[i..<j])))
            i = j
        }
        return tokens
    }

    /// Resolve one jsonPath against one object — nil for anything not found or not supported.
    static func resolve(_ obj: JSON, _ jsonPath: String?) -> JSON? {
        var cur: JSON? = obj
        for t in tokenize(jsonPath) {
            guard let c = cur, !c.isNull else { return nil }
            switch t {
            case .field(let name):
                if case .object(let o) = c { cur = o[name] } else { cur = nil }
            case .index(let n):
                if case .array(let a) = c, n >= 0, n < a.count { cur = a[n] } else { cur = nil }
            case .filter(let field, let op, let value):
                guard case .array(let a) = c else { return nil }
                cur = a.first { item in
                    let v = getPlain(item, field)
                    return op == "==" ? v == value : v != value
                }
            case .unknown:
                return nil
            }
        }
        return cur
    }
}

/// kuberelations.js — where a resource leads next (owner, bound PV, Endpoints).
enum KubeRelations {
    /// Candidates to jump to from one full (already-fetched) object. Pure.
    static func relatedOf(_ object: JSON) -> JSON {
        guard case .object = object else { return [] }
        let kind = object["kind"].string
        let name = object["metadata"]["name"].string
        let namespace: JSON = object["metadata"]["namespace"].string?.nilIfEmpty.map { .string($0) } ?? .null
        var out: [JSON] = []
        let owners = object["metadata"]["ownerReferences"].items
        let owner = owners.first { $0["controller"].truthy } ?? owners.first
        if let o = owner, let k = o["kind"].string?.nilIfEmpty, let n = o["name"].string?.nilIfEmpty {
            out.append(["kind": .string(k), "name": .string(n), "namespace": namespace, "via": "owner"])
        }
        if kind == "PersistentVolumeClaim", let v = object["spec"]["volumeName"].string?.nilIfEmpty {
            out.append(["kind": "PersistentVolume", "name": .string(v), "namespace": .null, "via": "volumeName"])
        }
        if kind == "Service", let n = name?.nilIfEmpty {
            out.append(["kind": "Endpoints", "name": .string(n), "namespace": namespace, "via": "same name"])
        }
        return .array(out)
    }
}

/// kuberbac.js — "Who can do that?", the reverse of can-i. Pure.
enum KubeRBAC {
    struct Query {
        var verb: String
        var resource: String
        var apiGroup: String = ""
        var resourceName: String?
    }

    /// A rule's own list field: absent means "none", `*` anything.
    static func matchesList(_ list: JSON, _ value: String) -> Bool {
        let l = list.items.compactMap { $0.string }
        if l.isEmpty { return false }
        return l.contains("*") || l.contains(value)
    }

    static func ruleAllows(_ rule: JSON, _ q: Query) -> Bool {
        if !matchesList(rule["verbs"], q.verb) { return false }
        if !matchesList(rule["apiGroups"], q.apiGroup) { return false }
        if !matchesList(rule["resources"], q.resource) { return false }
        let names = rule["resourceNames"].items.compactMap { $0.string }
        if let rn = q.resourceName?.nilIfEmpty, !names.isEmpty, !names.contains(rn) { return false }
        return true
    }

    static func roleAllows(_ role: JSON, _ q: Query) -> Bool {
        role["rules"].items.contains { ruleAllows($0, q) }
    }

    /// Every subject some binding grants this to, with the binding and role that grant it.
    static func whoCan(_ q: Query, roles: [JSON] = [], clusterRoles: [JSON] = [], roleBindings: [JSON] = [],
                       clusterRoleBindings: [JSON] = []) -> [JSON] {
        func roleKey(_ ns: String?, _ name: String?) -> String { "\(ns ?? "")\u{1}\(name ?? "")" }
        var rolesByKey: [String: JSON] = [:]
        for r in roles { rolesByKey[roleKey(r["metadata"]["namespace"].string, r["metadata"]["name"].string)] = r }
        var clusterRolesByName: [String: JSON] = [:]
        for r in clusterRoles { clusterRolesByName[r["metadata"]["name"].string ?? ""] = r }
        func nullable(_ s: String?) -> JSON { s?.nilIfEmpty.map { .string($0) } ?? .null }

        var matches: [JSON] = []
        func consider(_ binding: JSON, _ bindingKind: String) {
            let ref = binding["roleRef"]
            let refName = ref["name"].string
            let role = ref["kind"].string == "ClusterRole"
                ? clusterRolesByName[refName ?? ""]
                : rolesByKey[roleKey(binding["metadata"]["namespace"].string, refName)]
            guard let role, roleAllows(role, q) else { return }
            for subject in binding["subjects"].items {
                matches.append([
                    "subject": ["kind": subject["kind"], "name": subject["name"], "namespace": nullable(subject["namespace"].string)],
                    "role": ["kind": ref["kind"], "name": ref["name"]],
                    "binding": ["kind": .string(bindingKind), "name": binding["metadata"]["name"],
                                "namespace": nullable(binding["metadata"]["namespace"].string)],
                ])
            }
        }
        for b in roleBindings { consider(b, "RoleBinding") }
        for b in clusterRoleBindings { consider(b, "ClusterRoleBinding") }
        return matches
    }
}
