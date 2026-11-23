import Foundation

// A pod's filesystem as an explorer source (explorer.js `source.kind ===
// 'kube'`). A kube exec pane is local-kind underneath — kubectl runs the way a
// local shell runs a program, with no connection behind it — so its explorer is
// pinned to the pod the pane is exec'd into instead: `kube:<paneId>`, keyed by
// pane because two kube exec panes have no connId in common to tell their view
// state apart by. Everything goes through KubeFS (kubefs.js): listing, mkdir,
// mv and rm as shell one-liners over `kubectl exec`, reading and writing with
// `kubectl cp`.
//
// How a pane becomes one: kube-ui marks the pane it opens with
// `attachments["kubeExec"] = KubeSpec` (or its JSON) — the same mark macros
// read — and the pane's explorer starts on that pod. `explorer-kube-source`
// (args `paneId`, `spec` KubeSpec or JSON) does it for a pane already drawn.

@MainActor
enum XPKube {
    /// The pod each kube exec pane is pinned to, by pane id.
    private(set) static var specs: [String: KubeSpec] = [:]

    static func value(_ paneId: String) -> String { "kube:" + paneId }

    static func spec(for value: String) -> KubeSpec? {
        guard value.hasPrefix("kube:") else { return nil }
        return specs[String(value.dropFirst(5))]
    }

    static func register(_ paneId: String, _ spec: KubeSpec) { specs[paneId] = spec }
    static func forget(_ paneId: String) { specs.removeValue(forKey: paneId) }

    /// A pane's attachment, whichever shape it was left in.
    static func specFrom(_ any: Any?) -> KubeSpec? {
        if let s = any as? KubeSpec { return s }
        if let j = any as? JSON, j.object != nil { return KubeSpec(json: j) }
        if let d = any as? [String: JSON] { return KubeSpec(json: .object(d)) }
        return nil
    }

    final class Provider: XPSourceProvider {
        let prefix = "kube"
        // Not offered to other explorers: kube offers no other pod to switch
        // to here. The pane's own explorer lists "This pod: …" itself.
        func options() -> [XPSourceOption] { [] }
        func fileSource(_ value: String) -> FileSource? {
            guard let s = XPKube.spec(for: value) else { return nil }
            return KubeFileSource(id: value, spec: s)
        }
    }

    static func install() {
        ExplorerSources.register(Provider())
        Actions.shared.register("explorer-kube-source") { ctx in
            guard let pid = ctx.paneId ?? ctx.arg("paneId", as: String.self),
                  let spec = specFrom(ctx.args["spec"]) else { return }
            register(pid, spec)
            let ex = XPPaneExplorers.shared.entry(pid).main
            Task { await ex.pickSource(value(pid)) }
        }
    }

    // MARK: - Transfers (straight `kubectl cp`, no queue)

    /// Straight `kubectl cp` per entry, straight to a real local path — no
    /// transfer queue (that machinery is keyed by a Connection's id, and a
    /// kube exec pane has none), so no pause/resume/speed-cap here, just "it
    /// either copied or it told you why not."
    static func download(_ ex: ExplorerModel, _ entries: [FileEntry], _ localDir: String?) async {
        guard let spec = ex.kubeSpec else { return }
        var dir = localDir
        if dir == nil {
            dir = await Modal.chooseDirectory(ex.window)?.path
            if dir == nil { return }
        }
        guard let dir else { return }
        xpStatus("Downloading \(entries.count) item(s) → \(dir)")
        for e in entries {
            let dest = XP.trimTrailingSlashes(dir) + "/" + e.name
            let r = await KubeFS.downloadPath(spec, e.path, dest)
            if !r["ok"].truthy { xpToast("\(e.name): \(r["error"].string ?? "download failed")", "error"); return }
        }
        xpStatus("Downloaded \(entries.count) item(s) → \(dir)")
    }

    static func upload(_ ex: ExplorerModel, _ localPaths: [String], _ remoteDir: String) async {
        guard let spec = ex.kubeSpec else { return }
        xpStatus("Uploading \(localPaths.count) item(s) → \(remoteDir)")
        for p in localPaths {
            let name = XP.trimTrailingSlashes(p).split(separator: "/").last.map(String.init) ?? p
            let dest = XP.trimTrailingSlashes(remoteDir) + "/" + name
            let r = await KubeFS.uploadPath(spec, p, dest)
            if !r["ok"].truthy { xpToast("\(name): \(r["error"].string ?? "upload failed")", "error"); return }
        }
        xpStatus("Uploaded \(localPaths.count) item(s) → \(remoteDir)")
        Task { await ex.refresh() }
    }
}

extension ExplorerModel {
    var isKube: Bool { kind == "kube" }
    var kubeSpec: KubeSpec? {
        if case .other(let v) = source { return XPKube.spec(for: v) }
        return nil
    }
}

extension XP {
    static func trimTrailingSlashes(_ s: String) -> String {
        var t = s
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// One `kubefs` ls entry `{name, path, type, size, mode, mtime}` as a FileEntry.
    static func kubeEntry(_ j: JSON) -> FileEntry? {
        guard let name = j["name"].string, let path = j["path"].string else { return nil }
        let type = FileType(rawValue: j["type"].string ?? "file") ?? .file
        let mode = j["mode"].double.map { UInt32(max(0, $0)) }
        return FileEntry(name: name, path: path, type: type, targetType: nil,
                         size: Int64(j["size"].double ?? 0), mode: mode,
                         modeString: j["modeString"].string ?? "", mtime: j["mtime"].double,
                         atime: nil, uid: nil, gid: nil, owner: j["owner"].string, group: j["group"].string,
                         links: nil, longname: nil)
    }

    /// `b64FromText` / `textFromB64`: a kube file's bytes travel as base64 — UTF-8 safe.
    static func b64FromText(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    static func textFromB64(_ b64: String) -> String {
        let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}

/// A pod's filesystem through KubeFS. Shaped like a local/SFTP listing so
/// nothing downstream needs to know this isn't one.
final class KubeFileSource: FileSource, @unchecked Sendable {
    let id: String
    let spec: KubeSpec
    let kind = FileSourceKind.sftp   // a remote POSIX tree; FileSourceKind has no kube case
    let capabilities: FileSourceCapabilities = []

    init(id: String, spec: KubeSpec) { self.id = id; self.spec = spec }

    @MainActor var label: String { spec.podName ?? "" }

    func home() async throws -> String { "/" }

    private static func check(_ r: JSON, _ fallback: String) throws {
        if !r["ok"].truthy { throw AppError(r["error"].string?.nilIfEmpty ?? fallback) }
    }

    func list(_ dir: String?) async throws -> FileListing {
        let p = (dir == nil || dir == "." || dir == "" || dir == "~") ? "/" : dir!
        let r = await KubeFS.ls(spec, p)
        try Self.check(r, "Could not list that directory")
        return FileListing(path: p, entries: (r["entries"].array ?? []).compactMap(XP.kubeEntry))
    }

    func stat(_ path: String) async throws -> FileEntry {
        let parent = Posix.parent(path), name = Posix.basename(path)
        let l = try await list(parent)
        if let e = l.entries.first(where: { $0.name == name }) { return e }
        throw AppError("No such file or directory")
    }

    func mkdir(_ path: String) async throws {
        try Self.check(await KubeFS.mkdir(spec, path), "mkdir failed")
    }

    func rename(_ from: String, to: String) async throws {
        try Self.check(await KubeFS.rename(spec, from, to), "rename failed")
    }

    func remove(_ entries: [FileEntry]) async throws {
        for e in entries {
            try Self.check(await KubeFS.rm(spec, e.path), "Could not delete \(e.name)")
        }
    }

    func readText(_ path: String, maxBytes: Int) async throws -> String {
        let r = await KubeFS.readFile(spec, path)
        try Self.check(r, "kubectl cp failed")
        return XP.textFromB64(r["data"].string ?? "")
    }

    func writeText(_ path: String, _ text: String) async throws {
        try Self.check(await KubeFS.writeFile(spec, path, base64: XP.b64FromText(text)), "kubectl cp failed")
    }

    func chmod(_ path: String, mode: UInt32) async throws {
        throw AppError("Permissions inside a pod cannot be changed from here.")
    }

    func search(_ options: FindFiles.Options) async throws -> FindFiles.Outcome {
        throw AppError("Search does not reach into a pod’s filesystem yet")
    }

    func parent(of path: String) -> String { Posix.parent(path) }
    func join(_ dir: String, _ name: String) -> String { Posix.join(dir, name) }
}
