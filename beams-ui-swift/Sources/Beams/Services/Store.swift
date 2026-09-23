import Foundation

/// Persists config, sessions, transcripts and pulled memory under
/// ~/Library/Application Support/BeamsUI — the same layout as the Go app, so
/// both apps see the same sessions.
final class Store {
    let root: URL

    init() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        root = base.appendingPathComponent("BeamsUI", isDirectory: true)
        for d in ["sessions", "repos"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    private let decoder = JSONDecoder()

    // MARK: config

    var configURL: URL { root.appendingPathComponent("config.json") }

    func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: configURL), let c = try? decoder.decode(Config.self, from: data) else { return Config() }
        return c
    }

    func saveConfig(_ c: Config) throws {
        try writeAtomic(encoder.encode(c), to: configURL)
    }

    // MARK: sessions

    func sessionDir(_ id: String) -> URL { root.appendingPathComponent("sessions/\(id)", isDirectory: true) }
    func memoryDir(_ id: String) -> URL { sessionDir(id).appendingPathComponent("memory", isDirectory: true) }
    /// Snapshot of the beam's working directory (the files the agent generated).
    func workspaceDir(_ id: String) -> URL { sessionDir(id).appendingPathComponent("workspace", isDirectory: true) }
    /// Claude Code's own conversation file, needed for `--resume` in another beam.
    func claudeSessionURL(_ id: String) -> URL { sessionDir(id).appendingPathComponent("claude-session.jsonl") }
    /// Codex rollout file, needed for `codex exec resume` in another beam.
    func codexSessionURL(_ id: String) -> URL { sessionDir(id).appendingPathComponent("codex-session.jsonl") }

    func hasFile(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    func dirHasFiles(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == false
    }
    func transcriptURL(_ id: String) -> URL { sessionDir(id).appendingPathComponent("transcript.jsonl") }
    func repoCacheDir(_ repo: String) -> URL { root.appendingPathComponent("repos/\(repo.replacingOccurrences(of: "/", with: "__"))", isDirectory: true) }

    func saveSession(_ s: Session) throws {
        try FileManager.default.createDirectory(at: sessionDir(s.id), withIntermediateDirectories: true)
        try writeAtomic(encoder.encode(s), to: sessionDir(s.id).appendingPathComponent("meta.json"))
    }

    func loadSession(_ id: String) -> Session? {
        guard let data = try? Data(contentsOf: sessionDir(id).appendingPathComponent("meta.json")) else { return nil }
        return try? decoder.decode(Session.self, from: data)
    }

    func listSessions() -> [Session] {
        let dir = root.appendingPathComponent("sessions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap(loadSession).sorted { $0.updated > $1.updated }
    }

    func deleteSession(_ id: String) throws {
        guard !id.isEmpty, !id.contains("..") else { return }
        try FileManager.default.removeItem(at: sessionDir(id))
    }

    func appendTranscript(_ id: String, line: String) {
        let url = transcriptURL(id)
        try? FileManager.default.createDirectory(at: sessionDir(id), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func readTranscript(_ id: String) -> [String] {
        guard let s = try? String(contentsOf: transcriptURL(id), encoding: .utf8) else { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: memory

    func listMemory(_ id: String) -> [MemoryFile] {
        let base = memoryDir(id)
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var out: [MemoryFile] = []
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard vals?.isRegularFile == true else { continue }
            let rel = url.path.replacingOccurrences(of: base.path + "/", with: "")
            out.append(MemoryFile(path: rel, size: Int64(vals?.fileSize ?? 0)))
        }
        return out.sorted { $0.path < $1.path }
    }

    func readMemoryFile(_ id: String, _ rel: String) -> String {
        guard !rel.contains("..") else { return "" }
        return (try? String(contentsOf: memoryDir(id).appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    /// Replaces the session's memory snapshot with the contents of a gzip tarball.
    func replaceMemory(_ id: String, tarGz: Data) async throws {
        try await unpack(tarGz, into: memoryDir(id))
    }

    /// Replaces the session's workspace snapshot with the beam's working dir.
    func replaceWorkspace(_ id: String, tarGz: Data) async throws {
        try await unpack(tarGz, into: workspaceDir(id))
    }

    private func unpack(_ tarGz: Data, into dst: URL) async throws {
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try await Shell.run(["/usr/bin/tar", "xzf", "-", "-C", dst.path], stdin: tarGz)
    }

    /// Packs a directory (laid out like ~/.claude) into a gzip tarball.
    func tarGz(directory: URL) async throws -> (Data, Int) {
        let count = (FileManager.default.enumerator(atPath: directory.path)?.allObjects.count) ?? 0
        let res = try await Shell.run(["/usr/bin/tar", "czf", "-", "-C", directory.path, "."])
        return (res.stdout, count)
    }

    // MARK: rendering

    /// Readable Markdown of a transcript for committing next to the raw JSONL.
    func renderMarkdown(_ s: Session, lines: [String]) -> String {
        var md = "# \(s.title.isEmpty ? "Beam session" : s.title)\n\n"
        md += "- Session: `\(s.id)`\n- Beam: `\(s.beamName)`\n- Started: \(RFC3339.string(s.created))\n- Turns: \(s.turns)\n- Cost: $\(String(format: "%.4f", s.costUsd))\n\n---\n\n"
        for ln in lines {
            guard let ev = StreamEvent(line: ln) else { continue }
            switch ev.type {
            case "beamsui.user":
                md += "## You\n\n\(ev.raw["text"] as? String ?? "")\n\n"
            case "assistant":
                for blk in ev.contentBlocks {
                    switch blk["type"] as? String {
                    case "text": md += "\(blk["text"] as? String ?? "")\n\n"
                    case "tool_use":
                        let input = blk["input"] ?? [:]
                        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        md += "<details><summary>Tool: \(blk["name"] as? String ?? "")</summary>\n\n```json\n\(json)\n```\n\n</details>\n\n"
                    default: break
                    }
                }
            case "result":
                let isErr = ev.raw["is_error"] as? Bool ?? false
                let secs = Double(ev.raw["duration_ms"] as? Int ?? 0) / 1000
                let cost = ev.raw["total_cost_usd"] as? Double ?? 0
                md += "_\(isErr ? "error" : "done") · \(String(format: "%.1f", secs))s · $\(String(format: "%.4f", cost))_\n\n---\n\n"
            default: break
            }
        }
        return md
    }

    private func writeAtomic(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
