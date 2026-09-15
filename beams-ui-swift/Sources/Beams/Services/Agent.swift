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

    var script: String {
        var s = "set -e\n"
        s += "export PATH=\"$HOME/.local/bin:$PATH\"\n"
        s += "mkdir -p \(Shell.quote(workDir)) && cd \(Shell.quote(workDir))\n"
        s += "exec claude -p --verbose --output-format stream-json"
        s += resume ? " --resume \(sessionID)" : " --session-id \(sessionID)"
        switch permissionMode {
        case "", "bypass", "bypassPermissions": s += " --dangerously-skip-permissions"
        default: s += " --permission-mode \(permissionMode)"
        }
        if !model.isEmpty { s += " --model \(Shell.quote(model))" }
        if maxTurns > 0 { s += " --max-turns \(maxTurns)" }
        s += " -- \(Shell.quote(prompt))\n"
        return s
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
