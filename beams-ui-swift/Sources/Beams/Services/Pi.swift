import Foundation

/// Builds one local `pi --mode json` turn for a Local session. Unlike
/// Claude/Codex, local sessions run directly on this Mac — no beam, no SSH:
/// `pi` is launched with `Shell.run`, and `--session-id` resumes (or creates)
/// the session's own conversation, so context continues across turns without
/// a persistent process. `cwd` doubles as pi's project directory, which
/// controls its own session grouping and resource discovery.
///
/// v1 scope: no permission-prompt UI (pi doesn't gate tool calls behind one
/// in JSON mode — see docs/security.md), no image attachments, no MCP wiring.
///
/// Uses the same "proxy the agent's Teleport app to this Mac" port Settings
/// already keeps running (AppModel+MCP.swift `reconcileAgentProxy`), via a
/// pi provider pointed at it — e.g. `~/.pi/agent/models.json`'s
/// `teleport-anthropic` (`http://127.0.0.1:<agentProxyPort>`,
/// `api: "anthropic-messages"`), named `"teleport-" + serviceApp` so it
/// tracks `config.agent`/`config.model` instead of a separate pi setting.
/// pi itself must already have that provider configured; this app doesn't
/// write pi's config.
struct PiTurn {
    var workDir: String
    var sessionID: String
    var prompt: String
    var provider: String
    var model: String

    var argv: [String] {
        var a = ["pi", "--mode", "json", "--session-id", sessionID]
        if !provider.isEmpty { a += ["--provider", provider] }
        if !model.isEmpty { a += ["--model", model] }
        return a + ["--", prompt]
    }
}

/// Maps pi's JSON event stream (see docs/json.md) onto the shared
/// TranscriptItem model. Only terminal events produce items — no streaming
/// deltas yet (v1): `message_end` (authoritative assistant content) and
/// `tool_execution_end` (full result, no separate attach step like Claude's
/// tool_result blocks) are enough for a readable transcript.
enum PiEvents {
    static func isPiLine(_ ev: StreamEvent) -> Bool {
        ev.type == "session" || ev.type.hasPrefix("message_") || ev.type.hasPrefix("tool_execution_")
            || ev.type.hasPrefix("agent_") || ev.type.hasPrefix("turn_")
    }

    static func items(from ev: StreamEvent, seq: inout Int) -> [TranscriptItem] {
        func nextID() -> String { seq += 1; return "\(seq)" }
        switch ev.type {
        case "session":
            let sid = (ev.raw["id"] as? String ?? "").prefix(8)
            return [TranscriptItem(id: nextID(), kind: .systemInit, text: "pi session \(sid) · \(ev.raw["cwd"] as? String ?? "")")]

        case "message_end":
            guard let msg = ev.raw["message"] as? [String: Any], msg["role"] as? String == "assistant" else { return [] }
            return contentItems(msg["content"], nextID: nextID)

        case "tool_execution_end":
            let name = ev.raw["toolName"] as? String ?? "tool"
            let args = ev.raw["args"] as? [String: Any] ?? [:]
            var tool = ToolInfo(toolUseId: ev.raw["toolCallId"] as? String ?? nextID(), name: name,
                                summary: TranscriptItem.toolSummary(args), inputJSON: prettyJSON(args))
            tool.result = resultText(ev.raw["result"])
            tool.isError = ev.raw["isError"] as? Bool ?? false
            return [TranscriptItem(id: nextID(), kind: .tool, tool: tool)]

        case "agent_settled":
            let aborted = ev.raw["aborted"] as? Bool ?? false
            return [TranscriptItem(id: nextID(), kind: .result, text: aborted ? "stopped" : "done", ok: !aborted)]

        default:
            return []
        }
    }

    /// Assistant message content blocks: text and thinking. Tool-call blocks
    /// are skipped here — tool_execution_end already carries the full call
    /// plus its result, so mapping both would duplicate the card.
    private static func contentItems(_ content: Any?, nextID: () -> String) -> [TranscriptItem] {
        guard let blocks = content as? [[String: Any]] else {
            if let s = content as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [TranscriptItem(id: nextID(), kind: .assistant, text: s)]
            }
            return []
        }
        var out: [TranscriptItem] = []
        for blk in blocks {
            switch blk["type"] as? String {
            case "text":
                let t = blk["text"] as? String ?? ""
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(TranscriptItem(id: nextID(), kind: .assistant, text: t)) }
            case "thinking":
                let t = blk["thinking"] as? String ?? ""
                if !t.isEmpty { out.append(TranscriptItem(id: nextID(), kind: .thinking, text: String(t.prefix(600)))) }
            default: break
            }
        }
        return out
    }

    private static func resultText(_ result: Any?) -> String {
        if let r = result as? [String: Any], let arr = r["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return (result as? String) ?? ""
    }

    private static func prettyJSON(_ obj: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
