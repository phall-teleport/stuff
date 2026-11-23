import Testing
import Foundation
@testable import ServerLife

@Test func jsonRoundTrip() throws {
    let j = try JSON.parse(#"{"a":1,"b":[true,null,"x"],"c":{"d":2.5}}"#)
    #expect(j["a"].int == 1)
    #expect(j["b"][0].bool == true)
    #expect(j["b"][1].isNull)
    #expect(j["c"]["d"].double == 2.5)
    #expect(j["missing"]["deeper"].isNull)
    let back = try JSON.parse(j.text())
    #expect(back == j)
}

@Test func hostPrefKeys() {
    var h = Host(type: "teleport", id: "", name: "web-1")
    h.cluster = "c1"
    #expect(h.prefKey == "tsh:c1:web-1")
    h.uuid = "abc"
    #expect(h.prefKey == "uuid:abc")
    let s = Host(json: ["type": "ssh", "alias": "ent"])
    #expect(s.id == "ssh:ent")
    #expect(s.clusterPrefKey == "ssh")
}

@Test func formatting() {
    #expect(Fmt.bytes(512) == "512 B")
    #expect(Fmt.bytes(1536) == "1.50 KB")
    #expect(Fmt.duration(ms: 350) == "350ms")
    #expect(Fmt.duration(ms: 192_000) == "3m 12s")
    #expect(Posix.parent("/a/b/") == "/a")
    #expect(Posix.basename("/a/b") == "b")
    #expect(shellQuote("it's") == "'it'\\''s'")
    #expect(compareNames("node-2", "node-10") == .orderedAscending)
}

@Test func procRunsAndTimesOut() async {
    let r = await Proc.run("/bin/echo", ["hi"])
    #expect(r.ok && r.out == "hi\n")
    let t = await Proc.run("/bin/sleep", ["5"], timeout: 0.3)
    #expect(t.timedOut)
}

@Test @MainActor func storeDefaultsMerge() {
    let s = Store(dir: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sl-test-\(UUID())"))
    s.apply(parsed: ["settings": ["fontSize": 15], "profiles": "junk", "workspace": ["tabs": []]])
    #expect(s.setting("fontSize", 0) == 15)
    #expect(s.setting("mfaMode", "") == "platform")
    #expect(s["profiles"].array?.isEmpty == true)
    #expect(s["workspaces"]["w1"]["slot"].string == "w1")
}

@Test @MainActor func sharedStoreIsIsolatedUnderTests() {
    #expect(Store.shared.file.path.contains("serverlife-tests-"))
}


@Test func jsonIntNeverTraps() {
    #expect(JSON.number(1e20).int == nil)
    #expect(JSON.number(-1e20).int == nil)
    #expect(JSON.number(42).int == 42)
}

@Test func jsStyleJSONText() {
    let j: JSON = ["b": [], "a": ["x": 1, "s": "a/b\n"], "c": [:]]
    #expect(j.jsText(indent: 2) == "{\n  \"a\": {\n    \"s\": \"a/b\\n\",\n    \"x\": 1\n  },\n  \"b\": [],\n  \"c\": {}\n}")
    #expect(j.jsText() == "{\"a\":{\"s\":\"a/b\\n\",\"x\":1},\"b\":[],\"c\":{}}")
}

@Test @MainActor func storeSavesAtomicallyAndKeepsUnreadable() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sl-atomic-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: dir.appendingPathComponent("sessions.json"))
    let s = Store(dir: dir)
    s.load()
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names.contains { $0.hasPrefix("sessions.json.corrupt-") })
    s.setSetting("fontSize", 17)
    s.saveNow()
    let back = try JSON.parse(Data(contentsOf: dir.appendingPathComponent("sessions.json")))
    #expect(back["settings"]["fontSize"].int == 17)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions.json.tmp").path))
}

@Test func argumentsKeepTheirUnicodeBytes() async {
    // Precomposed é (U+00E9) must reach the child as C3 A9, not e + U+0301.
    let r = await Proc.run("/usr/bin/printf", ["%s", "h\u{00E9}llo"])
    #expect(Array(r.stdout) == [0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F])
    let t = await Proc.run("/bin/sleep", ["10"], timeout: 0.5)
    #expect(t.timedOut)
}

// MARK: - 0.39 shared helpers (csv.js, textdiff.js, util.js, code editor)

@Test func csvQuotesOnlyWhenNeeded() {
    let rows: [[String: Any]] = [
        ["name": "web-1", "n": 3, "note": "a, b"],
        ["name": "say \"hi\"", "n": 1.5, "note": NSNull()],
        ["name": "two\nlines", "ok": true],
    ]
    let s = toCsv(rows, columns: [("name", "Name"), ("n", nil), ("note", "Note"), ("ok", "OK")])
    #expect(s == "Name,n,Note,OK\r\nweb-1,3,\"a, b\",\r\n\"say \"\"hi\"\"\",1.5,,\r\n\"two\nlines\",,,true\r\n")
    let j = toCsv([JSON.object(["a": .number(2), "b": .string("x")])], columns: [("a", nil), ("b", nil)])
    #expect(j == "a,b\r\n2,x\r\n")
}

@Test func diffLinesLCS() {
    let d = diffLines("a\nb\nc", "a\nc\nd")
    #expect(d == [DiffLine(type: .same, line: "a"), DiffLine(type: .remove, line: "b"),
                  DiffLine(type: .same, line: "c"), DiffLine(type: .add, line: "d")])
    #expect(diffLines("", "x") == [DiffLine(type: .add, line: "x")])
    #expect(diffLines(nil, "") == [])
    #expect(diffLines("x", "x") == [DiffLine(type: .same, line: "x")])
}

@Test func dateTimeTzReadsLikeAClock() {
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    var c = DateComponents(); c.year = 2024; c.month = 3; c.day = 5; c.hour = 15; c.minute = 7
    var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
    let d = cal.date(from: c)!
    let ms = d.timeIntervalSince1970 * 1000
    #expect(Fmt.dateTimeTz(ms: ms, now: d, timeZone: tz) == "Mar 5, 3:07 PM PST")
    #expect(Fmt.dateTimeTz(ms: ms, now: d.addingTimeInterval(400 * 86400), timeZone: tz) == "Mar 5, 2024, 3:07 PM PST")
    #expect(Fmt.dateTimeTz(ms: nil) == "")
}

private func tokens(_ text: String, _ lang: CodeLanguage) -> [(String, CodeToken)] {
    let ns = text as NSString
    return CodeSyntax.spans(text, lang).map { (ns.substring(with: $0.range), $0.token) }
}

@Test func sshConfigTokens() {
    let t = tokens("# c\nHost web-* !x\n  HostName=10.0.0.1\n  ForwardAgnet yes\n  IdentityFile \"a b\" # x\n", .sshConfig)
    let want: [(String, CodeToken)] = [
        ("# c", .comment), ("Host", .keyword), ("web-*", .string), ("!x", .string),
        ("HostName=", .key), ("10.0.0.1", .string), ("ForwardAgnet", .invalid), ("yes", .string),
        ("IdentityFile", .key), ("\"a b\"", .string), ("# x", .comment),
    ]
    #expect(t.count == want.count)
    for (a, b) in zip(t, want) { #expect(a.0 == b.0 && a.1 == b.1) }
}

@Test func yamlTokens() {
    let src = "# top\nkind: Pod\nmetadata:\n  name: \"web\" # c\n  labels: {app: web}\nlist:\n  - a\n  - key: &x v\nrun: |\n  echo key: no\nafter: *x\n---\n"
    let t = tokens(src, .yaml)
    func has(_ s: String, _ k: CodeToken) -> Bool { t.contains { $0.0 == s && $0.1 == k } }
    #expect(has("# top", .comment))
    #expect(has("kind", .key) && has("metadata", .key) && has("name", .key) && has("after", .key))
    #expect(has("\"web\"", .string) && has("# c", .comment))
    #expect(has("app", .key) && has("{", .punctuation) && has("}", .punctuation))
    #expect(has("-", .punctuation) && has("key", .key) && has("&x", .label) && has("*x", .label))
    #expect(has("|", .special))
    // A block of text is text: "echo key: no" is not a key.
    #expect(!has("echo key", .key))
    #expect(has("---", .meta))
}

@MainActor @Test func broadcastActionsReachEveryListener() {
    var hits = 0
    Actions.shared.register("app-resume") { _ in hits += 1 }
    Actions.shared.register("app-resume") { _ in hits += 10 }
    Actions.shared.perform("app-resume")
    #expect(hits == 11)
}

@MainActor @Test func bundledFontsRegister() {
    BundledFonts.registerAll()
    #expect(BundledFonts.list.count == 51)
    // Every face in the list has its file, and registers under some family.
    let missing = BundledFonts.list.filter { BundledFonts.registeredFamily[$0.family] == nil }.map(\.family)
    #expect(missing.isEmpty, "not registered: \(missing)")
    #expect(BundledFonts.font(family: "JetBrains Mono", size: 12) != nil)
    let mismatched = BundledFonts.registeredFamily.filter { $0.key != $0.value }
    print("bundled fonts whose own family differs:", mismatched)
}
