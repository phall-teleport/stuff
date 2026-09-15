import Foundation

// MARK: - Beams

struct Beam: Identifiable, Hashable {
    var id: String
    var name: String
    var state: String
    var created: String
    var raw: [String: String]

    /// Maps a `tsh beams ls -f json` row (id, uuid, owner, expires, region…)
    /// onto Beam, tolerating field names from other server versions.
    init(row: [String: Any]) {
        func str(_ keys: String...) -> String {
            for k in keys { if let s = row[k] as? String, !s.isEmpty { return s } }
            return ""
        }
        id = str("id", "name", "uuid")
        name = str("alias", "name", "id")
        state = str("state", "status", "phase").isEmpty ? "running" : str("state", "status", "phase")
        created = str("created", "created_at", "expires")
        var r: [String: String] = [:]
        for (k, v) in row { if let s = v as? String { r[k] = s } else { r[k] = String(describing: v) } }
        raw = r
    }

    init(id: String, name: String, state: String = "running", created: String = "", raw: [String: String] = [:]) {
        self.id = id; self.name = name; self.state = state; self.created = created; self.raw = raw
    }
}

// MARK: - Sessions (same JSON layout as the Go app, so data is shared)

struct Session: Codable, Identifiable, Hashable {
    var id: String
    var beamId: String
    var beamName: String
    var title: String = ""
    var created: Date
    var updated: Date
    var turns: Int = 0
    var costUsd: Double = 0
    var lastSync: String = ""
    var lastError: String = ""
    var publishedUrls: [String] = []

    // Explicit because providing both init(from:) and encode(to:) disables synthesis.
    enum CodingKeys: String, CodingKey {
        case id, beamId, beamName, title, created, updated, turns, costUsd, lastSync, lastError, publishedUrls
    }

    init(id: String, beamId: String, beamName: String) {
        self.id = id; self.beamId = beamId; self.beamName = beamName
        created = Date(); updated = Date()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        beamId = try c.decodeIfPresent(String.self, forKey: .beamId) ?? ""
        beamName = try c.decodeIfPresent(String.self, forKey: .beamName) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        created = RFC3339.parse(try c.decodeIfPresent(String.self, forKey: .created) ?? "") ?? Date()
        updated = RFC3339.parse(try c.decodeIfPresent(String.self, forKey: .updated) ?? "") ?? created
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        lastSync = try c.decodeIfPresent(String.self, forKey: .lastSync) ?? ""
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        publishedUrls = try c.decodeIfPresent([String].self, forKey: .publishedUrls) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(beamId, forKey: .beamId)
        try c.encode(beamName, forKey: .beamName)
        try c.encode(title, forKey: .title)
        try c.encode(RFC3339.string(created), forKey: .created)
        try c.encode(RFC3339.string(updated), forKey: .updated)
        try c.encode(turns, forKey: .turns)
        try c.encode(costUsd, forKey: .costUsd)
        try c.encode(lastSync, forKey: .lastSync)
        try c.encode(lastError, forKey: .lastError)
        try c.encode(publishedUrls, forKey: .publishedUrls)
    }
}

/// Go's time.Time marshals RFC3339 with up to nine fractional digits; Foundation
/// wants at most three, so normalise before parsing.
enum RFC3339 {
    private static let withFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let noFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let fracRe = try! NSRegularExpression(pattern: #"(\.\d{1,3})\d*"#)

    static func parse(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let trimmed = fracRe.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        return withFrac.date(from: trimmed) ?? noFrac.date(from: trimmed) ?? noFrac.date(from: s)
    }

    static func string(_ d: Date) -> String { withFrac.string(from: d) }
}

// MARK: - Config (shared file with the Go app)

struct GitHubConfig: Codable, Equatable {
    var repo: String = ""
    var branch: String = "main"
    var prefix: String = "beams"
    var autoSync: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "main"
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? "beams"
        autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? false
    }
}

struct Config: Codable, Equatable {
    var tshBin: String = "tsh"
    var proxy: String = "super-grass.beams.sh"
    var teleportUser: String = ""
    var login: String = ""
    var workDir: String = "/home/beams/work"
    var permissionMode: String = "bypass"
    var model: String = ""
    var disableAutoOpenApps: Bool = false
    var terminalApp: String = ""      // "", "iterm", "terminal"
    var github: GitHubConfig = GitHubConfig()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tshBin = try c.decodeIfPresent(String.self, forKey: .tshBin) ?? "tsh"
        if tshBin.isEmpty { tshBin = "tsh" }
        proxy = try c.decodeIfPresent(String.self, forKey: .proxy) ?? ""
        teleportUser = try c.decodeIfPresent(String.self, forKey: .teleportUser) ?? ""
        login = try c.decodeIfPresent(String.self, forKey: .login) ?? ""
        workDir = try c.decodeIfPresent(String.self, forKey: .workDir) ?? "/home/beams/work"
        if workDir.isEmpty { workDir = "/home/beams/work" }
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? "bypass"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        disableAutoOpenApps = try c.decodeIfPresent(Bool.self, forKey: .disableAutoOpenApps) ?? false
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp) ?? ""
        github = try c.decodeIfPresent(GitHubConfig.self, forKey: .github) ?? GitHubConfig()
    }
}

struct MemoryFile: Identifiable, Hashable {
    var path: String
    var size: Int64
    var id: String { path }
}

// MARK: - Stream events → transcript items

/// One parsed stream-json line. `raw` keeps the dictionary for ad-hoc access.
struct StreamEvent {
    let type: String
    let subtype: String
    let raw: [String: Any]
    let line: String

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["type"] as? String else { return nil }
        type = t
        subtype = obj["subtype"] as? String ?? ""
        raw = obj
        self.line = line
    }

    var contentBlocks: [[String: Any]] {
        guard let msg = raw["message"] as? [String: Any] else { return [] }
        return msg["content"] as? [[String: Any]] ?? []
    }
}

struct ToolInfo: Hashable {
    var toolUseId: String
    var name: String
    var summary: String
    var inputJSON: String
    var result: String? = nil
    var isError: Bool = false
}

struct TranscriptItem: Identifiable, Hashable {
    enum Kind: Hashable { case user, systemInit, assistant, thinking, tool, stderr, result, permission }
    var id: String
    var kind: Kind
    var text: String = ""
    var ok: Bool = true
    var tool: ToolInfo? = nil
}

extension TranscriptItem {
    /// Converts one event into zero or more items. Tool results don't create
    /// items; they attach to the matching tool call via `attachToolResult`.
    static func items(from ev: StreamEvent, seq: inout Int) -> [TranscriptItem] {
        func nextID() -> String { seq += 1; return "\(seq)" }
        switch ev.type {
        case "beamsui.user":
            return [TranscriptItem(id: nextID(), kind: .user, text: ev.raw["text"] as? String ?? "")]
        case "beamsui.permission":
            // Our own record of a permission decision, so reloads show it.
            let allowed = ev.raw["allowed"] as? Bool ?? false
            let text = "\(allowed ? "allowed" : "denied") \(ev.raw["tool"] as? String ?? "tool") \(ev.raw["summary"] as? String ?? "")"
            return [TranscriptItem(id: nextID(), kind: .permission, text: text, ok: allowed)]
        case "system" where ev.subtype == "init":
            let sid = (ev.raw["session_id"] as? String ?? "").prefix(8)
            let text = "session \(sid) · \(ev.raw["model"] as? String ?? "") · \(ev.raw["cwd"] as? String ?? "") · \(ev.raw["permissionMode"] as? String ?? "")"
            return [TranscriptItem(id: nextID(), kind: .systemInit, text: text)]
        case "assistant":
            var out: [TranscriptItem] = []
            for blk in ev.contentBlocks {
                switch blk["type"] as? String {
                case "text":
                    let t = blk["text"] as? String ?? ""
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(TranscriptItem(id: nextID(), kind: .assistant, text: t))
                    }
                case "tool_use":
                    let input = blk["input"] as? [String: Any] ?? [:]
                    let json = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let info = ToolInfo(toolUseId: blk["id"] as? String ?? "", name: blk["name"] as? String ?? "tool",
                                        summary: toolSummary(input), inputJSON: json)
                    out.append(TranscriptItem(id: nextID(), kind: .tool, tool: info))
                case "thinking":
                    if let t = blk["thinking"] as? String, !t.isEmpty {
                        out.append(TranscriptItem(id: nextID(), kind: .thinking, text: String(t.prefix(600))))
                    }
                default: break
                }
            }
            return out
        case "result":
            let isErr = ev.raw["is_error"] as? Bool ?? false
            let secs = Double(ev.raw["duration_ms"] as? Int ?? 0) / 1000
            let cost = ev.raw["total_cost_usd"] as? Double ?? 0
            let turns = ev.raw["num_turns"] as? Int ?? 0
            var text = "\(isErr ? "error" : "done") · \(turns) turns · \(String(format: "%.1f", secs))s · $\(String(format: "%.4f", cost))"
            if isErr, let r = ev.raw["result"] as? String, !r.isEmpty { text += " · " + String(r.prefix(300)) }
            return [TranscriptItem(id: nextID(), kind: .result, text: text, ok: !isErr)]
        default:
            return []
        }
    }

    static func toolSummary(_ input: [String: Any]) -> String {
        for k in ["description", "command", "file_path", "pattern", "query", "url", "prompt"] {
            if let s = input[k] as? String, !s.isEmpty { return s }
        }
        return input.values.compactMap { $0 as? String }.first ?? ""
    }

    /// Attaches tool_result blocks from a `user` event to their tool calls.
    static func attachToolResults(from ev: StreamEvent, into items: inout [TranscriptItem]) {
        guard ev.type == "user" else { return }
        for blk in ev.contentBlocks where blk["type"] as? String == "tool_result" {
            let id = blk["tool_use_id"] as? String ?? ""
            var text = ""
            if let arr = blk["content"] as? [[String: Any]] {
                text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else if let s = blk["content"] as? String { text = s }
            let isErr = blk["is_error"] as? Bool ?? false
            if let i = items.lastIndex(where: { $0.tool?.toolUseId == id }) {
                items[i].tool?.result = text.count > 20000 ? String(text.prefix(20000)) + "\n… (truncated)" : text
                items[i].tool?.isError = isErr
            }
        }
    }
}
