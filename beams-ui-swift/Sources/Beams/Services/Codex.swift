import Foundation

/// Which agent CLI a turn runs in the beam. Both ship in every beam.
enum AgentKind: String, CaseIterable {
    case claude          // Claude Code (Anthropic models), stream-json protocol
    case codex           // OpenAI Codex CLI, `codex exec --json`

    var label: String { self == .claude ? "Claude Code" : "Codex" }
}

/// Builds one `codex exec` turn. Unlike Claude, the prompt is an argument and
/// there is no interactive permission protocol — beams are externally
/// sandboxed, so we bypass Codex's own approvals. Context continues across
/// turns via `codex exec resume <thread_id>`.
struct CodexTurn {
    var workDir: String
    var model: String
    var prompt: String
    var resumeThread: String   // empty = start a new thread

    var script: String {
        var s = "set -e\n"
        s += "export PATH=\"$HOME/.local/bin:$PATH\"\n"
        s += "mkdir -p \(Shell.quote(workDir)) && cd \(Shell.quote(workDir))\n"
        s += "exec codex exec"
        if !resumeThread.isEmpty { s += " resume \(Shell.quote(resumeThread))" }
        // No --color flag: `codex exec resume` rejects it, and --json output is
        // already plain. --json is accepted by both exec and exec resume.
        s += " --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check"
        if !model.isEmpty { s += " -m \(Shell.quote(model))" }
        s += " -- \(Shell.quote(prompt))\n"
        return s
    }
}

/// Maps Codex's JSONL events onto the shared TranscriptItem model. Only
/// terminal events produce items (item.completed / turn.completed), so
/// started/in-progress duplicates are skipped.
enum CodexEvents {
    static func isCodexLine(_ ev: StreamEvent) -> Bool {
        ev.type.hasPrefix("thread.") || ev.type.hasPrefix("turn.") || ev.type.hasPrefix("item.")
    }

    /// Returns any transcript items plus the thread id when a thread starts.
    static func items(from ev: StreamEvent, seq: inout Int) -> (items: [TranscriptItem], threadID: String?) {
        func nextID() -> String { seq += 1; return "\(seq)" }
        switch ev.type {
        case "thread.started":
            let tid = ev.raw["thread_id"] as? String ?? ""
            let item = TranscriptItem(id: nextID(), kind: .systemInit, text: "codex thread \(tid.prefix(8))")
            return ([item], tid.isEmpty ? nil : tid)

        case "item.completed":
            guard let item = ev.raw["item"] as? [String: Any] else { return ([], nil) }
            switch item["type"] as? String {
            case "agent_message":
                let t = item["text"] as? String ?? ""
                return (t.isEmpty ? [] : [TranscriptItem(id: nextID(), kind: .assistant, text: t)], nil)
            case "reasoning":
                let t = item["text"] as? String ?? item["summary"] as? String ?? ""
                return (t.isEmpty ? [] : [TranscriptItem(id: nextID(), kind: .thinking, text: String(t.prefix(600)))], nil)
            case "file_change":
                let changes = item["changes"] as? [[String: Any]] ?? []
                let paths = changes.compactMap { $0["path"] as? String }.map { ($0 as NSString).lastPathComponent }
                let kinds = Set(changes.compactMap { $0["kind"] as? String })
                var tool = ToolInfo(toolUseId: item["id"] as? String ?? nextID(), name: "Edit",
                                    summary: paths.joined(separator: ", "),
                                    inputJSON: prettyJSON(item))
                tool.result = "\(kinds.sorted().joined(separator: ", ")) · \(item["status"] as? String ?? "completed")"
                tool.isError = (item["status"] as? String) == "failed"
                return ([TranscriptItem(id: nextID(), kind: .tool, tool: tool)], nil)
            case "command_execution":
                var tool = ToolInfo(toolUseId: item["id"] as? String ?? nextID(), name: "Bash",
                                    summary: item["command"] as? String ?? "",
                                    inputJSON: prettyJSON(item))
                tool.result = item["aggregated_output"] as? String ?? item["output"] as? String ?? (item["status"] as? String ?? "")
                tool.isError = (item["exit_code"] as? Int ?? 0) != 0
                return ([TranscriptItem(id: nextID(), kind: .tool, tool: tool)], nil)
            case "error":
                return ([TranscriptItem(id: nextID(), kind: .result, text: item["message"] as? String ?? "error", ok: false)], nil)
            default:
                return ([], nil)
            }

        case "turn.completed":
            let usage = ev.raw["usage"] as? [String: Any] ?? [:]
            let inTok = usage["input_tokens"] as? Int ?? 0
            let outTok = usage["output_tokens"] as? Int ?? 0
            return ([TranscriptItem(id: nextID(), kind: .result, text: "done · \(inTok) in / \(outTok) out tokens", ok: true)], nil)

        case "turn.failed":
            let msg = (ev.raw["error"] as? [String: Any])?["message"] as? String ?? "turn failed"
            return ([TranscriptItem(id: nextID(), kind: .result, text: msg, ok: false)], nil)

        default:
            return ([], nil)
        }
    }

    private static func prettyJSON(_ obj: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
