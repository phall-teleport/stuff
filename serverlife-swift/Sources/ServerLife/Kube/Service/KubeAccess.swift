import Foundation

// kuberesources.js: can-i, the "My access" grid, and "Who can do that?".

extension KubeResources {
    /// `kubectl auth can-i <verb> <resource>` — can-i exits 1 for a plain "no";
    /// only an empty answer with an error beside it means it could not be asked.
    static func canI(_ spec: KubeSpec, verb: String, resource: String, namespace: String? = nil, asUser: String? = nil,
                     asGroups: [String] = [], allNamespaces: Bool = false) async -> JSON {
        var impersonate: [String] = []
        if let u = asUser?.nilIfEmpty { impersonate.append("--as=" + u) }
        impersonate += asGroups.filter { !$0.isEmpty }.map { "--as-group=" + $0 }
        let scope = allNamespaces && (namespace ?? "").isEmpty ? ["-A"] : []
        let r = await run(argsFor(spec, namespace: namespace), ["auth", "can-i", verb, resource] + scope + impersonate, timeout: 10)
        let out = kubePlain(r.stdout).lowercased()
        let unknown = out.isEmpty && !kubePlain(r.stderr).isEmpty
        var o: [String: JSON] = ["ok": true, "allowed": .bool(r.ok && out.hasPrefix("yes")), "unknown": .bool(unknown), "noAccess": .bool(r.noAccess)]
        if unknown { o["error"] = .string(kubePlain(r.stderr)) }
        return .object(o)
    }

    static let accessVerbs = ["get", "list", "create", "update", "delete"]
    static let accessResources: [(resource: String, cluster: Bool)] = [
        ("pods", false), ("deployments", false), ("statefulsets", false), ("daemonsets", false),
        ("jobs", false), ("services", false), ("ingresses", false), ("configmaps", false),
        ("secrets", false), ("persistentvolumeclaims", false), ("events", false),
        ("namespaces", true), ("nodes", true),
    ]
    /// Subresources with one verb that matters each.
    static let accessExtra: [(resource: String, verb: String)] = [("pods/exec", "create"), ("pods/log", "get")]

    /// Run `fn` over `items`, at most `limit` at once; answers in order.
    static func mapLimit<T: Sendable, R: Sendable>(_ items: [T], _ limit: Int, _ fn: @escaping @Sendable (T) async -> R) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { g in
            var out = [R?](repeating: nil, count: items.count)
            var next = 0
            for _ in 0..<min(limit, items.count) {
                let i = next; next += 1
                g.addTask { (i, await fn(items[i])) }
            }
            for await (i, r) in g {
                out[i] = r
                if next < items.count { let j = next; next += 1; g.addTask { (j, await fn(items[j])) } }
            }
            return out.compactMap { $0 }
        }
    }

    /// Who the cluster sees, and a can-i grid. Identity from `auth whoami` when
    /// the cluster allows it, else from the Teleport profile's own kubernetes
    /// users/groups (`teleportProxy` says which profile). Asked one can-i at a
    /// time: through Teleport `auth can-i --list` needs selfsubjectrulesreviews,
    /// which most roles do not grant.
    static func access(_ spec: KubeSpec, namespace: String? = nil, teleportProxy: String? = nil, asUser: String? = nil,
                       asGroups: [String] = []) async -> JSON {
        var identity: JSON = .null
        // Impersonating: the grid is about them, and whoami can't speak for another identity.
        if asUser?.isEmpty == false || !asGroups.isEmpty {
            identity = ["source": "impersonated", "users": JSON(asUser?.nilIfEmpty.map { [$0] } ?? []), "groups": JSON(asGroups)]
        }
        if identity.isNull {
            let r = await run(clusterArgs(spec), ["auth", "whoami", "-o", "json"], timeout: 10)
            if r.ok, let j = try? JSON.parse(r.stdout) {
                let u = j["status"]["userInfo"]
                identity = ["source": "cluster", "users": JSON(u["username"].string?.nilIfEmpty.map { [$0] } ?? []),
                            "groups": JSON(u["groups"].items.compactMap { $0.string })]
            }
        }
        if identity.isNull, let proxy = teleportProxy?.nilIfEmpty, let p = await kubeTeleportIdentity(proxy: proxy) {
            identity = p
        }
        struct Check: Sendable { var resource: String; var verb: String; var cluster: Bool }
        let checks = accessResources.flatMap { r in accessVerbs.map { Check(resource: r.resource, verb: $0, cluster: r.cluster) } }
            + accessExtra.map { Check(resource: $0.resource, verb: $0.verb, cluster: false) }
        let groups = asGroups
        let answers = await mapLimit(checks, 8) { c in
            await canI(spec, verb: c.verb, resource: c.resource, namespace: c.cluster ? nil : namespace, asUser: asUser, asGroups: groups)
        }
        let rights: [JSON] = checks.enumerated().map { i, c in
            ["resource": .string(c.resource), "verb": .string(c.verb), "cluster": .bool(c.cluster),
             "allowed": answers[i]["allowed"], "unknown": answers[i]["unknown"]]
        }
        return ["ok": true, "identity": identity, "rights": .array(rights), "verbs": JSON(accessVerbs),
                "namespace": namespace?.nilIfEmpty.map { .string($0) } ?? .null]
    }

    /// The Teleport profile for `proxy`, as `{source:'teleport', users, groups,
    /// teleportUser, roles}`. Swift's TeleportProfile does not carry the
    /// kubernetes users/groups, so `tsh status --format=json` is read here
    /// (in that proxy's home first, then the others).
    static func kubeTeleportIdentity(proxy: String) async -> JSON? {
        func bare(_ s: String) -> String {
            s.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #":443$"#, with: "", options: .regularExpression)
        }
        var homes = TeleportHomes.active
        if let h = Tools.home(forProxy: proxy), let i = homes.firstIndex(of: h) { homes.remove(at: i); homes.insert(h, at: 0) }
        for home in homes {
            let r = await Teleport.run(["status", "--format=json"], home: home, timeout: 15)
            guard r.ok, r.out.trimmed.hasPrefix("{"), let data = try? JSON.parse(r.out) else { continue }
            let all = (data["active"].isNull ? [] : [data["active"]]) + data["profiles"].items
            for p in all {
                let px = p["profile_url"].string.map { $0.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression) } ?? p["proxy"].kStr
                guard bare(px) == bare(proxy) else { continue }
                func strs(_ j: JSON) -> JSON { JSON(j.items.compactMap { $0.string }) }
                return ["source": "teleport", "users": strs(p["kubernetes_users"]), "groups": strs(p["kubernetes_groups"]),
                        "teleportUser": p["username"], "roles": strs(p["roles"])]
            }
        }
        return nil
    }

    /// "Who can do that?" — every Role/ClusterRole reachable from every binding,
    /// matched the way the API server would (kuberbac.js). Namespaced kinds are
    /// scoped to `namespace` when given, every namespace otherwise.
    static func whoCan(_ spec: KubeSpec, verb: String, resource: String, apiGroup: String = "", resourceName: String? = nil,
                       namespace: String? = nil) async -> JSON {
        async let roles = getRawList(spec, name: "roles", namespaced: true, namespace: namespace)
        async let clusterRoles = getRawList(spec, name: "clusterroles")
        async let roleBindings = getRawList(spec, name: "rolebindings", namespaced: true, namespace: namespace)
        async let clusterRoleBindings = getRawList(spec, name: "clusterrolebindings")
        let all = await [roles, clusterRoles, roleBindings, clusterRoleBindings]
        if let e = all.first(where: { !$0["ok"].truthy }) { return ["ok": false, "error": e["error"]] }
        let matches = KubeRBAC.whoCan(KubeRBAC.Query(verb: verb, resource: resource, apiGroup: apiGroup, resourceName: resourceName),
                                      roles: all[0]["items"].items, clusterRoles: all[1]["items"].items,
                                      roleBindings: all[2]["items"].items, clusterRoleBindings: all[3]["items"].items)
        return ["ok": true, "matches": .array(matches)]
    }

    /// One representative check per rule (at most 10) — a smoke test, `*` asked as get/pods.
    static func sampleChecksFromRules(_ rules: JSON, namespace: String? = nil) -> [JSON] {
        rules.items.prefix(10).compactMap { rule in
            guard let verb = rule["verbs"].items.first?.string?.nilIfEmpty,
                  let resource = rule["resources"].items.first?.string?.nilIfEmpty else { return nil }
            var o: [String: JSON] = ["verb": .string(verb == "*" ? "get" : verb), "resource": .string(resource == "*" ? "pods" : resource)]
            if let ns = namespace?.nilIfEmpty { o["namespace"] = .string(ns) }
            return .object(o)
        }
    }
}
