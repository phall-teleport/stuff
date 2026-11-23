import Foundation

/// The control socket's read-only Kubernetes verbs (main.js
/// `list_kube_resource_types`, `list_kube_resources`, `get_kube_resource`,
/// `describe_kube_resource`, with `resolveKubeContext` / `resolveKubeType`).
@MainActor
enum ControlKube {
    /// A kube cluster, named, for the control socket's own read-only verbs —
    /// resolved from `Kube.listContexts()` alone (every context, Teleport-
    /// sourced or not, already carries `contextName`/`kubeconfigPaths`,
    /// everything KubeResources needs). Nothing window-only is needed for a
    /// read: a cluster has to already be logged in to answer one at all, so
    /// the sidebar's available/requestable states have nothing to add here —
    /// `list_hosts`/`open_session` are where logging in happens, not this.
    static func resolveContext(_ name: String?) async throws -> JSON {
        guard let name = name?.nilIfEmpty else { throw AppError("Give a \"cluster\".") }
        let r = await Kube.listContexts(extraPaths: Store.shared.kubeSettingConfigPaths)
        if !r["ok"].truthy { throw AppError(r["error"].string?.nilIfEmpty ?? "Could not read kubeconfig contexts.") }
        return try pick(name, from: r["contexts"].items)
    }

    /// The matching rule, apart for tests: an exact context name, else the
    /// one context for that kube cluster name.
    nonisolated static func pick(_ name: String, from contexts: [JSON]) throws -> JSON {
        if let c = contexts.first(where: { $0["contextName"].string == name }) { return c }
        let byKube = contexts.filter { $0["kubeClusterName"].string == name }
        if byKube.count == 1 { return byKube[0] }
        if byKube.count > 1 {
            throw AppError("\"\(name)\" matches \(byKube.count) logged-in contexts: "
                + byKube.map { $0["contextName"].string ?? "" }.joined(separator: ", ") + ". Give the exact context name.")
        }
        throw AppError("No logged-in cluster called \"\(name)\". Try serverlife_list_hosts to see what is available, "
            + "or serverlife_open_session to log in first — this only reads from a cluster already logged into.")
    }

    /// A discovered resource type matching `kind`, case-insensitive — the
    /// same rule the cross-cluster search in the kube browser uses.
    static func resolveType(_ spec: KubeSpec, _ kind: String?) async throws -> JSON {
        guard let kind = kind?.nilIfEmpty else { throw AppError("Give a \"kind\" (e.g. Pod, Deployment).") }
        let r = await KubeResources.discoverResourceTypes(spec)
        if !r["ok"].truthy { throw AppError(r["error"].string?.nilIfEmpty ?? "Could not list resource kinds for that cluster.") }
        guard let type = r["types"].items.first(where: { ($0["kind"].string ?? "").lowercased() == kind.lowercased() }) else {
            throw AppError("\"\(kind)\" is not a kind this cluster lists. Try serverlife_list_kube_resource_types.")
        }
        return type
    }

    private static func spec(_ p: JSON) async throws -> (KubeSpec, String) {
        let c = try await resolveContext(p["cluster"].stringish)
        return (KubeSpec(json: c), c["contextName"].string ?? "")
    }

    /// Every resource kind a kube cluster actually has — discovery, no fixed list.
    static func listTypes(_ p: JSON) async throws -> JSON {
        let (spec, ctx) = try await spec(p)
        let r = await KubeResources.discoverResourceTypes(spec)
        if !r["ok"].truthy { throw AppError(r["error"].string?.nilIfEmpty ?? "Could not list resource kinds.") }
        return ["cluster": .string(ctx), "types": r["types"]]
    }

    /// Resources of one kind — kubectl get, trimmed the same way the cluster
    /// browser shows a row.
    static func listResources(_ p: JSON) async throws -> JSON {
        let (spec, ctx) = try await spec(p)
        let type = try await resolveType(spec, p["kind"].stringish)
        let r = await KubeResources.getResources(spec, name: type["name"].string ?? "", namespaced: type["namespaced"].truthy,
                                                 namespace: p["namespace"].stringish?.nilIfEmpty,
                                                 selector: p["selector"].stringish?.nilIfEmpty)
        if !r["ok"].truthy { throw AppError(r["error"].string?.nilIfEmpty ?? "Could not list that resource.") }
        let items = r["items"].items
        let limit = ControlVerbs.jsClamp(p["limit"].double ?? 100, 1, 1000)
        return ["cluster": .string(ctx), "kind": type["kind"], "count": .number(Double(items.count)),
                "items": .array(Array(items.prefix(limit)))]
    }

    /// One resource's own YAML — kubectl get -o yaml, read-only.
    static func getResource(_ p: JSON) async throws -> JSON {
        guard let name = p["name"].stringish?.nilIfEmpty else { throw AppError("Give a \"name\".") }
        let (spec, ctx) = try await spec(p)
        let type = try await resolveType(spec, p["kind"].stringish)
        let r = await KubeResources.getYaml(spec, name: name, resource: type["name"].string ?? "",
                                            namespace: p["namespace"].stringish?.nilIfEmpty)
        if !r["ok"].truthy { throw AppError(r["error"].string?.nilIfEmpty ?? "Could not read that resource.") }
        return ["cluster": .string(ctx), "kind": type["kind"], "name": .string(name), "yaml": r["yaml"]]
    }

    /// `kubectl describe` for one resource — conditions and recent events, in kubectl's own words.
    static func describeResource(_ p: JSON) async throws -> JSON {
        guard let name = p["name"].stringish?.nilIfEmpty else { throw AppError("Give a \"name\".") }
        let (spec, ctx) = try await spec(p)
        let type = try await resolveType(spec, p["kind"].stringish)
        let r = await KubeResources.describe(spec, name: name, resource: type["name"].string ?? "",
                                             namespace: p["namespace"].stringish?.nilIfEmpty)
        if !r["ok"].truthy { throw AppError(r["error"].string?.nilIfEmpty ?? "Could not describe that resource.") }
        return ["cluster": .string(ctx), "kind": type["kind"], "name": .string(name), "text": r["text"]]
    }

    /// kubepanel.js `contextsForProfile`'s rule, as list_hosts uses it: a
    /// Teleport-sourced context belongs to the profile whose cluster it names,
    /// or (naming none) whose proxy it came through.
    nonisolated static func contexts(_ all: [JSON], cluster: String, proxy: String) -> [JSON] {
        all.filter { c in
            guard c["source"].string == "teleport" else { return false }
            let tc = c["teleportCluster"].string?.nilIfEmpty
            return tc == cluster || (tc == nil && c["teleportProxy"].string == proxy)
        }
    }

    nonisolated static func nameOf(_ c: JSON) -> String { c["kubeClusterName"].string?.nilIfEmpty ?? c["name"].string ?? "" }
}
