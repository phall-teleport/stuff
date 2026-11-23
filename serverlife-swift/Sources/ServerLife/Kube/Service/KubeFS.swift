import Foundation

/// kubefs.js — browsing a pod's filesystem. There is no SFTP inside a
/// container, so listing/making/removing run as POSIX shell one-liners over
/// `kubectl exec` (shaped for GNU coreutils and BusyBox); reading and writing
/// go through `kubectl cp` (tar over the exec stream — no byte ranges, no resume).
/// `spec` carries contextName/kubeconfigPaths plus namespace/podName/containerName.
enum KubeFS {
    private static func execSh(_ spec: KubeSpec, _ script: String, _ args: [String] = []) async -> KubeRun {
        let k = Kube.kubectlArgsFor(spec)
        var argv = k.baseArgs + ["exec", spec.podName ?? ""]
        if let c = spec.containerName?.nilIfEmpty { argv += ["-c", c] }
        argv += ["--", "sh", "-c", script, "sh"] + args
        return await KubeBin.run(k.bin, argv, env: k.env, timeout: 20, explain: false)
    }

    static func podTarget(_ spec: KubeSpec, _ remotePath: String) -> String {
        "\(spec.namespace ?? "undefined")/\(spec.podName ?? "undefined"):\(remotePath)"
    }

    /// All entries directly inside one directory, hidden files included, `.`/`..` excluded.
    static let lsScript = """

    dir=$1
    for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      stat -c '%n\\t%F\\t%s\\t%Y\\t%a' "$f" 2>/dev/null || stat -c '%n\\t%F\\t%s\\t%Y\\t%a' -L "$f" 2>/dev/null
    done

    """

    static func parseType(_ ftype: String) -> String {
        if TPText.test("directory", ftype, .caseInsensitive) { return "directory" }
        if TPText.test("symbolic", ftype, .caseInsensitive) { return "symlink" }
        return "file"
    }

    /// The pure part of `ls`: stat lines → entries `{name, path, type, size, mode, modeString, mtime, owner, group}`.
    static func parseListing(_ stdout: String, dir cleanDir: String) -> [JSON] {
        stdout.components(separatedBy: "\n").filter { !$0.isEmpty }.compactMap { line -> JSON? in
            let f = line.components(separatedBy: "\t")
            let full = f[0], ftype = f.count > 1 ? f[1] : "", size = f.count > 2 ? f[2] : "", mtime = f.count > 3 ? f[3] : "", mode = f.count > 4 ? f[4] : ""
            let rest = full.utf16.count > cleanDir.utf16.count ? String(full.utf16.dropFirst(cleanDir.utf16.count))! : ""
            let name = rest.replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
            if name.isEmpty { return nil }
            let sz = Double(size.trimmed) ?? 0, mt = Double(mtime.trimmed) ?? 0
            return ["name": .string(name), "path": .string(cleanDir == "/" ? "/" + name : "\(cleanDir)/\(name)"),
                    "type": .string(parseType(ftype)), "size": .number(sz.isNaN ? 0 : sz),
                    "mode": .number(Double(kubeParseOctal(mode))), "modeString": "", "mtime": .number((mt.isNaN ? 0 : mt) * 1000),
                    "owner": .null, "group": .null]
        }
    }

    static func ls(_ spec: KubeSpec, _ dir: String) async -> JSON {
        // Stripped so the "$dir"/* glob never doubles up at the root.
        let cleanDir = dir.replacingOccurrences(of: "/+$", with: "", options: .regularExpression).nilIfEmpty ?? "/"
        let r = await execSh(spec, lsScript, [cleanDir])
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "Could not list that directory"), ["entries": []]) }
        return kubeOk(["entries": .array(parseListing(r.stdout, dir: cleanDir))])
    }

    static func mkdir(_ spec: KubeSpec, _ dir: String) async -> JSON {
        let r = await execSh(spec, "mkdir -p \"$1\"", [dir])
        return r.ok ? kubeOk() : kubeFail(kubeOr(kubePlain(r.stderr), "mkdir failed"))
    }

    /// Recursive, same as the local/SFTP "remove" action — the caller already confirmed.
    static func rm(_ spec: KubeSpec, _ target: String) async -> JSON {
        let r = await execSh(spec, "rm -rf \"$1\"", [target])
        return r.ok ? kubeOk() : kubeFail(kubeOr(kubePlain(r.stderr), "rm failed"))
    }

    static func rename(_ spec: KubeSpec, _ from: String, _ to: String) async -> JSON {
        let r = await execSh(spec, "mv \"$1\" \"$2\"", [from, to])
        return r.ok ? kubeOk() : kubeFail(kubeOr(kubePlain(r.stderr), "mv failed"))
    }

    private static func tmpPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("kubelife-\(Int64(nowMs()))-\(UUID().uuidString.prefix(10).lowercased())")
    }

    private static func cp(_ spec: KubeSpec, _ from: String, _ to: String, timeout: TimeInterval) async -> JSON {
        let k = Kube.kubectlArgsFor(spec)
        let r = await KubeBin.run(k.bin, k.baseArgs + ["cp", from, to], env: k.env, timeout: timeout, explain: false)
        return r.ok ? kubeOk() : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl cp failed"))
    }

    /// `kubectl cp` through a temp file → `{ok, data}` (base64, as upstream).
    static func readFile(_ spec: KubeSpec, _ remotePath: String) async -> JSON {
        let tmp = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = await cp(spec, podTarget(spec, remotePath), tmp, timeout: 30)
        if !r["ok"].truthy { return r }
        guard let d = FileManager.default.contents(atPath: tmp) else { return kubeFail("ENOENT: no such file or directory, open '\(tmp)'") }
        return kubeOk(["data": .string(d.base64EncodedString())])
    }

    static func writeFile(_ spec: KubeSpec, _ remotePath: String, data: Data) async -> JSON {
        let tmp = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do { try data.write(to: URL(fileURLWithPath: tmp)) } catch { return kubeFail(error) }
        return await cp(spec, tmp, podTarget(spec, remotePath), timeout: 30)
    }

    static func writeFile(_ spec: KubeSpec, _ remotePath: String, base64: String?) async -> JSON {
        await writeFile(spec, remotePath, data: Data(base64Encoded: base64 ?? "", options: .ignoreUnknownCharacters) ?? Data())
    }

    /// A file or a whole directory straight to/from disk; 5-minute timeout, no progress, no resume.
    static func downloadPath(_ spec: KubeSpec, _ remotePath: String, _ localPath: String) async -> JSON {
        await cp(spec, podTarget(spec, remotePath), localPath, timeout: 300)
    }

    static func uploadPath(_ spec: KubeSpec, _ localPath: String, _ remotePath: String) async -> JSON {
        await cp(spec, localPath, podTarget(spec, remotePath), timeout: 300)
    }
}

/// `parseInt(s, 8) || 0`: leading octal digits only.
func kubeParseOctal(_ s: String) -> Int {
    let t = s.trimmingCharacters(in: .whitespaces)
    let digits = t.prefix { ("0"..."7").contains($0) }
    return Int(digits, radix: 8) ?? 0
}
