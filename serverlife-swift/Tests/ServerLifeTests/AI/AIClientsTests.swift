import Testing
import Foundation
@testable import ServerLife

/// Launching AI assistants with ServerLife's MCP server (tests/aiclients.test.mjs).
///
/// Every client is told about the server its own way; these pin each one, so
/// a change to one cannot quietly break another. Nothing here needs a client
/// installed — the launch is built, not run.
@Suite(.serialized) struct AIClientsTests {
    let spec = AIClients.serverSpec(runtime: "/Apps/ServerLife", userData: "/Users/me/SL")

    func parse(_ s: String) -> JSON { (try? JSON.parse(s)) ?? .null }

    @Test func bridgeRunsOnServerLifeItself() {
        #expect(spec.command == "/Apps/ServerLife")
        #expect(spec.args == ["--mcp"])
        #expect(spec.env.map { "\($0.0)=\($0.1)" } == ["SERVERLIFE_USER_DATA=/Users/me/SL"])
    }

    @Test func claudeGetsMcpConfig() {
        let args = AIClients.mcpFor("claude", spec).args
        #expect(args[0] == "--mcp-config")
        #expect(parse(args[1]) == ["mcpServers": ["serverlife": spec.json]])
    }

    @Test func codexGetsTomlOverrides() {
        #expect(AIClients.mcpFor("codex", spec).args == [
            "-c", "mcp_servers.serverlife.command=\"/Apps/ServerLife\"",
            "-c", "mcp_servers.serverlife.args=[\"--mcp\"]",
            "-c", "mcp_servers.serverlife.env={ SERVERLIFE_USER_DATA = \"/Users/me/SL\" }",
        ])
    }

    @Test func copilotEveryToolAllowed() {
        let args = AIClients.mcpFor("copilot", spec).args
        #expect(args[0] == "--additional-mcp-config")
        let cfg = parse(args[1])["mcpServers"]["serverlife"]
        #expect(cfg["tools"] == ["*"])
        #expect(cfg["type"].string == "local")
    }

    @Test func opencodeConfigFile() throws {
        let dir = NSTemporaryDirectory() + "sl-ai-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = AIClients.mcpFor("opencode", spec, tmpDir: dir)
        #expect(m.env["OPENCODE_CONFIG"] == (dir as NSString).appendingPathComponent("serverlife-opencode.json"))
        try AIClients.writeFiles(m.files)
        let cfg = parse(try String(contentsOfFile: m.env["OPENCODE_CONFIG"]!, encoding: .utf8))
        #expect(cfg["mcp"]["serverlife"]["command"] == ["/Apps/ServerLife", "--mcp"])
        #expect(cfg["mcp"]["serverlife"]["environment"]["SERVERLIFE_USER_DATA"].string == "/Users/me/SL")
    }

    @Test func piAndGeminiRegisteredOnce() {
        #expect(AIClients.registerCommand("pi", spec) == ["pi", "mcp", "add", "serverlife",
            "--env", "SERVERLIFE_USER_DATA=/Users/me/SL", "--", "/Apps/ServerLife", "--mcp"])
        #expect(AIClients.registerCommand("gemini", spec)?.first == "gemini")
        #expect(AIClients.registerCommand("claude", spec) == nil)
    }

    @Test func launchThroughLoginShell() throws {
        var o = AIClients.LaunchOptions(); o.spec = spec; o.shell = "/bin/zsh"
        let l = try AIClients.launch("claude", o)
        #expect(l.command == "/bin/zsh")
        #expect(Array(l.args.prefix(3)) == ["-l", "-i", "-c"])
        #expect(l.args[3].hasPrefix("exec claude --mcp-config '{\"mcpServers\""))
        #expect(l.title == "Claude Code")
    }

    @Test func launcherWrapsTheClient() {
        let argv = ["claude", "--mcp-config", "{}"]
        #expect(AIClients.withLauncher("claude", argv, .init(template: "prism {client}")).argv == ["prism", "claude", "--mcp-config", "{}"])
        #expect(AIClients.withLauncher("claude", argv, .init(template: "aws-vault exec dev -- {command}")).argv
            == ["aws-vault", "exec", "dev", "--", "claude", "--mcp-config", "{}"])
        #expect(AIClients.withLauncher("claude", argv, .init(template: "nice -n 5")).argv == ["nice", "-n", "5", "claude", "--mcp-config", "{}"])
    }

    @Test func launcherOnlyForListedClients() throws {
        let l = AIClients.Launcher(template: "prism {client}", clients: ["claude", "pi"])
        #expect(AIClients.withLauncher("copilot", ["copilot"], l).launched == false)
        var o = AIClients.LaunchOptions(); o.launcher = l; o.shell = "/bin/zsh"
        let pi = try AIClients.launch("pi", o)
        #expect(pi.args[3] == "exec prism pi")
        #expect(pi.title == "Pi · via launcher")
        var plain = AIClients.LaunchOptions(); plain.shell = "/bin/zsh"
        #expect(try AIClients.launch("pi", plain).args[3] == "exec pi")
    }

    @Test func theSixClients() {
        #expect(AIClients.builtIn.map(\.id) == ["claude", "codex", "copilot", "opencode", "pi", "gemini"])
        for c in AIClients.builtIn {
            #expect(!c.name.isEmpty && !c.bin.isEmpty && ["flag", "env", "persist"].contains(c.mcp))
        }
    }

    @Test func customTool() throws {
        AIClients.setCustom([["id": "custom-aider", "name": "Aider", "command": "aider --no-auto-commits", "mcpFlag": ""],
                             ["id": "custom-x", "name": "X", "command": "xagent", "mcpFlag": "--mcp-config"]])
        defer { AIClients.setCustom([]) }
        var o = AIClients.LaunchOptions(); o.spec = spec; o.shell = "/bin/zsh"
        #expect(try AIClients.launch("custom-aider", o).args[3] == "exec aider --no-auto-commits")
        let x = try AIClients.launch("custom-x", o)
        #expect(x.argv[0] == "xagent")
        #expect(x.argv[1] == "--mcp-config")
        #expect(parse(x.argv[2])["mcpServers"]["serverlife"] == spec.json)
        #expect(AIClients.byId("custom-x")?.custom == true)
        AIClients.setCustom([])
        #expect(AIClients.byId("custom-x") == nil)
    }

    @Test func modelAndExtraArguments() throws {
        var o = AIClients.LaunchOptions(); o.shell = "/bin/zsh"; o.model = "anthropic/claude-haiku-4-5"
        #expect(try AIClients.launch("opencode", o).args[3] == "exec opencode -m anthropic/claude-haiku-4-5")
        var c = AIClients.LaunchOptions(); c.model = "claude-sonnet-5"; c.extraArgs = "--add-dir \"/tmp/a b\""
        #expect(try AIClients.launch("claude", c).argv == ["claude", "--model", "claude-sonnet-5", "--add-dir", "/tmp/a b"])
        #expect(AIClients.splitWords("-c 'model_providers.g.base_url=\"http://x/v1\"' --fast")
            == ["-c", "model_providers.g.base_url=\"http://x/v1\"", "--fast"])
    }

    @Test func shellQuoting() {
        #expect(AIClients.shq("claude") == "claude")
        #expect(AIClients.shq("a b") == "'a b'")
        #expect(AIClients.shq("it's") == "'it'\\''s'")
    }

    @Test func toolDirsGoOnPath() {
        let p = AIClients.withToolPath("/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(p.split(separator: ":").contains("/opt/homebrew/bin"))
        #expect(p.hasPrefix("/usr/bin:/bin"))
        #expect(AIClients.withToolPath("/opt/homebrew/bin:/usr/bin").split(separator: ":").filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    @Test func findOnPathOnDisk() throws {
        let dir = NSTemporaryDirectory() + "sl-bin-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bin = dir + "/mytool"
        fm.createFile(atPath: bin, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: dir + "/notexec", contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        #expect(AIClients.findOnPath("mytool", "/nonexistent:\(dir)") == bin)
        #expect(AIClients.findOnPath("notexec", dir) == nil)
        #expect(AIClients.findOnPath("nope", dir) == nil)
    }

    @Test func codexThroughPrism() throws {
        let r = AIClients.recipeFor("codex", "prism {client}")
        #expect(r?.why.contains("OPENAI_BASE_URL") == true)
        let args = r?.args(7331) ?? []
        #expect(args.contains("model_providers.gateway.base_url=\"http://127.0.0.1:7331/v1\""))
        #expect(AIClients.recipeFor("claude", "prism {client}") == nil)
        #expect(AIClients.recipeFor("codex", "other {client}") == nil)
        var o = AIClients.LaunchOptions(); o.launcher = .init(template: "prism {client}"); o.recipeArgs = args
        #expect(Array(try AIClients.launch("codex", o).argv.prefix(4)) == ["prism", "codex", "-c", "model_provider=\"gateway\""])
    }

    @Test func resumeAndName() throws {
        func argv(_ id: String, resume: String = "", name: String = "", model: String = "") throws -> AIClients.Launch {
            var o = AIClients.LaunchOptions(); o.resume = resume; o.name = name; o.model = model
            return try AIClients.launch(id, o)
        }
        #expect(try argv("claude", resume: "last").argv.dropFirst() == ["--continue"])
        #expect(try argv("claude", resume: "pick").argv.dropFirst() == ["--resume"])
        // Codex's is a subcommand: straight after the program, before its options.
        #expect(try argv("codex", resume: "last", model: "gpt-5").argv.dropFirst() == ["resume", "--last", "-m", "gpt-5"])
        #expect(try argv("gemini", resume: "last").argv.dropFirst() == ["--resume", "latest"])
        // No list to choose from: nothing added rather than a flag it does not take.
        #expect(try argv("opencode", resume: "pick").argv.dropFirst().isEmpty)
        let named = try argv("claude", name: "prod upgrade")
        #expect(named.argv.dropFirst() == ["--name", "prod upgrade"])
        #expect(named.title == "prod upgrade")
        #expect(try argv("claude", resume: "last", name: "x").argv.dropFirst() == ["--continue"])
        #expect(try argv("codex", name: "x").argv.dropFirst().isEmpty)
        #expect(try argv("codex", name: "x").title == "x")
    }
}

/// tests/aiwaiting.test.mjs
@Test func aiQuestionsRecognised() {
    for t in [
        "Bash command\n  rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n  2. No",
        "Quick safety check: Is this a project you trust?\n❯ 1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm · Esc to cancel",
        "Allow command `kubectl get pods`?",
        "Overwrite file? (y/n)",
        "Would you like to run the following command?",
        "› 1. Yes, proceed\n  2. No, and tell Codex what to do differently",
        "  2. Yes, and don't ask again for this command",
    ] { #expect(AIWaiting.looksLikeQuestion(t), "\(t)") }
}

@Test func aiNotQuestions() {
    for t in [
        "",
        "✻ Thinking… (12s · esc to interrupt)",
        "> \n  ? for shortcuts",
        "total 48\ndrwxr-xr-x  5 me  staff  160 Oct  9 12:00 .",
        "The tests pass. 1. First, I updated the config. 2. Then I ran it.",
    ] { #expect(!AIWaiting.looksLikeQuestion(t), "\(t)") }
}

@Test func aiResponseName() {
    #expect(AIWindow.responseName("╭────╮\n> fix it\n⏺ Fixed the config in two places.\n") == "Fixed the config in two places.")
    #expect(AIWindow.responseName("────\nThe disk is nearly full\n") == "The disk is nearly full")
}
