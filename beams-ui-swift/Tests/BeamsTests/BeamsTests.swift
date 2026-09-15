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
    #expect(o.script.contains(#"-- 'say '\''hi'\'''"#))
    let r = TurnOptions(sessionID: "abc", resume: true, workDir: "/w", prompt: "x", permissionMode: "plan", model: "claude-sonnet-5")
    #expect(r.script.contains("--resume abc"))
    #expect(r.script.contains("--permission-mode plan"))
    #expect(r.script.contains("--model 'claude-sonnet-5'"))
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

@Test func shellQuoteAndHost() {
    #expect(Shell.quote("a'b") == #"'a'\''b'"#)
    #expect(hostOnly("https://super-grass.beams.sh:443/x") == "super-grass.beams.sh")
}
