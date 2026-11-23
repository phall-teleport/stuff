import Foundation

/// AI coding assistants ServerLife can open beside a session, and how each is
/// told about ServerLife's own tools (aiclients.js).
///
/// Every one of these is the vendor's own command-line client, run in a
/// terminal pane — the way Claude Code's VS Code and JetBrains integrations
/// run `claude` — so each signs in the way its vendor intends, with nothing
/// embedded or re-implemented here. What ServerLife adds is the MCP server:
/// the agent can list hosts, open sessions and read cluster state through the
/// same fixed list of verbs MCP.md describes.
///
/// Each client takes MCP servers differently. Where it can be given one for a
/// single session it is (a flag, or a config file named in the environment),
/// so nobody's own setup is edited. Pi and Gemini CLI only read their own
/// config files; for those the registration is a one-time step the person is
/// asked about. Any client can be run through a launcher — a command that
/// wraps it, such as one that routes it through a gateway — configured in
/// Settings rather than known here.
///
/// Pure apart from writing a session config file: the launch is built here
/// and run by the caller, so it can be tested without any client installed.
enum AIClients {
    static let server = "serverlife"

    /// How a client is given ServerLife's MCP server.
    ///   flag    — passed on the command line for this session
    ///   env     — a config file named in the environment, this session
    ///   persist — written to the client's own config, once, when asked
    ///   none    — a custom tool with no MCP flag
    struct Resume: Equatable, Sendable {
        var last: [String]
        var pick: [String]?
        /// The arguments are a subcommand, put straight after the program.
        var lead = false
        func args(_ kind: String) -> [String]? {
            switch kind {
            case "last": return last
            case "pick": return pick
            default: return nil
            }
        }
    }

    struct Client: Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var bin: String
        var vendor: String
        var mcp: String
        var modelFlag: String?
        var resume: Resume?
        var nameFlag: String?
        var install: String?
        var login: String?
        // custom tools
        var extraArgs: [String] = []
        var mcpFlag = ""
        var custom = false
    }

    /// The six assistants ServerLife knows.
    static let builtIn: [Client] = [
        Client(id: "claude", name: "Claude Code", bin: "claude", vendor: "Anthropic", mcp: "flag", modelFlag: "--model",
               resume: Resume(last: ["--continue"], pick: ["--resume"]), nameFlag: "--name",
               install: "npm install -g @anthropic-ai/claude-code", login: "claude auth login"),
        // A subcommand, so it goes straight after the program.
        Client(id: "codex", name: "Codex", bin: "codex", vendor: "OpenAI", mcp: "flag", modelFlag: "-m",
               resume: Resume(last: ["resume", "--last"], pick: ["resume"], lead: true), nameFlag: nil,
               install: "npm install -g @openai/codex", login: "codex login"),
        Client(id: "copilot", name: "GitHub Copilot CLI", bin: "copilot", vendor: "GitHub", mcp: "flag", modelFlag: "--model",
               resume: Resume(last: ["--continue"], pick: ["--resume"]), nameFlag: "--name",
               install: "npm install -g @github/copilot", login: "copilot login"),
        Client(id: "opencode", name: "OpenCode", bin: "opencode", vendor: "open source", mcp: "env", modelFlag: "-m",
               resume: Resume(last: ["--continue"]), nameFlag: nil,
               install: "npm install -g opencode-ai", login: "opencode auth login"),
        Client(id: "pi", name: "Pi", bin: "pi", vendor: "open source", mcp: "persist", modelFlag: "--model",
               resume: Resume(last: ["--continue"], pick: ["--resume"]), nameFlag: "--name",
               install: nil, login: nil),
        Client(id: "gemini", name: "Gemini CLI", bin: "gemini", vendor: "Google", mcp: "persist", modelFlag: "-m",
               resume: Resume(last: ["--resume", "latest"]), nameFlag: nil,
               install: "npm install -g @google/gemini-cli", login: "gemini"),
    ]

    /// A tool the person added themselves: a name, the command that starts it,
    /// and — optionally — the flag it takes MCP servers with, as the standard
    /// `{"mcpServers": {…}}` JSON that Claude Code, Copilot and others read.
    /// Whatever the first word of the command is, that is what is checked for.
    static func customClient(_ raw: JSON) -> Client {
        let command = (raw["command"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let name = (raw["name"].string?.nilIfBlank ?? words.first ?? "AI tool").trimmingCharacters(in: .whitespaces)
        let flag = (raw["mcpFlag"].string ?? "").trimmingCharacters(in: .whitespaces)
        let install = (raw["install"].string ?? "").trimmingCharacters(in: .whitespaces)
        return Client(id: raw["id"].string ?? "", name: name, bin: words.first ?? "", vendor: "added by you",
                      mcp: flag.isEmpty ? "none" : "flag", modelFlag: nil, resume: nil, nameFlag: nil,
                      install: install.isEmpty ? nil : install, login: nil,
                      extraArgs: Array(words.dropFirst()), mcpFlag: flag, custom: true)
    }

    /// The built-in clients and the person's own, as one list.
    static func allClients(_ custom: [JSON] = []) -> [Client] {
        builtIn + custom.filter { ($0["id"].string?.isEmpty == false) && ($0["command"].string?.isEmpty == false) }.map(customClient)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var customList: [JSON] = []
    /// Tell this module about the person's own tools (from settings).
    static func setCustom(_ list: [JSON]) { lock.withLock { customList = list } }

    static func byId(_ id: String) -> Client? {
        let custom = lock.withLock { customList }
        return allClients(custom).first { $0.id == id }
    }

    // MARK: The MCP server

    /// The MCP server definition, in the parts every client asks for. The
    /// Swift build is its own bridge (`ServerLife --mcp`), so there is no
    /// runtime flag to set; SERVERLIFE_USER_DATA tells it which ServerLife to
    /// reach, which matters as soon as two are installed or one is a dev build.
    struct ServerSpec: Equatable, Sendable {
        var command: String
        var args: [String]
        /// In order: Codex's TOML table and the registration commands keep it.
        var env: [(String, String)]
        static func == (a: ServerSpec, b: ServerSpec) -> Bool {
            a.command == b.command && a.args == b.args && a.env.map { [$0.0, $0.1] } == b.env.map { [$0.0, $0.1] }
        }
        var envJSON: JSON { .object(Dictionary(env.map { ($0.0, JSON.string($0.1)) }, uniquingKeysWith: { a, _ in a })) }
        var json: JSON { ["command": .string(command), "args": .array(args.map { .string($0) }), "env": envJSON] }
    }

    static func serverSpec(runtime: String, args: [String] = ["--mcp"], userData: String) -> ServerSpec {
        ServerSpec(command: runtime, args: args, env: [("SERVERLIFE_USER_DATA", userData)])
    }

    /// TOML for one string or a table of strings, for Codex's -c overrides.
    static func tomlStr(_ s: String) -> String { JSON.string(s).jsText() }
    static func tomlTable(_ kv: [(String, String)]) -> String {
        "{ " + kv.map { "\($0.0) = \(tomlStr($0.1))" }.joined(separator: ", ") + " }"
    }

    struct MCPArgs: Sendable {
        var args: [String] = []
        var env: [String: String] = [:]
        /// Written before launch (OpenCode's config): path, text.
        var files: [(String, String)] = []
    }

    /// The arguments and environment that give a client the MCP server for
    /// this session.
    static func mcpFor(_ clientId: String, _ spec: ServerSpec, tmpDir: String = NSTemporaryDirectory()) -> MCPArgs {
        let s = server
        switch clientId {
        case "claude":
            return MCPArgs(args: ["--mcp-config", JSON.object(["mcpServers": [s: spec.json]]).jsText()])
        case "codex":
            return MCPArgs(args: [
                "-c", "mcp_servers.\(s).command=\(tomlStr(spec.command))",
                "-c", "mcp_servers.\(s).args=[\(spec.args.map(tomlStr).joined(separator: ", "))]",
                "-c", "mcp_servers.\(s).env=\(tomlTable(spec.env))",
            ])
        case "copilot":
            var o = spec.json
            o["type"] = "local"
            o["tools"] = ["*"]
            return MCPArgs(args: ["--additional-mcp-config", JSON.object(["mcpServers": [s: o]]).jsText()])
        case "opencode":
            let file = (tmpDir as NSString).appendingPathComponent("serverlife-opencode.json")
            let config: JSON = [
                "$schema": "https://opencode.ai/config.json",
                "mcp": [s: ["type": "local", "command": .array(([spec.command] + spec.args).map { .string($0) }),
                            "environment": spec.envJSON, "enabled": true]],
            ]
            return MCPArgs(args: [], env: ["OPENCODE_CONFIG": file], files: [(file, config.jsText(indent: 2))])
        default:
            // A tool of the person's own that names a flag for MCP config.
            if let c = byId(clientId), c.custom, !c.mcpFlag.isEmpty {
                return MCPArgs(args: [c.mcpFlag, JSON.object(["mcpServers": [s: spec.json]]).jsText()])
            }
            // Pi and Gemini read only their own config: see registerCommand.
            return MCPArgs()
        }
    }

    /// The one-time command that adds ServerLife to a client that keeps MCP
    /// servers only in its own config. Shown to the person before it is run.
    static func registerCommand(_ clientId: String, _ spec: ServerSpec) -> [String]? {
        func envFlags(_ flag: String) -> [String] { spec.env.flatMap { [flag, "\($0.0)=\($0.1)"] } }
        if clientId == "pi" { return ["pi", "mcp", "add", server] + envFlags("--env") + ["--", spec.command] + spec.args }
        if clientId == "gemini" { return ["gemini", "mcp", "add", "--scope", "user"] + envFlags("-e") + [server, spec.command] + spec.args }
        return nil
    }

    // MARK: Command lines

    /// Words from a line a person typed: whitespace-separated, with "double"
    /// or 'single' quotes keeping spaces in one word. Enough for extra arguments.
    static func splitWords(_ line: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #""([^"]*)"|'([^']*)'|(\S+)"#) else { return [] }
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { m in
            for g in 1...3 where m.range(at: g).location != NSNotFound { return ns.substring(with: m.range(at: g)) }
            return ""
        }
    }

    /// One argument for a POSIX shell, quoted only when it needs it.
    static func shq(_ v: String) -> String {
        if !v.isEmpty, v.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return v }
        return "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct Launcher: Equatable, Sendable {
        var template: String
        var clients: [String] = []
    }

    /// The client's command line, run through a launcher if one is set.
    ///
    /// A launcher is any command the person wants assistants run through — one
    /// that routes them through a gateway, sets up credentials, records usage.
    /// `{client}` is replaced by the assistant's name (claude, codex, …) with
    /// its arguments after it; `{command}` by its whole command line; with
    /// neither, the command is added after the launcher. Only the clients
    /// listed in `clients` go through it, when a list is given.
    static func withLauncher(_ clientId: String, _ argv: [String], _ launcher: Launcher?) -> (argv: [String], launched: Bool) {
        let template = (launcher?.template ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty, let l = launcher, l.clients.isEmpty || l.clients.contains(clientId) else { return (argv, false) }
        let words = template.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let out: [String]
        if words.contains("{client}") {
            out = words.flatMap { $0 == "{client}" ? [clientId] + argv.dropFirst() : [$0] }
        } else if words.contains("{command}") {
            out = words.flatMap { $0 == "{command}" ? argv : [$0] }
        } else {
            out = words + argv
        }
        return (out, true)
    }

    struct Launch: Sendable {
        /// What is run: the person's shell.
        var command: String
        var args: [String]
        var env: [String: String]
        var files: [(String, String)]
        var title: String
        var client: Client
        var launched: Bool
        /// The command line before it is handed to the shell.
        var argv: [String]
    }

    struct LaunchOptions {
        var spec: ServerSpec?
        var launcher: Launcher?
        var shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var tmpDir = NSTemporaryDirectory()
        var model = ""
        var extraArgs = ""
        var recipeArgs: [String] = []
        /// "last", "pick" or "".
        var resume = ""
        var name = ""
    }

    /// How to start a client: the program, its arguments and environment.
    ///
    /// Through the person's login shell, so `claude` is found wherever their
    /// shell finds it — nvm, Homebrew, ~/.local/bin — which an app started
    /// from the Dock cannot see.
    static func launch(_ clientId: String, _ o: LaunchOptions = LaunchOptions()) throws -> Launch {
        guard let c = byId(clientId) else { throw AppError("Unknown assistant: \(clientId)") }
        let mcp = o.spec.map { mcpFor(clientId, $0, tmpDir: o.tmpDir) } ?? MCPArgs()
        // A model chosen for this tool goes on its own model flag — which also
        // keeps a tool from guessing a provider from whatever credentials
        // happen to be in the environment. Extra arguments are whatever else
        // the person wants on this tool's command line.
        let model = o.model.trimmingCharacters(in: .whitespaces)
        let modelArgs = !model.isEmpty && c.modelFlag != nil ? [c.modelFlag!, model] : []
        let extra = splitWords(o.extraArgs)
        // Picking up a past conversation ('last' or 'pick'), and a name for a
        // new one — each only where the client has a way to; a resumed
        // conversation keeps the name it had.
        let again = o.resume.isEmpty ? [] : (c.resume?.args(o.resume) ?? [])
        let lead = c.resume?.lead == true ? again : []
        let tail = c.resume?.lead == true ? [] : again
        let label = o.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameArgs = !label.isEmpty && c.nameFlag != nil && again.isEmpty ? [c.nameFlag!, label] : []
        let (argv, launched) = withLauncher(clientId,
            [c.bin] + lead + c.extraArgs + o.recipeArgs + modelArgs + extra + nameArgs + tail + mcp.args, o.launcher)
        let title = label.isEmpty ? c.name + (launched ? " · via launcher" : "") : label
        // Login and interactive, as the person's own terminal starts: ~/.zshrc
        // is where Homebrew, nvm and the like are often set up, and a login
        // shell alone does not read it. The pane is a real terminal, so -i is
        // at home.
        return Launch(command: o.shell, args: ["-l", "-i", "-c", "exec " + argv.map(shq).joined(separator: " ")],
                      env: mcp.env, files: mcp.files, title: title, client: c, launched: launched, argv: argv)
    }

    // MARK: Launchers

    struct Recipe: Sendable {
        var why: String
        var needs: String
        var args: @Sendable (Int) -> [String]
    }

    struct KnownLauncher: Sendable {
        var bin: String
        var template: String
        var clients: [String]
        var about: String
        var recipes: [String: Recipe]
    }

    /// Launchers worth suggesting, when their command is installed. Suggested
    /// only — nothing is used unless the person picks it in Settings.
    static let knownLaunchers: [KnownLauncher] = [
        KnownLauncher(
            bin: "prism", template: "prism {client}", clients: ["claude", "codex", "opencode", "pi"],
            about: "routes assistants through a Teleport cluster’s LLM gateways, signed in as you in Teleport",
            // What a client needs beyond the launcher, applied by ServerLife so
            // nobody has to know it. Codex no longer reads OPENAI_BASE_URL,
            // which is all prism sets, so on its own it went straight to
            // OpenAI; a provider pointing at prism's router is what makes it go
            // through the gateway. The router's port is read from prism's state
            // when the tool starts.
            recipes: ["codex": Recipe(
                why: "Codex ignores OPENAI_BASE_URL, so ServerLife points a Codex model provider at the gateway on this machine.",
                needs: "prismPort",
                args: { port in [
                    "-c", "model_provider=\"gateway\"",
                    "-c", "model_providers.gateway.name=\"Teleport gateway\"",
                    "-c", "model_providers.gateway.base_url=\"http://127.0.0.1:\(port)/v1\"",
                    "-c", "model_providers.gateway.env_key=\"OPENAI_API_KEY\"",
                    "-c", "model_providers.gateway.wire_api=\"responses\"",
                ] })]),
    ]

    /// The recipe a client needs for a launcher, if one is known.
    static func recipeFor(_ clientId: String, _ template: String) -> Recipe? {
        let first = template.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return knownLaunchers.first { $0.bin == first }?.recipes[clientId]
    }

    /// prism's router port, from its state file, or nil.
    static func prismPort(home: String = NSHomeDirectory()) -> Int? {
        let dir = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".config")
        let file = ((dir as NSString).appendingPathComponent("prism") as NSString).appendingPathComponent("state.json")
        guard let data = FileManager.default.contents(atPath: file), let j = try? JSON.parse(data) else { return nil }
        return j["local_port"].int.flatMap { $0 == 0 ? nil : $0 }
    }

    // MARK: Finding tools

    /// Where command-line tools are installed, for an environment that does
    /// not already have them on PATH — an app opened from the Dock has only
    /// launchd's /usr/bin:/bin:/usr/sbin:/sbin.
    static func toolDirs(home: String = NSHomeDirectory()) -> [String] {
        func h(_ p: String) -> String { (home as NSString).appendingPathComponent(p) }
        return ["/opt/homebrew/bin", "/usr/local/bin", h(".local/bin"), h("bin"), h(".npm-global/bin"), h(".bun/bin"),
                h(".cargo/bin"), h(".volta/bin"), h(".claude/local")]
    }

    /// The first executable named `bin` in the directories of `path`, or nil.
    static func findOnPath(_ bin: String, _ path: String) -> String? {
        if bin.isEmpty { return nil }
        let fm = FileManager.default
        if bin.contains("/") { return fm.fileExists(atPath: bin) ? bin : nil }
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            let full = (dir as NSString).appendingPathComponent(bin)
            var isDir: ObjCBool = false
            if fm.isExecutableFile(atPath: full), fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { return full }
        }
        return nil
    }

    /// A PATH with the tool directories appended.
    static func withToolPath(_ path: String) -> String {
        let have = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let add = toolDirs().filter { !have.contains($0) }
        return (have + add).joined(separator: ":")
    }

    /// Write a launch's files (OpenCode's session config) before starting it.
    static func writeFiles(_ files: [(String, String)]) throws {
        let fm = FileManager.default
        for (file, text) in files {
            try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: file))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        }
    }
}

extension String {
    /// nil when only whitespace (AI-owned helper).
    fileprivate var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
