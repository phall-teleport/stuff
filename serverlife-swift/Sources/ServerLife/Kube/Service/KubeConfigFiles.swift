import Foundation

/// main.js `kubeconfig:*` — editing a kubeconfig in the app, the same rules as
/// the ssh config editor: only files the app already reads (the default
/// kubeconfig and the ones added in Settings), and never saved before kubectl
/// itself has parsed the new text — `kubectl config view` on a copy — with a
/// context pointing at a cluster or user the file does not have said as a
/// problem too. The file it replaces is kept as <file>.serverlife-backup,
/// permissions kept.
enum KubeConfigFiles {
    static func resolve(_ p: String) -> String {
        let e = (p as NSString).expandingTildeInPath
        let abs = e.hasPrefix("/") ? e : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(e)
        return (abs as NSString).standardizingPath
    }

    @MainActor static func known() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for p in (Kube.defaultKubeconfigPaths() + Store.shared.kubeSettingConfigPaths).map(resolve) where seen.insert(p).inserted { out.append(p) }
        return out
    }

    /// The path, if it is one of the files ServerLife reads (the first of them when `file` is empty).
    @MainActor static func knownKubeconfig(_ file: String?) throws -> String {
        let k = known()
        let p = resolve(file?.nilIfEmpty ?? k.first ?? "")
        guard k.contains(p) else { throw AppError("\(file ?? "undefined") is not one of the kubeconfig files ServerLife reads.") }
        return p
    }

    /// `[{path, exists}]`.
    @MainActor static func files() -> [JSON] {
        known().map { ["path": .string($0), "exists": .bool(FileManager.default.fileExists(atPath: $0))] }
    }

    /// `{path, text}`; a missing file reads as "".
    @MainActor static func read(_ file: String?) throws -> JSON {
        let p = try knownKubeconfig(file)
        let text: String
        if !FileManager.default.fileExists(atPath: p) { text = "" } else { text = try String(contentsOfFile: p, encoding: .utf8) }
        return ["path": .string(p), "text": .string(text)]
    }

    /// The parsed config's own consistency problems (pure, for tests).
    static func warnings(_ cfg: JSON) -> [String] {
        let clusters = Set(cfg["clusters"].items.compactMap { $0["name"].stringish })
        let users = Set(cfg["users"].items.compactMap { $0["name"].stringish })
        var w: [String] = []
        for c in cfg["contexts"].items {
            let name = c["name"].stringish ?? "undefined"
            if let cl = c["context"]["cluster"].stringish?.nilIfEmpty, !clusters.contains(cl) {
                w.append("Context \"\(name)\" names cluster \"\(cl)\", which this file does not have")
            }
            if let u = c["context"]["user"].stringish?.nilIfEmpty, !users.contains(u) {
                w.append("Context \"\(name)\" names user \"\(u)\", which this file does not have")
            }
        }
        if let cur = cfg["current-context"].stringish?.nilIfEmpty, !cfg["contexts"].items.contains(where: { $0["name"].stringish == cur }) {
            w.append("current-context \"\(cur)\" is not one of the contexts in this file")
        }
        return w
    }

    /// `{ok, warnings, contexts}` or `{ok:false, errors}`.
    static func checkText(_ text: String?, realPath: String) async -> JSON {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("serverlife-kubeconfig-\(getpid())-\(Int64(nowMs()))")
        FileManager.default.createFile(atPath: tmp, contents: Data((text ?? "").utf8), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = await Proc.run(KubeBin.findKubectl(), ["config", "view", "--kubeconfig", tmp, "-o", "json"],
                               env: KubeBin.kubectlEnv(), timeout: 15)
        if !r.ok {
            let err = r.err.components(separatedBy: tmp).joined(separator: realPath)
            return ["ok": false, "errors": [.string(KubeBin.humanizeKubectlError(err).nilIfEmpty ?? "kubectl could not read it")]]
        }
        guard let cfg = try? JSON.parse(r.out) else { return ["ok": false, "errors": ["kubectl could not read it as a kubeconfig"]] }
        return ["ok": true, "warnings": JSON(warnings(cfg)), "contexts": .number(Double(cfg["contexts"].items.count))]
    }

    @MainActor static func check(file: String?, text: String?) async throws -> JSON {
        await checkText(text, realPath: try knownKubeconfig(file))
    }

    /// `{ok, path, backup, warnings}` or `{ok:false, errors}`.
    @MainActor static func write(file: String?, text: String?) async throws -> JSON {
        let p = try knownKubeconfig(file)
        let check = await checkText(text, realPath: p)
        if !check["ok"].truthy { return ["ok": false, "errors": check["errors"]] }
        let fm = FileManager.default, backup = "\(p).serverlife-backup"
        var mode = 0o600
        if let attrs = try? fm.attributesOfItem(atPath: p) {
            mode = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o600) & 0o777
            try? fm.removeItem(atPath: backup)
            try fm.copyItem(atPath: p, toPath: backup)
        }
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data((text ?? "").utf8).write(to: URL(fileURLWithPath: p))
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: p)
        return ["ok": true, "path": .string(p), "backup": .string(backup), "warnings": check["warnings"]]
    }
}

/// Settings this owner reads (same keys and defaults as store.js).
extension Store {
    var kubeSettingEnabled: Bool { setting("kubeEnabled", true) }
    var kubeSettingConfigPaths: [String] { settingJSON("kubeconfigPaths").items.compactMap { $0.string } }
    var kubeSettingRefreshSeconds: Double { settingJSON("kubeRefreshSeconds").double ?? 15 }
    var kubeSettingQuietRemote: Bool { settingJSON("quietRemote").bool == true }
    var kubeSettingMfaHosts: [String] { settingJSON("mfaHosts").items.compactMap { $0.stringish } }
}
