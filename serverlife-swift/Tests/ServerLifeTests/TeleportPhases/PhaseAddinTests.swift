import Foundation
import Testing
@testable import ServerLife

// tests/phasesetup.test.mjs — add-ins and opening a phase.yaml.

private let nodeAddin = """

label: Our Node toolchain
group: Team setups
stage: commands
fields:
  - { key: version, label: Node version, default: "22", required: true }
  - { key: registry, label: Registry, default: "https://npm.example.com/a b" }
commands:
  - comment: Install Node {{version}}
    shell: curl -fsSL https://deb.nodesource.com/setup_{{version}}.x | bash - && npm config set registry {{registry|sh}}

"""

/// A YAML value written out with sorted keys, to compare documents.
private func canon(_ v: YAMLValue) -> String {
    switch v {
    case .null: return "null"
    case .bool(let b): return "\(b)"
    case .int(let i): return "\(i)"
    case .double(let d): return "\(d)"
    case .string(let s): return "\"\(s)\""
    case .seq(let a): return "[" + a.map(canon).joined(separator: ",") + "]"
    case .map(let m): return "{" + m.sorted { $0.0 < $1.0 }.map { "\($0.0):\(canon($0.1))" }.joined(separator: ",") + "}"
    }
}

@Suite("TeleportPhases add-ins") @MainActor
struct PhaseAddinTests {
    @Test func addinReadAndFilled() throws {
        let a = try PhaseSetups.parseAddin(nodeAddin, name: "node-team")
        #expect(a.id == "addin:node-team")
        #expect(a.group == "Team setups")
        let out = a.expand(["version": "20", "registry": "https://npm.example.com/a b"], PhaseSetupContext())
        #expect(out.commands.first?["comment"].string == "Install Node 20")
        let shell = out.commands.first?["shell"].string ?? ""
        #expect(shell.contains("setup_20.x"))
        #expect(shell.hasSuffix("registry 'https://npm.example.com/a b'"))
    }

    @Test func addinGoesThroughTheSameChecks() throws {
        let a = try PhaseSetups.parseAddin(nodeAddin, name: "node-team")
        let ctx = PhaseSetupContext(addins: [a])
        let ok = PhaseSetups.build([phStage("tools", "commands", [(a.id, ["version": "22"])])], ctx)
        #expect(ok.errors == [])
        #expect(ok.yaml.contains("comment: Install Node 22"))
        let empty = PhaseSetups.build([phStage("tools", "commands", [(a.id, ["version": ""])])], ctx)
        #expect(phHas(empty.errors, "\"Node version\" is needed"))
        let gone = PhaseSetups.build([phStage("tools", "commands", [("addin:nope", [:])])], ctx)
        #expect(phHas(gone.errors, "add-in not found"))
    }

    @Test func addinMistakesAreNamed() {
        func bad(_ t: String) -> String? {
            do { _ = try PhaseSetups.parseAddin(t, name: "x"); return nil } catch { return (error as? AppError)?.message ?? "\(error)" }
        }
        func says(_ t: String, _ pat: String) -> Bool { bad(t)?.range(of: pat, options: .regularExpression) != nil }
        #expect(says("label: [unclosed", "not YAML"))
        #expect(says("commands: []", "needs a label"))
        #expect(says("label: x\nstage: commands\ncomand:\n  - shell: true", "unknown key: comand"))
        #expect(says("label: x\nstage: commands\ncommands:\n  - shell: echo {{versoin}}", #"uses \{\{versoin\}\} but has no such field"#))
        #expect(says("label: x\nstage: files\ncommands:\n  - shell: true", "files add-in runs no commands"))
        #expect(says("label: x\nstage: any\ncommands:\n  - shell: true", "can only add services"))
        #expect(says("label: x\nstage: commands", "adds nothing"))
        #expect(says("label: x\nfields:\n  - { key: k, kind: select }\ncommands:\n  - shell: true", "select needs options"))
        #expect(bad(PhaseSetups.addinTemplate) == nil, "the template a new add-in starts from is itself valid")
    }

    @Test func folderOfAddins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-addins-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try nodeAddin.write(toFile: dir + "/node-team.yaml", atomically: true, encoding: .utf8)
        try "label: x\n".write(toFile: dir + "/broken.yaml", atomically: true, encoding: .utf8)
        try "not an add-in".write(toFile: dir + "/notes.txt", atomically: true, encoding: .utf8)
        let r = PhaseSetups.loadAddins(dir)
        #expect(r.addins.map(\.id) == ["addin:node-team"])
        #expect(r.problems.count == 1)
        #expect(r.problems.first?.file.hasSuffix("broken.yaml") == true)
        #expect(PhaseSetups.catalog(r.addins).contains { $0.id == "addin:node-team" && $0.addin })
        #expect(PhaseSetups.loadAddins("/no/such/folder").addins.isEmpty, "a folder not made yet is just none")
    }

    @Test func openedYamlBuildsBackTheSame() throws {
        let text = """
        version: v1
        metadata:
          name: app-tools
          from: workspace
        commands:
          - comment: Install tools
            command: /bin/sh
            args: [-c, "apt-get update && apt-get install -y git"]
            env: [{ name: DEBIAN_FRONTEND, value: noninteractive }]
        ---
        version: v1
        metadata:
          name: app-config
          from: app-tools
        files:
          - from: ./config
            to: /opt/app-config
        services:
          - name: prepare-config
            type: pre-start
            shell: cp /opt/app-config/app.json /home/beams/app.json
        ---
        version: v1
        metadata:
          name: app-deps
          from: app-config
          rebuild_home_paths: [/home/beams/app/node_modules]
        commands:
          - command: npm
            args: [ci]
            workdir: /home/beams/app

        """
        let r = try PhaseSetups.fromYaml(text, dir: "/work/project")
        #expect(r.warnings == [])
        #expect(r.stages.map { [$0.name, $0.from, $0.kind] } == [["app-tools", "workspace", "commands"], ["app-config", "", "files"], ["app-deps", "", "commands"]])
        let built = PhaseSetups.build(r.stages, phAlways)
        #expect(built.errors == [])
        // made absolute against the file's folder
        let want = try KubeYAML.loadAllValues(text.replacingOccurrences(of: "from: ./config", with: "from: /work/project/config"))
        #expect(phDocs(built).map(canon) == want.filter { !$0.isNull }.map(canon))
    }

    @Test func openingRawAndOdd() throws {
        let raw = try PhaseSetups.fromYaml("commands:\n  - command: /bin/true\n")
        #expect(raw.stages.count == 1)
        #expect(raw.stages.first?.kind == "commands")
        let odd = try PhaseSetups.fromYaml("version: v1\nmetadata: { name: a }\ncommands: [{ shell: x }]\nnotes: hi\n---\nversion: v1\nmetadata: { name: b, from: zzz }\ncommands: [{ shell: y }]\n")
        #expect(phHas(odd.warnings, "left out notes"))
        #expect(phHas(odd.warnings, "was built on zzz"))
        #expect(throws: (any Error).self) { try PhaseSetups.fromYaml("") }
        #expect(throws: (any Error).self) { try PhaseSetups.fromYaml("a: [b") }
        let msg: (String) -> String = { t in do { _ = try PhaseSetups.fromYaml(t); return "" } catch { return (error as? AppError)?.message ?? "" } }
        #expect(msg("").contains("empty"))
        #expect(msg("a: [b").contains("not YAML"))
    }
}
