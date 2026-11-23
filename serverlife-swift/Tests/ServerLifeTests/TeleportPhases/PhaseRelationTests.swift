import Foundation
import Testing
@testable import ServerLife

// beams.js phaseRelations / judge, sidebar.js phaseRelationRows, phasebuilder.js freshName.

private func ph(_ name: String, _ parent: String = "default:v1", state: String = "ready", at: Double? = nil) -> BeamPhase {
    BeamPhase(name: name, state: state, parent: parent, publishedAt: at)
}
private func entry(_ name: String, mode: String, source: String = "", result: String = "saved", proxy: String = "px",
                   startedAt: Double = 1000) -> PhaseBuildEntry {
    PhaseBuildEntry(raw: .object(["id": .string(uid("e")), "proxy": .string(proxy), "name": .string(name), "kind": "add",
                                  "mode": .string(mode), "source": .string(source), "result": .string(result),
                                  "startedAt": .number(startedAt)]))
}

@Suite("TeleportPhases relations") @MainActor
struct PhaseRelationTests {
    @Test func judgeSavedFailedOrNotYet() {
        let e = entry("a", mode: "base", result: "running", startedAt: 1_000_000)
        #expect(PhaseJournal.judge(e, nil) == nil)
        #expect(PhaseJournal.judge(e, ph("a", at: 1_000_000)) == "saved")
        // Published a little before the build began still counts (a minute of slack); long before does not.
        #expect(PhaseJournal.judge(e, ph("a", at: 1_000_000 - 30_000)) == "saved")
        #expect(PhaseJournal.judge(e, ph("a", at: 1_000_000 - 120_000)) == nil)
        #expect(PhaseJournal.judge(e, ph("a", state: "build_failed")) == "failed")
        #expect(PhaseJournal.judge(e, ph("a", state: "building")) == nil)
    }

    @Test func chainFromTheListAndForksFromTheJournal() {
        let list = [ph("tools"), ph("app", "tools"), ph("mine", "default:v1")]
        let journal = [entry("mine", mode: "fork", source: "app@sha256:abc")]
        let rel = PhaseRelations.of("px", "mine", phases: list, journal: journal, beams: [])
        #expect(rel.chain.map(\.name) == ["default:v1", "tools", "app", "mine"])
        #expect(rel.chain.first?.base == true)
        #expect(rel.chain.last?.how == "fork")
        #expect(PhaseRelations.lineageText(rel, fallback: "mine") == "default:v1 → tools → app ⑂ mine")
        let app = PhaseRelations.of("px", "app", phases: list, journal: journal, beams: [])
        #expect(Set(app.children.map(\.phase.name)) == ["mine"])
        #expect(app.children.first?.how == "fork")
        let tools = PhaseRelations.of("px", "tools", phases: list, journal: journal, beams: [])
        #expect(tools.children.map(\.phase.name) == ["app"])
        #expect(tools.children.first?.how == "from")
    }

    @Test func aFailedBuildIsNoOrigin() {
        let list = [ph("app"), ph("mine")]
        let rel = PhaseRelations.of("px", "mine", phases: list, journal: [entry("mine", mode: "fork", source: "app", result: "failed")], beams: [])
        #expect(rel.chain.map(\.name) == ["default:v1", "mine"])
    }

    @Test func aForkOfAGoneOneIsMarkedGone() {
        let rel = PhaseRelations.of("px", "mine", phases: [ph("mine")], journal: [entry("mine", mode: "fork", source: "old")], beams: [])
        #expect(rel.chain.first?.name == "old")
        #expect(rel.chain.first?.gone == true)
    }

    @Test func lineageFallback() {
        #expect(PhaseRelations.lineageText([], fallback: "x") == "x")
    }

    @Test func relationshipRowsDrawEachOnceEvenInALoop() {
        let list = [ph("a"), ph("b", "a"), ph("c", "b")]
        var relOf: [String: PhaseRelationsInfo] = [:]
        for p in list { relOf[p.name] = PhaseRelations.of("px", p.name, phases: list, journal: [], beams: []) }
        let rows = PhaseRelLayout.rows(proxy: "px", list: list, shut: [], relOf: relOf)
        let names = rows.compactMap { r -> String? in if case .phase(let p, _, _, _, _) = r { return p.name }; return nil }
        #expect(names == ["a", "b", "c"])
        if case .base(let n, _, let count) = rows.first { #expect(n == "default:v1" && count == 1) } else { Issue.record("no base row") }
        // Shut "a": b and c are hidden under it, counted.
        let shut = PhaseRelLayout.rows(proxy: "px", list: list, shut: ["px|a"], relOf: relOf)
        let hidden = shut.compactMap { r -> Int? in if case .phase(let p, _, _, _, let h) = r, p.name == "a" { return h }; return nil }
        #expect(hidden == [2])
        #expect(shut.count == 2)
        // A loop (x's child is y, y's child is x): both still drawn, once.
        var loop: [String: PhaseRelationsInfo] = [:]
        let x = ph("x"), y = ph("y")
        loop["x"] = PhaseRelationsInfo(chain: [], children: [PhaseChild(phase: y, how: "from")], beams: [], builds: [])
        loop["y"] = PhaseRelationsInfo(chain: [], children: [PhaseChild(phase: x, how: "from")], beams: [], builds: [])
        let lr = PhaseRelLayout.rows(proxy: "px", list: [x, y], shut: [], relOf: loop)
        let ln = lr.compactMap { r -> String? in if case .phase(let p, _, _, _, _) = r { return p.name }; return nil }
        #expect(Set(ln) == ["x", "y"] && ln.count == 2)
    }

    @Test func freshNames() {
        #expect(phaseFreshName("My Tools!", []) == "my-tools")
        #expect(phaseFreshName("tools", ["tools", "tools-2"]) == "tools-3")
        #expect(phaseFreshName("", []) == "setup")
        #expect(phaseFreshName(String(repeating: "a", count: 60), []).count == 44)
    }
}
