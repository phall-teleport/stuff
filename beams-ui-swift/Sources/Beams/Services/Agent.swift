import Foundation

/// Builds the shell that runs Claude Code inside a beam for one turn, the
/// same protocol the Claude Code CLI uses for programmatic sessions.
struct TurnOptions {
    var sessionID: String
    var resume: Bool
    var workDir: String
    var prompt: String
    var permissionMode: String
    var model: String
    var maxTurns: Int = 0

    /// Anything but bypass means Claude Code will ask before using tools. In
    /// print mode nobody can answer a terminal prompt, so we tell it to route
    /// permission requests over stdin/stdout (`--permission-prompt-tool stdio`)
    /// and answer them from the UI — the same channel the Agent SDK uses.
    var asksPermission: Bool { !["", "bypass", "bypassPermissions"].contains(permissionMode) }

    /// The prompt itself is not on the command line: it is sent as the first
    /// stream-json user message on stdin (see `userMessage`).
    var script: String {
        var s = "set -e\n"
        s += "export PATH=\"$HOME/.local/bin:$PATH\"\n"
        s += "mkdir -p \(Shell.quote(workDir)) && cd \(Shell.quote(workDir))\n"
        s += "exec claude -p --verbose --output-format stream-json --input-format stream-json"
        s += resume ? " --resume \(sessionID)" : " --session-id \(sessionID)"
        if asksPermission {
            s += " --permission-mode \(permissionMode) --permission-prompt-tool stdio"
        } else {
            s += " --dangerously-skip-permissions"
        }
        if !model.isEmpty { s += " --model \(Shell.quote(model))" }
        if maxTurns > 0 { s += " --max-turns \(maxTurns)" }
        s += "\n"
        return s
    }

    static func jsonLine(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// stream-json user message carrying the prompt.
    static func userMessage(_ text: String) -> String {
        jsonLine(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]])
    }

    /// Replies to a `can_use_tool` control request.
    static func allowResponse(requestID: String, input: [String: Any]) -> String {
        jsonLine(["type": "control_response", "response": ["subtype": "success", "request_id": requestID,
                                                             "response": ["behavior": "allow", "updatedInput": input]]])
    }

    static func denyResponse(requestID: String, message: String) -> String {
        jsonLine(["type": "control_response", "response": ["subtype": "success", "request_id": requestID,
                                                             "response": ["behavior": "deny", "message": message]]])
    }

    static func errorResponse(requestID: String, error: String) -> String {
        jsonLine(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": error]])
    }
}

/// A tool-permission question from Claude Code, awaiting the user's answer.
struct PermissionRequest: Identifiable, Hashable {
    var id: String            // request_id
    var sessionID: String
    var toolName: String
    var description: String   // Claude's one-liner, e.g. the file name
    var summary: String       // command / file path etc.
    var inputJSON: String
    var input: [String: Any]
    var suggestsAcceptEdits: Bool

    static func == (a: PermissionRequest, b: PermissionRequest) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    init?(event ev: StreamEvent, sessionID: String) {
        guard ev.type == "control_request",
              let rid = ev.raw["request_id"] as? String,
              let req = ev.raw["request"] as? [String: Any],
              req["subtype"] as? String == "can_use_tool" else { return nil }
        id = rid
        self.sessionID = sessionID
        toolName = req["display_name"] as? String ?? req["tool_name"] as? String ?? "tool"
        description = req["description"] as? String ?? ""
        input = req["input"] as? [String: Any] ?? [:]
        summary = TranscriptItem.toolSummary(input)
        inputJSON = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sugg = req["permission_suggestions"] as? [[String: Any]] ?? []
        suggestsAcceptEdits = sugg.contains { $0["type"] as? String == "setMode" && $0["mode"] as? String == "acceptEdits" }
    }
}

enum AgentScripts {
    /// Streams a gzip tarball of the beam's Claude memory (every
    /// projects/*/memory directory plus the global CLAUDE.md) to stdout.
    static let memoryPull = """
    cd "$HOME/.claude" 2>/dev/null || exit 0
    set -- $(find projects -type d -name memory 2>/dev/null)
    [ -f CLAUDE.md ] && set -- "$@" CLAUDE.md
    [ $# -eq 0 ] && exit 0
    tar czf - "$@"
    """

    static let memoryRestore = #"mkdir -p "$HOME/.claude" && tar xzf - -C "$HOME/.claude""#

    /// Reports the beam's toolchain for the composer hint.
    static let probe = #"whoami; echo "$HOME"; command -v claude >/dev/null 2>&1 && claude --version || echo "claude: not installed""#
}

/// Apps published from a beam with `tsh beams publish` live at
/// https://<beam-alias-port>.<cluster>, so any URL on a subdomain of the
/// configured proxy host is a published app.
enum PublishedURLs {
    static func find(in text: String, proxy: String) -> [String] {
        let host = hostOnly(proxy)
        guard !host.isEmpty else { return [] }
        let pattern = #"(?i)https://[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\."# + NSRegularExpression.escapedPattern(for: host) + #"(?::\d+)?(?:/[^\s"'<>\\)\]]*)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>(); var out: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            var u = String(text[r])
            while let last = u.last, ".,;:".contains(last) { u.removeLast() }
            let key = u.lowercased()
            if key.hasPrefix("https://" + host) { continue }   // the tenant's own web UI
            if !seen.contains(key) { seen.insert(key); out.append(u) }
        }
        return out
    }
}
