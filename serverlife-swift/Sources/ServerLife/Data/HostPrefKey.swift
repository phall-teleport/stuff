import Foundation

extension Store {
    /// store.js `hostPrefKey` on a plain host descriptor (JSON), including the
    /// Kubernetes branches added for KubeLife: a kube cluster is keyed by its
    /// Teleport cluster's name when there is one, else by its group — kept in
    /// step with folders.js `hostKey()`. `Host.prefKey` (Core) is the typed
    /// counterpart; a kube host carries `kind`, `teleportCluster` and
    /// `groupKey` in `extra`.
    nonisolated static func hostPrefKey(_ host: JSON) -> String {
        guard host.truthy else { return "" }
        if host["uuid"].truthy { return "uuid:" + dStr(host["uuid"]) }
        if host["kind"].string == "kube", host["name"].truthy {
            if host["teleportCluster"].truthy { return "kube:\(dStr(host["teleportCluster"])):\(dStr(host["name"]))" }
            if host["groupKey"].truthy { return "kube:\(dStr(host["groupKey"])):\(dStr(host["name"]))" }
        }
        if host["type"].string == "teleport", host["name"].truthy {
            return "tsh:\(dStr(host["cluster"])):\(dStr(host["name"]))"
        }
        if host["id"].truthy { return dStr(host["id"]) }
        return host["alias"].truthy ? "ssh:" + dStr(host["alias"]) : ""
    }
}
