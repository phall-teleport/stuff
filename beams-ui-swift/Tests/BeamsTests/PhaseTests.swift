import Testing
import Foundation
@testable import Beams

@Suite("Phase parsing and arguments")
struct PhaseTests {
    @Test("phase ls row from real tsh output")
    func phaseLs() throws {
        let json = #"[{"name":"x","owner":"paul@geekvoice.net","strategy":"static","parent":"default:v1","state":"building","region":"us-west-2","roles":["access"]}]"#
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let p = try #require(BeamPhase.parse(obj).first)
        #expect(p.name == "x")
        #expect(p.parent == "default:v1")
        #expect(p.isBuilding)
        #expect(!p.locked)
    }

    @Test("Empty or null listing")
    func emptyListing() {
        #expect(BeamPhase.parse(NSNull()).isEmpty)
        #expect(BeamPhase.parse([Any]()).isEmpty)
    }

    @Test("A phase with children is locked")
    func lockedByChild() {
        let p = BeamPhase.parse([["name": "base"], ["name": "web", "parent": "base"]])
        #expect(p.first { $0.name == "base" }?.locked == true)
        #expect(p.first { $0.name == "web" }?.locked == false)
    }

    @Test("Text table fallback")
    func table() {
        let text = """
        Name   Parent      State
        ------ ----------- --------
        x      default:v1  building
        """
        let p = BeamPhase.parseTable(text)
        #expect(p.map(\.name) == ["x"])
        #expect(p.first?.parent == "default:v1")
    }

    @Test("phase add output from real tsh output")
    func phaseAdd() throws {
        let json = #"{"name":"x","owner":"paul@geekvoice.net","strategy":"static","parent":"default:v1","state":"building","build_beam":"af775672-8eea-488b-9bde-109128dd015d","region":"us-west-2","roles":["access"]}"#
        let b = try #require(PhaseBuild.parse(Data(json.utf8), fallbackName: "fallback"))
        #expect(b.name == "x")
        #expect(b.buildBeam == "af775672-8eea-488b-9bde-109128dd015d")
        #expect(b.raw["state"] == "building")
    }

    @Test("Headless phase add arguments")
    func phaseAddArgs() throws {
        #expect(try TshClient.phaseAddArgs(name: "y", from: "default:v1")
                == ["phase", "add", "--from=default:v1", "--no-console", "--format=json", "y"])
        #expect(try TshClient.phaseAddArgs(name: "", forkFrom: "x@sha256:abc")
                == ["phase", "add", "--fork-from=x@sha256:abc", "--no-console", "--format=json"])
        #expect(throws: PhaseError.self) { try TshClient.phaseAddArgs(name: "z", from: "a", forkFrom: "b") }
    }

    @Test("Beam from a phase")
    func beamAddArgs() throws {
        #expect(try TshClient.beamAddArgs(phase: "default:v1")
                == ["beams", "add", "--no-console", "-f", "json", "--phase=default:v1"])
        #expect(throws: PhaseError.self) { try TshClient.beamAddArgs(phase: "  ") }
    }

    @Test("Beam id from beams add output")
    func beamID() {
        #expect(TshClient.beamID(fromAddOutput: Data("Creating…\n{\"id\":\"x-af775672\",\"uuid\":\"af775672\"}".utf8)) == "x-af775672")
        #expect(TshClient.beamID(fromAddOutput: Data("no json".utf8)) == nil)
    }

    @Test("Names and references are sanitized")
    func names() {
        #expect(BeamPhase.safeName(" my phase; rm -rf ") == "myphaserm-rf")
        #expect(BeamPhase.safeName("default:v1") == "defaultv1")
        #expect(BeamPhase.safeRef("default:v1") == "default:v1")
        #expect(BeamPhase.safeRef("x@sha256:abc; ls") == "x@sha256:abcls")
    }

    @Test("In-beam scripts")
    func scripts() {
        #expect(PhaseScripts.snapshot().contains("exec tsh phase snapshot 2>&1"))
        #expect(PhaseScripts.snapshot(final: true).contains("tsh phase snapshot --final"))
        let fork = PhaseScripts.fork(newName: "my phase; x")
        #expect(fork.contains("myphasex"))
        #expect(fork.contains("--fork --no-console"))
        #expect(!fork.contains(";  x"))
    }

    @Test("Error text cleanup")
    func clean() {
        let out = PhaseText.clean("\u{1B}[31mERROR:\u{1B}[0m bad\nthing ")
        #expect(!out.contains("\u{1B}"), "color codes should be stripped")
        #expect(out == "ERROR: bad thing")
    }

    @Test("tsh version parsing prefers the client line")
    func versionParse() throws {
        let v = try #require(TshVersion.parse("Teleport v18.11.9 git:v18.11.9-0-gabc123 go1.24.4"))
        #expect(v == TshVersion(major: 18, minor: 11, patch: 9))
        let withProxy = "Teleport v18.11.7 git:v18.11.7-0-gdef go1.24.4\nProxy version: 18.12.0\nProxy: super-grass.beams.sh:443"
        #expect(TshVersion.parse(withProxy) == TshVersion(major: 18, minor: 11, patch: 7))
        #expect(TshVersion.parse("no version here") == nil)
    }

    @Test("Phase minimum version comparison")
    func versionCompare() {
        #expect(TshVersion(major: 18, minor: 11, patch: 7) < TshVersion.phaseMinimum)
        #expect(TshVersion(major: 17, minor: 99, patch: 99) < TshVersion.phaseMinimum)
        #expect(!(TshVersion(major: 18, minor: 11, patch: 9) < TshVersion.phaseMinimum))
        #expect(!(TshVersion(major: 18, minor: 12, patch: 0) < TshVersion.phaseMinimum))
        #expect(!(TshVersion(major: 19, minor: 0, patch: 0) < TshVersion.phaseMinimum))
    }

    @Test("Old tsh errors are recognized")
    func unsupported() {
        #expect(PhaseError.isUnsupportedCommand(#"tsh --proxy=super-grass.beams.sh phase: tsh: error: expected command but got "phase""#))
        #expect(PhaseError.isUnsupportedCommand("ERROR: unknown flag: --phase"))
        #expect(!PhaseError.isUnsupportedCommand("ERROR: phase x is locked"))
    }
@Test("Beam rows keep phase out of state")
    func beamRowPhase() {
        let b = Beam(row: ["id": "x-af775672", "uuid": "af775672-8eea", "region": "us-west-2", "phase": "default:v1"])
        #expect(b.state == "running")
        #expect(b.phase == "default:v1")
    }

    @Test("Session phase round-trips; old files decode without it")
    func sessionPhase() throws {
        var s = Session(id: "s1", beamId: "b", beamName: "b")
        s.phase = "x"
        let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
        #expect(back.phase == "x")

        let old = try JSONDecoder().decode(Session.self, from: Data(#"{"id":"s2","beamId":"b"}"#.utf8))
        #expect(old.phase.isEmpty)

        let plain = String(decoding: try JSONEncoder().encode(Session(id: "s3", beamId: "b", beamName: "b")), as: UTF8.self)
        #expect(!plain.contains("\"phase\""))
    }

    @Test("Config defaultPhase decodes from old files")
    func configDefaultPhase() throws {
        #expect(try JSONDecoder().decode(Config.self, from: Data(#"{"proxy":"p"}"#.utf8)).defaultPhase.isEmpty)
        #expect(try JSONDecoder().decode(Config.self, from: Data(#"{"defaultPhase":"x"}"#.utf8)).defaultPhase == "x")
    }
@Test("Conversation paths checked in a beam started from a phase")
    func conversationPaths() {
        #expect(PhaseRestore.conversationPath(sessionID: "abc", isCodex: false, codexRel: "", workDir: "/home/beams/work")
                == ".claude/projects/-home-beams-work/abc.jsonl")
        #expect(PhaseRestore.conversationPath(sessionID: "abc", isCodex: true, codexRel: "sessions/2026/r.jsonl", workDir: "/w")
                == ".codex/sessions/2026/r.jsonl")
        #expect(PhaseRestore.conversationPath(sessionID: "abc", isCodex: true, codexRel: "", workDir: "/w") == nil)
    }

    @Test("Conversation check script quotes the path")
    func conversationCheck() {
        let s = PhaseRestore.checkScript(".claude/projects/x/a b.jsonl")
        #expect(s.hasPrefix(#"test -f "$HOME"/'"#))
        #expect(s.contains("echo present || echo missing"))
    }
@Test("Continue wording for phase sessions")
    func continueWording() {
        let plan = AppModel.RestorePlan(files: 3, memory: true, resumable: true, hasTranscript: true)
        var s = Session(id: "s", beamId: "b", beamName: "b")
        s.turns = 2

        // No phase: unchanged wording.
        #expect(ContinueText.summary(plan, session: s, newBeam: true) == ContinueText.summary(plan, turns: 2))

        s.phase = "x"
        let phaseText = ContinueText.summary(plan, session: s, newBeam: true)
        #expect(phaseText.contains("new beam from phase x"))
        #expect(phaseText.contains("saved copy is restored"))

        // Existing beam chosen: falls back to the restore wording.
        #expect(ContinueText.summary(plan, session: s, newBeam: false) == ContinueText.summary(plan, turns: 2))

        // Nothing saved yet: mentions the transcript fallback.
        let bare = AppModel.RestorePlan(files: 0, memory: false, resumable: false, hasTranscript: true)
        #expect(ContinueText.summary(bare, session: s, newBeam: true).contains("old transcript"))
    }
}
