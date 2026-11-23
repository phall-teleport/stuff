import Foundation

/// 0.39: a Kubernetes cluster's settings key (store.js `hostPrefKey`, kept in
/// step with folders.js `hostKey`). With its Teleport cluster known a cluster
/// is keyed `kube:<teleportCluster>:<name>`; otherwise by its group,
/// `kube:<groupKey>:<name>`; a local context keeps its own id. `Host.prefKey`
/// (Core) does not have the kube branches yet — use these until it does.
enum KubeKeys {
    static func prefKey(kind: String?, uuid: String? = nil, teleportCluster: String?, groupKey: String?, name: String?, id: String?) -> String? {
        if let uuid, !uuid.isEmpty { return "uuid:" + uuid }
        guard kind == "kube" else { return nil }
        let n = name ?? ""
        if let tc = teleportCluster, !tc.isEmpty, !n.isEmpty { return "kube:\(tc):\(n)" }
        if let g = groupKey, !g.isEmpty, !n.isEmpty { return "kube:\(g):\(n)" }
        return id?.nilIfEmpty
    }

    /// For a host row as JSON (the renderer's descriptor shape).
    static func prefKey(_ row: JSON) -> String? {
        prefKey(kind: row["kind"].string, uuid: row["uuid"].string, teleportCluster: row["teleportCluster"].string,
                groupKey: row["groupKey"].string, name: row["name"].stringish, id: row["id"].string)
    }
}

extension Host {
    /// `prefKey` with the kube rules of 0.39 (store.js `hostPrefKey`); a non-kube host is unchanged.
    var kubeAwarePrefKey: String {
        KubeKeys.prefKey(kind: extra["kind"]?.string, uuid: uuid, teleportCluster: extra["teleportCluster"]?.string,
                         groupKey: extra["groupKey"]?.string, name: name, id: id) ?? prefKey
    }
}
