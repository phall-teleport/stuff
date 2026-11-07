// Tests/BeamsTests/PhaseTests.swift
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
        #expect(PhaseText.clean("\u{1B}[31mERROR:\u{1B}[0m bad\nthing ") == "ERROR: bad thing")
    }
}
