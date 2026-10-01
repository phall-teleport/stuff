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
    // The beam's API proxies and ordinary tenant apps are not published apps.
    let env = "ANTHROPIC_BASE_URL=https://anthropic.super-grass.beams.sh OPENAI_BASE_URL=https://openai.super-grass.beams.sh see https://grafana.super-grass.beams.sh"
    #expect(PublishedURLs.find(in: env, proxy: "super-grass.beams.sh").isEmpty)
    #expect(PublishedURLs.isPublishedApp("https://quiet-river-8080.super-grass.beams.sh/", proxy: "super-grass.beams.sh"))
    #expect(!PublishedURLs.isPublishedApp("https://anthropic.super-grass.beams.sh", proxy: "super-grass.beams.sh"))
    #expect(!PublishedURLs.isPublishedApp("https://mild-moon-7727.other.example", proxy: "super-grass.beams.sh"))
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

@Test func tshLoginFlags() {
    var t = TshClient(bin: "tsh", proxy: "super-grass.beams.sh", login: "")
    #expect(t.loginCommand(user: "paul") == "tsh login --proxy=super-grass.beams.sh --user=paul")
    t.auth = "google-saml"; t.mfaBrowser = true
    #expect(t.loginCommand(user: "") == "tsh login --proxy=super-grass.beams.sh --auth=google-saml --mfa-mode=browser")
    t.auth = "google-saml; rm -rf ~"                 // can't smuggle shell into the Terminal hand-off
    #expect(t.authConnector == "google-samlrm-rf")
    #expect(TshClient.env["TELEPORT_USE_LOCAL_SSH_AGENT"] == "false")
}

@Test func sshLoginDeniedDetection() {
    // The exact errors from the cluster's audit log and tsh.
    #expect(TshClient.isSSHLoginDenied(#"ssh: principal "beams" not in the set of valid principals for given certificate: ["-teleport-nologin-46dc"]"#))
    #expect(TshClient.isSSHLoginDenied("ERROR: access denied to beams connecting to beam-7853401c"))
    #expect(TshClient.isSSHLoginDenied("ssh: handshake failed: ssh: unable to authenticate, attempted methods [none publickey]"))
    #expect(!TshClient.isSSHLoginDenied("claude: command not found"))
}

@MainActor @Test func sshBlockedWithoutBeamsLogin() throws {
    let model = try AppModel()
    model.config.login = ""
    model.tsh = TshStatus(tshFound: true, loggedIn: true, proxy: "super-grass.beams.sh", user: "paul@geekvoice.net",
                          cluster: "super-grass.beams.sh", roles: ["access", "beam-admin", "editor"], logins: [])
    let reason = try #require(model.sshBlockedReason)
    #expect(reason.contains("paul@geekvoice.net") && reason.contains("“beams”") && reason.contains("beam-admin"))
    model.tsh.logins = ["beams", "root"]
    #expect(model.sshBlockedReason == nil)
    model.tsh.logins = nil                              // tsh didn't report logins: don't block up front
    #expect(model.sshBlockedReason == nil)
    model.tsh.loggedIn = false                          // the login banner covers this case
    model.tsh.logins = []
    #expect(model.sshBlockedReason == nil)
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

@Test func mcpClaudeConfig() throws {
    let servers = [
        MCPServer(kind: .teleport, name: "grafana"),
        MCPServer(kind: .laptop, name: "Home Assistant", port: 8931, path: "api/mcp"),
        MCPServer(kind: .teleport, name: "off", enabled: false),
        MCPServer(kind: .laptop, name: "bad", port: 0),
    ]
    let json = try #require(MCPConfig.claudeJSON(servers))
    let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: [String: Any]]])
    let map = try #require(obj["mcpServers"])
    #expect(Set(map.keys) == ["grafana", "home-assistant"])
    #expect(map["grafana"]?["command"] as? String == "tsh")
    #expect(map["grafana"]?["args"] as? [String] == ["mcp", "connect", "grafana"])
    #expect(map["home-assistant"]?["url"] as? String == "http://127.0.0.1:8931/api/mcp")
    #expect(MCPConfig.claudeJSON([]) == nil)
    #expect(MCPConfig.laptopPorts(servers) == [8931])

    let turn = TurnOptions(sessionID: "s", resume: false, workDir: "/w", prompt: "", permissionMode: "bypass", model: "", mcpServers: servers)
    #expect(turn.script.contains("--mcp-config '"))
    #expect(turn.script.contains("for p in 8931;"))
    let plain = TurnOptions(sessionID: "s", resume: false, workDir: "/w", prompt: "", permissionMode: "bypass", model: "")
    #expect(!plain.script.contains("mcp"))
}

@Test func mcpCodexAndTsh() {
    let s = [MCPServer(kind: .teleport, name: "gh; rm -rf /"), MCPServer(kind: .laptop, name: "x", port: 9000, path: "")]
    #expect(MCPConfig.codexOverrides(s) == [
        #"mcp_servers.gh--rm--rf--.command="tsh""#,
        #"mcp_servers.gh--rm--rf--.args=["mcp","connect","ghrm-rf/"]"#,
        #"mcp_servers.x.url="http://127.0.0.1:9000""#,
    ])
    let tc = TshClient(bin: "tsh", proxy: "super-grass.beams.sh", login: "beams")
    #expect(tc.tunnelArgs(nodeUUID: "u-1", login: "beams", ports: [1, 2]) ==
            ["tsh", "--proxy=super-grass.beams.sh", "ssh", "-N", "-R", "1:127.0.0.1:1", "-R", "2:127.0.0.1:2", "beams@u-1"])
    let px = MCPServer(kind: .laptop, name: "g", port: 7000, proxyApp: "grafana-mcp", proxyCluster: "other.example.com")
    #expect(tc.proxyAppArgs(px) == ["tsh", "--proxy=other.example.com", "proxy", "app", "--browser=none", "--port", "7000", "grafana-mcp"])
    #expect(tc.proxyAppCommand(px)[2] == "'tsh' '--proxy=other.example.com' 'apps' 'login' 'grafana-mcp' >&2 && exec 'tsh' '--proxy=other.example.com' 'proxy' 'app' '--browser=none' '--port' '7000' 'grafana-mcp'")
    #expect(tc.proxyHost(px) == "other.example.com")
    #expect(tc.proxyHost(MCPServer(kind: .laptop, name: "h", port: 1)) == "super-grass.beams.sh")
}

@Test func mcpListParsing() throws {
    #expect(MCPApp.parse(NSNull()).isEmpty)
    let rows: Any = [["kind": "app", "metadata": ["name": "grafana", "description": "Dashboards"], "spec": ["uri": "mcp+stdio://"]], ["name": "flat"]]
    #expect(MCPApp.parse(rows).map(\.name) == ["grafana", "flat"])
    #expect(MCPApp.parse(rows).first?.uri == "mcp+stdio://")
}

@Test func mcpConfigDecodesOldFiles() throws {
    let cfg = try JSONDecoder().decode(Config.self, from: Data(#"{"proxy":"p"}"#.utf8))
    #expect(cfg.mcpServers.isEmpty)
}

// Supervisor tests run real (tiny) child processes.

private func runs(_ file: String) -> Int {
    ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").count
}

@MainActor @Test func supervisorRestartsWithBackoff() async throws {
    let f = NSTemporaryDirectory() + "sup-\(UUID().uuidString)"
    let sup = Supervisor(key: "t", command: { .success(["/bin/sh", "-c", "echo run >> '\(f)'; exit 1"]) })
    sup.start()
    try await Task.sleep(for: .seconds(2.6))   // run, 1s backoff, run, 2s backoff…
    sup.stop()
    #expect(runs(f) == 2)
    #expect(sup.state == .stopped)
}

@MainActor @Test func supervisorWaitsOnLoginPrompt() async throws {
    let f = NSTemporaryDirectory() + "sup-\(UUID().uuidString)"
    var states: [Supervisor.State] = []
    let sup = Supervisor(key: "t", command: {
        .success(["/bin/sh", "-c", "echo run >> '\(f)'; echo 'If browser window does not open automatically, open it by clicking on the link:'; exec sleep 30"])
    }, onState: { states.append($0) })
    sup.start()
    try await Task.sleep(for: .seconds(2.5))
    #expect(runs(f) == 1)                        // killed, and not restarted
    #expect(sup.state == .waiting("waiting for tsh login"))
    #expect(!sup.isRunning)
    sup.resume()                                 // a login happened
    try await Task.sleep(for: .seconds(1))
    #expect(runs(f) == 2)
    sup.stop()
    #expect(states.contains(.running))
}

@MainActor @Test func supervisorDoesNotStartWhileLoggedOut() async throws {
    var ready = false
    let f = NSTemporaryDirectory() + "sup-\(UUID().uuidString)"
    let sup = Supervisor(key: "t", command: {
        ready ? .success(["/bin/sh", "-c", "echo run >> '\(f)'; exec sleep 31.7"]) : .failure(.init(text: "waiting for a tsh login"))
    })
    sup.start()
    try await Task.sleep(for: .seconds(0.5))
    #expect(sup.state == .waiting("waiting for a tsh login"))
    #expect(runs(f) == 0)
    ready = true
    sup.resume()
    try await Task.sleep(for: .seconds(1))
    #expect(sup.isRunning && runs(f) == 1)
    sup.stop()
    // No orphaned child (allow a moment for the wrapper to notice).
    var alive = true
    for _ in 0..<20 where alive {
        try await Task.sleep(for: .seconds(0.25))
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "sleep 31.7"]
        try p.run(); p.waitUntilExit()
        alive = p.terminationStatus == 0
    }
    #expect(!alive)
}

@Test func loginPromptDetection() {
    #expect(Supervisor.looksLikeLoginPrompt("If browser window does not open automatically, open it by clicking on the link:"))
    #expect(Supervisor.looksLikeLoginPrompt("Enter password for Teleport user paul:"))
    #expect(!Supervisor.looksLikeLoginPrompt("Proxying connections to grafana on 127.0.0.1:7000"))
}

@Test func workspaceDownloadScript() {
    let s = AgentScripts.workspaceDownload(workDir: "/home/beams/work")
    #expect(s.contains("cd '/home/beams/work'"))
    #expect(s.contains("--exclude='*/node_modules'") && s.contains("--exclude='.env'"))
    #expect(!s.contains(".git'") && !s.contains("./dist"))   // a local copy keeps git history and build output
}

@Test func extractStaysInsideFolder() async throws {
    let root = NSTemporaryDirectory() + "extract-\(UUID().uuidString)"
    let src = root + "/src", dst = root + "/dst"
    try FileManager.default.createDirectory(atPath: src + "/sub", withIntermediateDirectories: true)
    try "a".write(toFile: src + "/a.txt", atomically: true, encoding: .utf8)
    try "b".write(toFile: src + "/sub/b.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
    try "keep".write(toFile: dst + "/mine.txt", atomically: true, encoding: .utf8)
    let tgz = try await Shell.run(["/usr/bin/tar", "czf", "-", "-C", src, "."]).stdout
    #expect(try await AppModel.extract(tgz, into: dst) == 2)
    #expect(FileManager.default.fileExists(atPath: dst + "/sub/b.txt"))
    #expect(FileManager.default.fileExists(atPath: dst + "/mine.txt"))   // nothing else deleted

    // An archive with a ../ entry must not write outside the folder.
    let evil = try await Shell.run(["/usr/bin/tar", "czf", "-", "-C", src + "/sub", "-P", "-s", ",^,../escaped-,", "b.txt"]).stdout
    _ = try? await AppModel.extract(evil, into: dst)
    #expect(!FileManager.default.fileExists(atPath: root + "/escaped-b.txt"))
}

@Test func sessionLocalFolderRoundTrip() throws {
    var s = Session(id: "x", beamId: "b", beamName: "b")
    s.localFolder = "/Users/me/out"; s.localSaved = "2026-09-30T12:00:00Z"
    let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
    #expect(back.localFolder == "/Users/me/out" && back.localSaved == "2026-09-30T12:00:00Z")
}

// Writes the generated download script to $BEAMS_DUMP_DOWNLOAD_SCRIPT (skipped otherwise).
@Test func dumpDownloadScript() throws {
    guard let out = ProcessInfo.processInfo.environment["BEAMS_DUMP_DOWNLOAD_SCRIPT"] else { return }
    try AgentScripts.workspaceDownload(workDir: "/home/beams/work").write(toFile: out, atomically: true, encoding: .utf8)
}

// Times Secrets.redact on every pulled workspace file (read-only); set BEAMS_REDACT_TIMING=1.
@Test func redactTiming() throws {
    guard ProcessInfo.processInfo.environment["BEAMS_REDACT_TIMING"] != nil else { return }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BeamsUI/sessions")
    var rows: [(Double, Int, String)] = []
    for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
        guard url.path.contains("/workspace/"), let d = try? Data(contentsOf: url), d.count <= 2_000_000, !d.contains(0) else { continue }
        let t = Date(); _ = Secrets.redact(String(decoding: d, as: UTF8.self))
        rows.append((Date().timeIntervalSince(t), d.count, url.path.replacingOccurrences(of: root.path, with: "")))
    }
    for r in rows.sorted(by: { $0.0 > $1.0 }).prefix(6) { print(String(format: "REDACT %.2fs %8d %@", r.0, r.1, r.2)) }
    print("REDACT files=\(rows.count) total=\(String(format: "%.1f", rows.map(\.0).reduce(0, +)))s")
}

@Test func codexUsageFromTranscript() {
    let lines = [
        #"{"type":"thread.started","thread_id":"A"}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10}}"#,
        #"{"type":"thread.started","thread_id":"A"}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":300,"cached_input_tokens":200,"output_tokens":25}}"#,   // running total for A
        #"{"type":"thread.started","thread_id":"B"}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":2000000,"cached_input_tokens":1000000,"output_tokens":4000}}"#,
    ]
    var s = Session(id: "x", beamId: "b", beamName: "b")
    s.codexUsage = Session.codexUsage(fromTranscript: lines)
    #expect(s.codexUsage == ["A": [300, 200, 25], "B": [2_000_000, 1_000_000, 4000]])
    #expect(s.codexTokens == (2_000_300, 1_000_200, 4025))
    #expect(s.usesTokens && s.costShort == "2.0M tok")
    #expect(s.costLong == "2.0M in (50% cached) · 4k out")
    s.costUsd = 0.25
    #expect(!s.usesTokens && s.costShort == "$0.2500")
    #expect(Session(id: "y", beamId: "", beamName: "").costShort == "$0.0000")
}

@Test func redactIsFastOnLongRuns() {
    // 30 KB of base64 (an SVG data URI) took 11s with the old KEY=value rule.
    let blob = "data:image/png;base64," + String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5", count: 640)
    let t = Date()
    _ = Secrets.redact(blob + "\nGITHUB_TOKEN=abcdefgh12345678\n" + blob)
    #expect(Date().timeIntervalSince(t) < 0.5)
    #expect(Secrets.redact("x GITHUB_TOKEN=abcdefgh12345678") == "x GITHUB_TOKEN=[REDACTED]")
    #expect(Secrets.redact(#"{"api_key": "sk_live_abcdef123456"}"#) == #"{"api_key": "[REDACTED]"}"#)
}
