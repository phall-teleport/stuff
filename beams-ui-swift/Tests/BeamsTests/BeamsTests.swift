import Testing
import Foundation
@testable import Beams

// Swift Testing rather than XCTest: XCTest ships only with Xcode, while the
// Command Line Tools carry the Testing library and its macro plugin.

@Test func publishedURLs() {
    let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Live:\n\n**https://mild-moon-7727.super-grass.beams.sh**\n\nDocs: https://super-grass.beams.sh/web/apps and https://MILD-MOON-7727.super-grass.beams.sh/play?x=1."}]}}"#
    #expect(PublishedURLs.find(in: line, proxy: "super-grass.beams.sh:443") ==
            ["https://mild-moon-7727.super-grass.beams.sh", "https://MILD-MOON-7727.super-grass.beams.sh/play?x=1"])
    #expect(PublishedURLs.find(in: "nothing https://example.com", proxy: "super-grass.beams.sh").isEmpty)
    #expect(PublishedURLs.find(in: "https://x.super-grass.beams.sh", proxy: "").isEmpty)
}

@Test func turnScript() {
    let o = TurnOptions(sessionID: "abc", resume: false, workDir: "/home/beams/work", prompt: "say 'hi'", permissionMode: "bypass", model: "")
    #expect(o.script.contains("--session-id abc"))
    #expect(o.script.contains("--dangerously-skip-permissions"))
    #expect(o.script.contains("--input-format stream-json"))
    #expect(!o.script.contains("say"))                      // prompt goes over stdin, not argv
    #expect(!o.script.contains("--permission-prompt-tool"))
    let r = TurnOptions(sessionID: "abc", resume: true, workDir: "/w", prompt: "x", permissionMode: "plan", model: "claude-sonnet-5")
    #expect(r.script.contains("--resume abc"))
    #expect(r.script.contains("--permission-mode plan --permission-prompt-tool stdio"))
    #expect(r.script.contains("--model 'claude-sonnet-5'"))
    #expect(r.asksPermission && !o.asksPermission)
}

@Test func controlProtocolMessages() throws {
    let user = TurnOptions.userMessage("say 'hi'")
    let obj = try #require(try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any])
    #expect(obj["type"] as? String == "user")
    let allow = TurnOptions.allowResponse(requestID: "r1", input: ["file_path": "/x"])
    #expect(allow.contains("\"behavior\":\"allow\"") && allow.contains("\"request_id\":\"r1\""))
    #expect(TurnOptions.denyResponse(requestID: "r1", message: "no").contains("\"behavior\":\"deny\""))

    let line = #"{"type":"control_request","request_id":"393370a2","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/home/beams/work/perm-test.txt","content":"hello\n"},"description":"perm-test.txt","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_1"}}"#
    let ev = try #require(StreamEvent(line: line))
    let req = try #require(PermissionRequest(event: ev, sessionID: "s"))
    #expect(req.id == "393370a2")
    #expect(req.toolName == "Write")
    #expect(req.summary == "/home/beams/work/perm-test.txt")
    #expect(req.suggestsAcceptEdits)
    #expect(PermissionRequest(event: try #require(StreamEvent(line: #"{"type":"result"}"#)), sessionID: "s") == nil)
}

@Test func rfc3339RoundTripWithGoFractions() {
    #expect(RFC3339.parse("2026-09-11T09:44:50.123456789-07:00") != nil)
    #expect(RFC3339.parse("2026-09-12T16:34:44Z") != nil)
    #expect(RFC3339.parse(RFC3339.string(Date())) != nil)
    #expect(RFC3339.parse("") == nil)
}

@Test func sessionDecodesGoJSON() throws {
    let json = #"{"id":"85df6e3c","beamId":"mild-moon","beamName":"mild-moon","title":"blackjack","created":"2026-09-11T09:44:50.5-07:00","updated":"2026-09-11T10:01:02.123456-07:00","turns":2,"costUsd":0.4391,"lastSync":"","lastError":"","publishedUrls":["https://mild-moon-7727.super-grass.beams.sh"]}"#
    let s = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    #expect(s.turns == 2)
    #expect(s.publishedUrls.count == 1)
    let again = try JSONDecoder().decode(Session.self, from: try JSONEncoder().encode(s))
    #expect(again.id == s.id)
    #expect(again.costUsd == s.costUsd)
}

@Test func streamEventItems() throws {
    var seq = 0
    let ev = try #require(StreamEvent(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","description":"List"}}]}}"#))
    var items = TranscriptItem.items(from: ev, seq: &seq)
    #expect(items.count == 2)
    #expect(items[1].tool?.summary == "List")
    let res = try #require(StreamEvent(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb","is_error":false}]}}"#))
    TranscriptItem.attachToolResults(from: res, into: &items)
    #expect(items[1].tool?.result == "a\nb")
}

@Test func markdownBlocksAndLinkify() {
    let blocks = MarkdownBlocks.parse("# Title\n\npara one\n\n- a\n- b\n\n```bash\nls\n```\n")
    #expect(blocks.count == 4)
    #expect(MarkdownBlocks.linkify("see https://x.example.com/a?b=1. ok") == "see [https://x.example.com/a?b=1](https://x.example.com/a?b=1). ok")
    #expect(MarkdownBlocks.linkify("[docs](https://d.example.com)") == "[docs](https://d.example.com)")
}

@Test func codexTurnScript() {
    let t = CodexTurn(workDir: "/home/beams/work", model: "gpt-5-codex", prompt: "make a thing", resumeThread: "")
    #expect(t.script.contains("codex exec --json"))
    #expect(t.script.contains("--dangerously-bypass-approvals-and-sandbox"))
    #expect(t.script.contains("-m 'gpt-5-codex'"))
    #expect(t.script.contains("-- 'make a thing'"))
    #expect(!t.script.contains("resume"))
    #expect(!t.script.contains("--color"))   // `codex exec resume` rejects --color
    let r = CodexTurn(workDir: "/w", model: "", prompt: "x", resumeThread: "01a0")
    #expect(r.script.contains("codex exec resume '01a0' --json"))
    #expect(!r.script.contains("--color"))
}

@Test func codexEventMapping() throws {
    var seq = 0
    let started = try #require(StreamEvent(line: #"{"type":"thread.started","thread_id":"01a0a64b-9408-7441"}"#))
    let (i0, tid) = CodexEvents.items(from: started, seq: &seq)
    #expect(tid == "01a0a64b-9408-7441")
    #expect(i0.first?.kind == .systemInit)

    let msg = try #require(StreamEvent(line: #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"I'll create z.txt."}}"#))
    #expect(CodexEvents.items(from: msg, seq: &seq).items.first?.kind == .assistant)

    let fc = try #require(StreamEvent(line: #"{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/home/beams/work/codextest/z.txt","kind":"add"}],"status":"completed"}}"#))
    let fcItem = CodexEvents.items(from: fc, seq: &seq).items.first
    #expect(fcItem?.kind == .tool)
    #expect(fcItem?.tool?.name == "Edit")
    #expect(fcItem?.tool?.summary == "z.txt")

    let done = try #require(StreamEvent(line: #"{"type":"turn.completed","usage":{"input_tokens":20422,"output_tokens":142}}"#))
    let dItem = CodexEvents.items(from: done, seq: &seq).items.first
    #expect(dItem?.kind == .result && dItem?.ok == true)
    #expect(dItem?.text.contains("20422 in") == true)

    #expect(CodexEvents.isCodexLine(started) && !CodexEvents.isCodexLine(msg) == false)
    let claudeEv = try #require(StreamEvent(line: #"{"type":"assistant","message":{"content":[]}}"#))
    #expect(!CodexEvents.isCodexLine(claudeEv))
}

@Test func workspacePullScript() {
    let s = AgentScripts.workspacePull(workDir: "/home/beams/work")
    #expect(s.contains("cd '/home/beams/work'"))
    #expect(s.contains("tar czf -"))
    #expect(s.contains("--exclude='./node_modules'"))
    #expect(s.contains("--exclude='./.git'"))
    #expect(s.contains("--exclude='./target'"))
}

@Test func claudeProjectSlug() {
    // Verified in a beam: /home/beams/work → -home-beams-work
    #expect(ClaudePaths.projectSlug("/home/beams/work") == "-home-beams-work")
    #expect(ClaudePaths.projectSlug("/home/beams/my.proj_x") == "-home-beams-my-proj-x")
}

@Test func conversationScripts() {
    let r = AgentScripts.claudeSessionRestore(sessionID: "abc", workDir: "/home/beams/work")
    #expect(r.contains(#""$HOME/.claude/projects/-home-beams-work""#))
    #expect(r.contains("cat > "))
    #expect(r.contains("'abc.jsonl'"))
    #expect(AgentScripts.claudeSessionPull(sessionID: "abc").contains("'abc.jsonl'"))
    // A path coming back from a beam can't break out of the quotes.
    let evil = AgentScripts.codexSessionRestore(relPath: #"sessions/"$(rm -rf ~)"/../x.jsonl"#)
    #expect(!evil.contains("$(rm"))
    #expect(!evil.contains(".."))
    #expect(AgentScripts.codexSessionRestore(relPath: "sessions/2026/09/16/rollout-1-abc.jsonl")
        .contains(#""$HOME/.codex/sessions/2026/09/16/rollout-1-abc.jsonl""#))
    #expect(AgentScripts.previousSessionWrite(workDir: "/home/beams/work").contains("'/home/beams/work/.beams/previous-session.md'"))
}

@Test func scanPreviousSessions() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("beams-scan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let fm = FileManager.default

    // Old-style session: transcript.md header only, no meta.json.
    let old = base.appendingPathComponent("old-1")
    try fm.createDirectory(at: old.appendingPathComponent("workspace"), withIntermediateDirectories: true)
    try "hi".write(to: old.appendingPathComponent("workspace/main.go"), atomically: true, encoding: .utf8)
    try "# make a blackjack app\n\n- Session: `old-1`\n- Beam: `mild-moon`\n- Started: 2026-09-11T09:44:50-07:00\n- Turns: 2\n- Cost: $0.43\n"
        .write(to: old.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

    // New-style session: meta.json and Claude's conversation file.
    let new = base.appendingPathComponent("new-2")
    try fm.createDirectory(at: new, withIntermediateDirectories: true)
    var s = Session(id: "new-2", beamId: "polar-panel", beamName: "polar-panel")
    s.title = "raleigh guide"; s.turns = 5
    s.updated = Date()
    try JSONEncoder().encode(s).write(to: new.appendingPathComponent("meta.json"))
    try "{}\n".write(to: new.appendingPathComponent("claude-session.jsonl"), atomically: true, encoding: .utf8)

    let found = GitHubSync.scanSessions(in: base)
    #expect(found.map(\.id) == ["new-2", "old-1"])            // newest first
    let o = try #require(found.first { $0.id == "old-1" })
    #expect(o.title == "make a blackjack app" && o.beamName == "mild-moon" && o.turns == 2)
    #expect(o.hasWorkspace && !o.resumable)
    let n = try #require(found.first { $0.id == "new-2" })
    #expect(n.title == "raleigh guide" && n.turns == 5 && n.resumable && !n.hasWorkspace)
    #expect(GitHubSync.scanSessions(in: base.appendingPathComponent("missing")).isEmpty)
}

@Test func sessionPickupFieldsRoundTrip() throws {
    var s = Session(id: "x", beamId: "b", beamName: "b")
    s.needsFreshStart = true; s.codexSessionRel = "sessions/a.jsonl"
    let back = try JSONDecoder().decode(Session.self, from: try JSONEncoder().encode(s))
    #expect(back.needsFreshStart && back.codexSessionRel == "sessions/a.jsonl")
    // Older meta without the fields still decodes.
    let old = try JSONDecoder().decode(Session.self, from: Data(#"{"id":"y","beamId":"b","beamName":"b"}"#.utf8))
    #expect(!old.needsFreshStart && old.codexSessionRel.isEmpty)
}

@Test func secretsRedaction() throws {
    let pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\nAbCdEf012345\n-----END PRIVATE KEY-----"
    #expect(Secrets.redact("key:\n\(pem)\nafter") == "key:\n[REDACTED PRIVATE KEY]\nafter")
    #expect(!Secrets.redact("-----BEGIN PIV YUBIKEY PRIVATE KEY-----\nabc").contains("BEGIN PIV"))
    #expect(Secrets.redact("TOKEN=resource-monitor-bot-abc123def456") == "TOKEN=[REDACTED]")
    #expect(Secrets.redact("export API_KEY=\"sk_live_abcdefgh1234\"").contains("[REDACTED]"))
    #expect(Secrets.redact("ghp_" + String(repeating: "a1B2", count: 9)) == "[REDACTED TOKEN]")
    let jwt = "eyJhbGciOiJFZERTQSIsImtpZCI6IjEyMyJ9.eyJzdWIiOiJib3QtbW9uaXRvciJ9.c2lnbmF0dXJlLWJ5dGVz"
    #expect(Secrets.redact("cert \(jwt) end") == "cert [REDACTED JWT] end")

    // A transcript line: key printed by a tool, with JSON-escaped newlines and
    // an escaped .env inside the string. Must stay valid JSON after redaction.
    let line = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"-----BEGIN PRIVATE KEY-----\nMIIEvQIBADAN\n-----END PRIVATE KEY-----\n\"token\": \"abcdefgh12345678\"\nTOKEN=a0b91bf133b5f5a914"}]},"usage":{"input_tokens":2678,"cache_read_input_tokens":123456789,"output_tokens":42}}"#
    let clean = Secrets.redact(line)
    #expect(!clean.contains("MIIEvQ") && !clean.contains("abcdefgh12345678") && !clean.contains("a0b91bf133"))
    #expect(clean.contains("123456789"))                       // numeric token counts untouched
    #expect((try? JSONSerialization.jsonObject(with: Data(clean.utf8))) != nil)

    // Harmless text is untouched.
    let prose = "Set the token in Settings, then run go test. input_tokens: 42"
    #expect(Secrets.redact(prose) == prose)
    #expect(!Secrets.containsSecret(prose))
}

@Test func redactFilesAndExcludes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("beams-secrets-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("app"), withIntermediateDirectories: true)
    try "package main\n".write(to: dir.appendingPathComponent("app/main.go"), atomically: true, encoding: .utf8)
    try "PORT=8080\nSECRET=supersecretvalue99\n".write(to: dir.appendingPathComponent("app/config.txt"), atomically: true, encoding: .utf8)
    #expect(Secrets.redactFiles(in: dir) == ["app/config.txt"])
    #expect(try String(contentsOf: dir.appendingPathComponent("app/config.txt"), encoding: .utf8) == "PORT=8080\nSECRET=[REDACTED]\n")
    // The workspace tar skips well-known secret files and nested session copies.
    let s = AgentScripts.workspacePull(workDir: "/home/beams/work")
    for p in [".env", "*.pem", "id_ed25519*", "tokenhash", "identity", "*/beams/sessions"] {
        #expect(s.contains("--exclude='\(p)'"), "missing exclude \(p)")
    }
}

@Test func beamExpiryFormatting() {
    #expect(BeamRow.expiry(nil) == "unknown")
    #expect(BeamRow.expiry("") == "unknown")
    #expect(BeamRow.expiry("not-a-date") == "not-a-date")
    let future = RFC3339.string(Date().addingTimeInterval(3 * 3600))
    #expect(BeamRow.expiry(future).contains("(") && !BeamRow.expiry(future).contains("expired"))
    #expect(BeamRow.expiry(RFC3339.string(Date().addingTimeInterval(-3600))).contains("expired"))
}

@Test func shellQuoteAndHost() {
    #expect(Shell.quote("a'b") == #"'a'\''b'"#)
    #expect(hostOnly("https://super-grass.beams.sh:443/x") == "super-grass.beams.sh")
}
