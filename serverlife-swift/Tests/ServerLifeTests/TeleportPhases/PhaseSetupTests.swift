import Foundation
import Testing
@testable import ServerLife

// tests/phasesetup.test.mjs

func phStage(_ name: String, _ kind: String, _ setups: [(String, [String: String])], from: String = "") -> PhaseStage {
    PhaseStage(name: name, from: from, kind: kind, setups: setups.map { PhaseSetupUse(id: $0.0, values: $0.1) })
}
func phDocs(_ r: PhaseBuildResult) -> [YAMLValue] { (try? KubeYAML.loadAllValues(r.yaml).filter { !$0.isNull }) ?? [] }
func phHas(_ errors: [String], _ pattern: String) -> Bool {
    errors.contains { $0.range(of: pattern, options: .regularExpression) != nil }
}
let phAlways = PhaseSetupContext(home: "", exists: { _ in true })

@Suite("TeleportPhases setups") @MainActor
struct PhaseSetupTests {
    @Test func everySetupBuildsFromDefaults() {
        for s in PhaseSetups.setups {
            var values: [String: String] = [:]
            for f in s.fields {
                values[f.key] = f.defaultValue?.nilIfEmpty ?? (f.kind == "select" ? f.options?.first : f.placeholder.nilIfEmpty) ?? "x"
            }
            let kind = s.stage == "files" ? "files" : "commands"
            // A service-only setup still needs a command for its commands stage to be valid.
            var setups = [(s.id, values)]
            if kind == "commands" && s.stage == "any" { setups.append(("command", ["shell": "true"])) }
            let r = PhaseSetups.build([phStage("one", kind, setups)], PhaseSetupContext(home: "/Users/me", exists: { _ in true }))
            #expect(r.errors == [], "\(s.id): \(r.errors.joined(separator: "; "))")
        }
    }

    @Test func stagesChain() {
        let r = PhaseSetups.build([
            phStage("tools", "commands", [("go", [:])], from: "workspace"),
            phStage("files", "files", [("copy", ["from": "/tmp/x", "to": "/opt/x"])]),
        ], phAlways)
        #expect(r.errors == [])
        let d = phDocs(r)
        #expect(d.count == 2)
        #expect(d[0]["metadata"]["from"].string == "workspace")
        #expect(d[1]["metadata"]["from"].string == "tools")
        #expect(!(d[0]["commands"].items ?? []).isEmpty && d[0]["files"].isNull)
        let f = d[1]["files"].items ?? []
        #expect(f.count == 1)
        #expect(f.first?["comment"].string == "Copy x" && f.first?["from"].string == "/tmp/x" && f.first?["to"].string == "/opt/x")
        #expect(r.yaml.hasPrefix("# A Phase setup made in ServerLife"))
    }

    @Test func defaultImageLeftOut() {
        let r = PhaseSetups.build([phStage("tools", "commands", [("uv", [:])], from: "default:v1")])
        #expect(phDocs(r)[0]["metadata"]["from"].isNull)
    }

    @Test func names() {
        func bad(_ n: String) -> [String] { PhaseSetups.build([phStage(n, "commands", [("uv", [:])])]).errors }
        #expect(!bad("My_Phase").isEmpty)
        #expect(!bad("-leading").isEmpty)
        #expect(!bad(String(repeating: "a", count: 55)).isEmpty)
        #expect(bad(String(repeating: "a", count: 54)) == [])
        let dup = PhaseSetups.build([phStage("x", "commands", [("uv", [:])]), phStage("x", "commands", [("uv", [:])])]).errors
        #expect(phHas(dup, "already has this name"))
    }

    @Test func commandsNeedACommandFilesMayBeEmpty() {
        #expect(phHas(PhaseSetups.build([phStage("a", "commands", [])]).errors, "at least one command"))
        let r = PhaseSetups.build([phStage("a", "files", [])])
        #expect(r.errors == [])
        #expect(phDocs(r)[0]["files"].items?.isEmpty == true)
    }

    @Test func setupsKeepToTheirKind() {
        #expect(phHas(PhaseSetups.build([phStage("a", "files", [("go", [:])])]).errors, "commands stage"))
        #expect(phHas(PhaseSetups.build([phStage("a", "commands", [("copy", ["from": "/x", "to": "/opt/x"])])]).errors, "copy-files stage"))
    }

    @Test func copiedFiles() {
        func run(_ to: String, _ exists: Bool = true) -> [String] {
            PhaseSetups.build([phStage("a", "files", [("copy", ["from": "/tmp/x", "to": to])])],
                              PhaseSetupContext(exists: { _ in exists })).errors
        }
        #expect(phHas(run("/home/beams/x"), "outside /home"))
        #expect(phHas(run("/home"), "outside /home"))
        #expect(phHas(run("opt/x"), "absolute"))
        #expect(phHas(run("/opt/x", false), "not on this computer"))
        #expect(run("/opt/x") == [])
    }

    @Test func dotfiles() {
        let r = PhaseSetups.build([phStage("dots", "files", [("dotfiles", ["paths": "~/.gitconfig\n~/.claude/settings.json"])])],
                                  PhaseSetupContext(home: "/Users/me"))
        #expect(r.errors == [])
        let d = phDocs(r)[0]
        let pairs = (d["files"].items ?? []).map { [$0["from"].string ?? "", $0["to"].string ?? ""] }
        #expect(pairs == [["/Users/me/.gitconfig", "\(PhaseSetups.homeStaging)/.gitconfig"],
                          ["/Users/me/.claude/settings.json", "\(PhaseSetups.homeStaging)/.claude/settings.json"]])
        let svc = d["services"].items?.first
        #expect(svc?["type"].string == "pre-start")
        #expect(svc?["shell"].string?.hasPrefix("cp -Rn ") == true)
        let rep = PhaseSetups.build([phStage("dots", "files", [("dotfiles", ["paths": "~/.vimrc", "replace": "yes"])])],
                                    PhaseSetupContext(home: "/Users/me"))
        #expect(phDocs(rep)[0]["services"].items?.first?["shell"].string?.hasPrefix("cp -Rf ") == true)
    }

    @Test func services() {
        func svc(_ v: [String: String]) -> [String] {
            PhaseSetups.build([phStage("a", "commands", [("command", ["shell": "true"]), ("service", v)])]).errors
        }
        #expect(svc(["name": "web", "shell": "exec x", "type": "background", "context": "runtime"]) == [])
        #expect(!svc(["name": "bootstrap", "shell": "x"]).isEmpty)
        #expect(!svc(["name": "bad name", "shell": "x"]).isEmpty)
        #expect(!svc(["name": "web", "shell": "x", "context": "sometimes"]).isEmpty)
        let twice = PhaseSetups.build([phStage("a", "commands", [("redis", [:]), ("service", ["name": "redis", "shell": "x"])])]).errors
        #expect(phHas(twice, "two services are called \"redis\""))
    }

    @Test func requiredField() {
        #expect(phHas(PhaseSetups.build([phStage("a", "commands", [("apt", ["packages": ""])])]).errors, "\"Packages\" is needed"))
    }

    @Test func environment() {
        let r = PhaseSetups.build([phStage("a", "commands", [("env", ["vars": "EDITOR=vim\nGREETING=hello world\nQUOTE=it's"])])])
        #expect(r.errors == [])
        let shell = phDocs(r)[0]["commands"].items?.first?["shell"].string ?? ""
        #expect(shell.contains("export EDITOR=vim"))
        #expect(shell.contains("export GREETING='hello world'"))
        #expect(shell.contains("export QUOTE='it'\\''s'"))
        #expect(!PhaseSetups.build([phStage("a", "commands", [("env", ["vars": "not a var"])])]).errors.isEmpty)
    }

    @Test func rebuildHomePaths() {
        let r = PhaseSetups.build([phStage("deps", "commands", [("deps-under-home", [:])], from: "app-source")])
        #expect(r.errors == [])
        let d = phDocs(r)[0]
        #expect(d["metadata"]["rebuild_home_paths"].items?.compactMap(\.string) == ["/home/beams/app/node_modules"])
        #expect(d["commands"].items?.first?["workdir"].string == "/home/beams/app")
        let bad = PhaseSetups.build([phStage("deps", "commands", [("deps-under-home", ["reserve": "/home/beams/*"])])]).errors
        #expect(phHas(bad, "without wildcards"))
    }

    @Test func workdir() {
        func errs(_ w: String) -> [String] { PhaseSetups.build([phStage("a", "commands", [("command", ["shell": "x", "workdir": w])])]).errors }
        #expect(!errs("relative").isEmpty)
        #expect(!errs("/a/../b").isEmpty)
        #expect(errs("/srv").isEmpty)
    }

    @Test func tooBig() {
        let r = PhaseSetups.build([phStage("a", "commands", [("command", ["shell": String(repeating: "x", count: 33 * 1024)])])])
        #expect(phHas(r.errors, "32768"))
    }

    @Test func catalogSize() { #expect(PhaseSetups.catalog().count >= 15) }

    @Test func applyArgs() throws {
        let a = try Beams.phaseApplyArgs(proxy: nil, file: "/tmp/p.yaml", noConsole: true, region: "us-west-2")
        #expect(Array(a.drop { $0 != "phase" }) == ["phase", "apply", "--file=/tmp/p.yaml", "--no-console", "--region=us-west-2"])
        #expect(throws: (any Error).self) { try Beams.phaseApplyArgs(proxy: nil, file: "") }
    }

    @Test func writtenInYamlKeepsToItsKind() {
        #expect(phHas(PhaseSetups.build([phStage("a", "files", [("raw", ["yaml": "commands:\n  - shell: true"])])]).errors, "runs no commands"))
        #expect(phHas(PhaseSetups.build([phStage("a", "commands", [("raw", ["yaml": "comands:\n  - shell: true"])])]).errors, "unknown key: comands"))
    }
}
