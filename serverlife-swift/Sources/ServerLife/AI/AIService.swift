import AppKit
import Foundation

/// The settings the assistants use (store.js keys; defaults as the original
/// treats a missing value).
extension Store {
    var aiKeys: Bool { get { setting("aiKeys", true) } set { setSetting("aiKeys", newValue) } }
    var aiStartup: String { get { setting("aiStartup", "") } set { setSetting("aiStartup", newValue) } }
    var aiWorkdirSetting: String { setting("aiWorkdir", "") }
    var aiNoToolsOk: Bool { setting("aiNoToolsOk", false) }
    var automationTyping: String { settingJSON("automationTyping").string?.nilIfEmptyAI ?? "ask" }
    var aiPanelWidthSetting: Double? { settingJSON("aiPanelWidth").double }
    var focusFollowsMouseAI: Bool { setting("focusFollowsMouse", false) }
    /// The person's own tools: [{id, name, command, mcpFlag, install}].
    var aiCustomClients: [JSON] { settingJSON("aiCustomClients").array ?? [] }
    /// Saved prompts, [{name, text}], or nil when never edited (the starters show).
    var aiPromptsSetting: [JSON]? { settingJSON("aiPrompts").array }
    func aiMap(_ key: String) -> [String: JSON] { settingJSON(key).object ?? [:] }
    func setAIMapEntry(_ key: String, _ id: String, _ value: JSON?) {
        var m = aiMap(key)
        if let value { m[id] = value } else { m.removeValue(forKey: id) }
        updateSettings([key: .object(m)])
    }
}

extension String {
    fileprivate var nilIfEmptyAI: String? { isEmpty ? nil : self }
}

/// One assistant as the panel sees it: the client and whether it is installed.
struct AIClientInfo: Identifiable, Equatable {
    var client: AIClients.Client
    var path: String?
    var id: String { client.id }
    var name: String { client.name }
    var available: Bool { path != nil }
}

struct AICheckStep: Identifiable {
    struct Fix {
        /// run | automation | noToolsOk | register | settings
        var kind: String
        var label: String
        var command: String?
        var edit = false
        var alt: [Fix] = []
    }
    let id = uid("step")
    /// ok | error | warn | info
    var level: String
    var label: String
    var detail: String?
    var fix: Fix?
}

struct AICheck {
    var id: String
    var steps: [AICheckStep]
    var ready: Bool { !steps.contains { $0.level == "error" } }
}

struct AILaunch {
    var command: String
    var args: [String]
    var env: [String: String]
    var title: String
    var launched: Bool
    var cwd: String
}

struct AISavedResponse: Identifiable, Equatable {
    var file: String
    var path: String
    var title: String
    var size: Int
    var mtime: Double
    var id: String { file }
}

/// main.js's AI handlers (`ai:*`): which assistants are installed, the check
/// before one opens, how it is launched, the folder it starts in and the
/// saved responses kept there.
@MainActor
enum AIService {
    /// The person's PATH, as their own terminal has it, with the usual tool
    /// directories: `Proc.path` already asked the login shell for it, in the
    /// background at launch.
    static var toolPath: String { AIClients.withToolPath(Proc.path) }

    /// A plain shell with the person's PATH: no ~/.zshrc, so no waiting on it.
    /// Its output, or "" on failure.
    static func shellOut(_ script: String, timeout: Double = 20) async -> String {
        let r = await Proc.run("/bin/sh", ["-c", script], env: ["PATH": toolPath], timeout: timeout)
        return r.out
    }

    /// The MCP server, as every client is given it: this binary as its own bridge.
    static func spec() -> AIClients.ServerSpec {
        AIClients.serverSpec(runtime: AutomationControl.binaryPath, args: ["--mcp"], userData: AutomationControl.dataDir)
    }

    /// The person's own tools, from settings, alongside the built-in ones.
    @discardableResult
    static func all() -> [AIClients.Client] {
        let custom = Store.shared.aiCustomClients
        AIClients.setCustom(custom)
        return AIClients.allClients(custom)
    }

    /// The launcher assistants go through, from Settings: { on, template,
    /// clients }. Off, or with no template, they run directly.
    static func launcher() -> AIClients.Launcher? {
        let l = Store.shared.settingJSON("aiLauncher")
        guard l["on"].bool == true, let t = l["template"].string, !t.isEmpty else { return nil }
        return AIClients.Launcher(template: t, clients: l["clients"].stringArray ?? [])
    }

    /// The launcher for one assistant. Each can say for itself: 'direct'
    /// (never a launcher), 'custom:<template>' (its own), or 'default' /
    /// unset — the global launcher, if it is on and covers this assistant.
    /// Returned with an empty client list, since it has already been decided
    /// for this one.
    static func launcherFor(_ id: String) -> AIClients.Launcher? {
        let mode = launchMode(id)
        if mode == "direct" { return nil }
        if mode.hasPrefix("custom:") {
            let t = String(mode.dropFirst("custom:".count)).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : AIClients.Launcher(template: t)
        }
        guard let g = launcher(), g.clients.isEmpty || g.clients.contains(id) else { return nil }
        return AIClients.Launcher(template: g.template)
    }

    /// How one assistant is launched: 'default', 'direct' or 'custom:<template>'.
    static func launchMode(_ id: String) -> String {
        Store.shared.aiMap("aiClientLaunch")[id]?.string?.nilIfEmptyAI ?? "default"
    }

    // MARK: ai:clients

    /// What is installed, looked up on disk along the person's PATH — no
    /// shell, so it answers at once.
    static func clients() -> [AIClientInfo] {
        let list = all()
        let p = toolPath
        var found: [String: String] = [:]
        for b in Set(list.map(\.bin).filter { !$0.isEmpty }) {
            if let hit = AIClients.findOnPath(b, p) { found[b] = hit }
        }
        return list.map { AIClientInfo(client: $0, path: found[$0.bin]) }
    }

    // MARK: ai:launch

    /// Arguments a known launcher needs for this client (recipes in
    /// AIClients). prism's port is read from its state, after `prism up` —
    /// idempotent, and quick when it is already up — so the port is real.
    static func recipeArgs(_ id: String, _ launcher: AIClients.Launcher?) async -> (args: [String], why: String?, missing: String?) {
        guard let l = launcher, let r = AIClients.recipeFor(id, l.template) else { return ([], nil, nil) }
        if r.needs == "prismPort" {
            var port = AIClients.prismPort()
            if port == nil { _ = await shellOut("prism up >/dev/null 2>&1", timeout: 90); port = AIClients.prismPort() }
            guard let port else { return ([], r.why, "The launcher’s gateway is not running, and could not be started") }
            return (r.args(port), r.why, nil)
        }
        return ([], r.why, nil)
    }

    static func launch(_ id: String, withMcp: Bool = true, resume: String = "", name: String = "") async throws -> AILaunch {
        all()
        let launcher = launcherFor(id)
        let recipe = await recipeArgs(id, launcher)
        var o = AIClients.LaunchOptions()
        o.recipeArgs = recipe.args
        o.spec = withMcp ? spec() : nil
        o.launcher = launcher
        o.model = Store.shared.aiMap("aiClientModel")[id]?.string ?? ""
        o.extraArgs = Store.shared.aiMap("aiClientArgs")[id]?.string ?? ""
        o.tmpDir = Store.shared.dir.appendingPathComponent("ai-sessions").path
        o.resume = resume
        o.name = name
        let l = try AIClients.launch(id, o)
        try AIClients.writeFiles(l.files)
        return AILaunch(command: l.command, args: l.args, env: l.env, title: l.title, launched: l.launched, cwd: workdir())
    }

    // MARK: The assistants' folder

    static let agentsGuide = [
        "# Running inside ServerLife",
        "",
        "You were started from ServerLife, a terminal and server manager for Teleport and SSH.",
        "Its MCP tools are named `serverlife_*`: list hosts and clusters, open sessions, run the",
        "user's saved macros, read what a terminal shows (`serverlife_read_output`) and, with the",
        "user's approval each time, type into a session (`serverlife_type_into_session`).",
        "",
        "Prefer those tools for anything on the user's servers rather than guessing hostnames.",
        "This folder is your working folder; it holds nothing else.",
        "",
    ].joined(separator: "\n")

    /// The folder assistants start in. Not the home folder: Claude Code does
    /// not remember trusting a home folder, so it asked "do you trust this
    /// folder?" on every start. A folder of their own is trusted once and
    /// remembered — and it gets an AGENTS.md (read by Claude Code, Codex and
    /// the rest) that says where they are running and which tools ServerLife
    /// gives them. One the person wrote is never touched.
    @discardableResult
    static func workdir() -> String {
        let dir = expandWorkdir(Store.shared.aiWorkdirSetting)
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let guide = (dir as NSString).appendingPathComponent("AGENTS.md")
            if !fm.fileExists(atPath: guide) { try Data(agentsGuide.utf8).write(to: URL(fileURLWithPath: guide)) }
        } catch { /* fall back to the home folder in the terminal */ }
        return dir
    }

    nonisolated static func expandWorkdir(_ raw: String, home: String = NSHomeDirectory()) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "~" { s = home } else if s.hasPrefix("~/") { s = home + s.dropFirst(1) }
        return s.isEmpty ? (home as NSString).appendingPathComponent("ServerLife AI") : s
    }

    // MARK: Saved responses

    /// What an assistant said that is worth keeping, one Markdown file each in
    /// "saved" in the assistants' folder — where Finder shows them and where
    /// an assistant can be asked to read them again.
    static var savedDir: String { (workdir() as NSString).appendingPathComponent("saved") }

    static func savedPath(_ file: String) throws -> String {
        let p = (savedDir as NSString).appendingPathComponent((file as NSString).lastPathComponent)
        guard p.hasSuffix(".md") else { throw AppError("Not a saved response") }
        return p
    }

    nonisolated static func slug(_ name: String) -> String {
        var s = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        s = s.replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        let cut = String(s.prefix(50))
        return cut.isEmpty ? "response" : cut
    }

    @discardableResult
    static func saveResponse(title: String, text: String, source: String = "") throws -> (file: String, path: String) {
        // Trailing spaces off every line, as the terminal pads them.
        let cleaned = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw AppError("Nothing to save") }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = t.isEmpty ? String((cleaned.components(separatedBy: "\n").first ?? "").prefix(60)) : t
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = f.string(from: now)
        let dir = savedDir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = slug(name)
        var file = (dir as NSString).appendingPathComponent("\(stamp)-\(s).md")
        var i = 2
        while FileManager.default.fileExists(atPath: file) {
            file = (dir as NSString).appendingPathComponent("\(stamp)-\(s)-\(i).md")
            i += 1
        }
        let when = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .medium)
        let head = ["# \(name)", "", "Saved \(when)\(source.isEmpty ? "" : " from \(source)").", "", ""].joined(separator: "\n")
        try Data((head + cleaned + "\n").utf8).write(to: URL(fileURLWithPath: file))
        return ((file as NSString).lastPathComponent, file)
    }

    static func savedList() -> [AISavedResponse] {
        let dir = savedDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [AISavedResponse] = []
        for f in names where f.hasSuffix(".md") {
            let full = (dir as NSString).appendingPathComponent(f)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                  let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            let title = text.components(separatedBy: "\n").first { $0.hasPrefix("# ") && $0.count > 2 }.map { String($0.dropFirst(2)) } ?? f
            out.append(AISavedResponse(file: f, path: full, title: title, size: (attrs[.size] as? Int) ?? 0,
                                       mtime: ((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000))
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    static func savedRead(_ file: String) throws -> String {
        try String(contentsOfFile: try savedPath(file), encoding: .utf8)
    }

    static func savedDelete(_ file: String) throws {
        try FileManager.default.removeItem(atPath: try savedPath(file))
    }

    static func savedReveal(_ file: String? = nil) {
        if let file, let p = try? savedPath(file) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else {
            try? FileManager.default.createDirectory(atPath: savedDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: savedDir))
        }
    }

    // MARK: ai:check

    /// Is this assistant ready to open? Each step says what it found and,
    /// where something is missing, how to put it right — a command to run, a
    /// setting to turn on.
    static func check(_ id: String) async throws -> AICheck {
        all()
        guard let c = AIClients.byId(id) else { throw AppError("Unknown assistant: \(id)") }
        var steps: [AICheckStep] = []
        func add(_ level: String, _ label: String, _ detail: String?, _ fix: AICheckStep.Fix? = nil) {
            steps.append(AICheckStep(level: level, label: label, detail: detail, fix: fix))
        }
        let q = AIClients.shq

        let ver = (await shellOut("command -v \(q(c.bin)) >/dev/null 2>&1 && { \(q(c.bin)) --version 2>&1 | head -1; } || echo __missing__", timeout: 8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ver.isEmpty || ver.contains("__missing__") {
            add("error", "\(c.name) is installed", "`\(c.bin)` is not on your PATH.",
                c.install.map { .init(kind: "run", label: "Install", command: $0) })
            return AICheck(id: id, steps: steps)
        }
        add("ok", "\(c.name) is installed", ver)

        let launcher = launcherFor(id)
        if let launcher {
            let first = launcher.template.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            let whereIs = (await shellOut("command -v \(q(first)) 2>/dev/null")).trimmingCharacters(in: .whitespacesAndNewlines)
            if whereIs.isEmpty {
                add("error", "The launcher `\(first)` is installed",
                    "Settings runs assistants through `\(launcher.template)`, and `\(first)` is not on your PATH.",
                    .init(kind: "settings", label: "Open Settings"))
            } else {
                add("ok", "Runs through `\(launcher.template)`", whereIs)
                // A launcher that names a Teleport cluster: is there a login for it?
                if first == "prism" {
                    let cfg = await shellOut("prism config show 2>/dev/null")
                    let proxy = JSON.tryParse(cfg)["proxy"].string?.nilIfEmptyAI
                    if let proxy {
                        let st = await shellOut("tsh status --proxy=\(q(proxy)) 2>&1")
                        let validLine = st.components(separatedBy: "\n").first { $0.contains("Valid until") } ?? ""
                        let valid = st.range(of: "Valid until:[^\\n]*valid for", options: [.regularExpression, .caseInsensitive]) != nil
                            && !validLine.contains("EXPIRED")
                        add(valid ? "ok" : "error", "Logged in to \(proxy)",
                            valid ? "Teleport login is valid" : "The Teleport login has expired or is missing.",
                            valid ? nil : .init(kind: "run", label: "Log in", command: "tsh login --proxy=\(proxy)"))
                    } else {
                        add("error", "The launcher knows which cluster to use", "No Teleport cluster is set for the launcher yet.",
                            .init(kind: "run", label: "Set the cluster", command: "prism config set proxy <cluster>:443", edit: true))
                    }
                }
            }
        }

        // Signed in to the vendor — unless a launcher is doing the signing in.
        if launcher != nil {
            add("info", "Signed in", "Through the launcher, so no vendor sign-in is needed.")
        } else if id == "claude" {
            let out = await shellOut("claude auth status 2>/dev/null", timeout: 8)
            let st = out.firstIndex(of: "{").map { JSON.tryParse(String(out[$0...])) } ?? .null
            let ok = st["loggedIn"].bool == true
            add(ok ? "ok" : "error", "Signed in", ok ? (st["authMethod"].string?.nilIfEmptyAI ?? "signed in") : "Not signed in.",
                ok ? nil : .init(kind: "run", label: "Sign in", command: c.login))
        } else if id == "codex" {
            let out = (await shellOut("codex login status 2>&1", timeout: 8)).trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = out.range(of: "logged in", options: .caseInsensitive) != nil
            add(ok ? "ok" : "error", "Signed in", out.isEmpty ? "Not signed in." : out, ok ? nil : .init(kind: "run", label: "Sign in", command: c.login))
        } else if id == "opencode" {
            let out = await shellOut("opencode auth list 2>&1", timeout: 8)
            var n = 0
            if let r = out.range(of: "(\\d+)\\s+credentials?", options: .regularExpression) {
                n = Int(out[r].prefix { $0.isNumber }) ?? 0
            }
            add(n > 0 ? "ok" : "warn", "Signed in to a provider",
                n > 0 ? "\(n) saved credential\(n == 1 ? "" : "s")" : "No saved credentials — OpenCode will offer only its free models.",
                n > 0 ? nil : .init(kind: "run", label: "Sign in", command: c.login))
        } else if id == "gemini" {
            let env = ProcessInfo.processInfo.environment
            let ok = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.gemini/oauth_creds.json")
                || !(env["GEMINI_API_KEY"] ?? "").isEmpty || !(env["GOOGLE_API_KEY"] ?? "").isEmpty
            add(ok ? "ok" : "warn", "Signed in", ok ? "Credentials found" : "Not yet — Gemini asks you to sign in in the browser when it first opens.")
        } else if c.custom {
            add("info", "Signed in", "\(c.name) signs in its own way — ServerLife cannot check it.")
        } else if id == "copilot" {
            add("info", "Signed in", "Copilot asks you to sign in with GitHub when it first opens, if needed (/login).")
        } else {
            add("info", "Signed in", "\(c.name) signs in per model provider: `pi auth check --provider <name>`.")
        }

        // ServerLife's tools, over MCP.
        let bridge = AutomationControl.binaryPath
        if !AutomationControl.enabled {
            // Said once, then — if the person would rather not have them — not again.
            let quiet = Store.shared.aiNoToolsOk
            add(quiet ? "info" : "warn", "ServerLife’s tools are available", "Local automation is off, so the assistant opens without them.",
                quiet ? nil : .init(kind: "automation", label: "Turn on", alt: [.init(kind: "noToolsOk", label: "Don’t ask again")]))
        } else if !FileManager.default.fileExists(atPath: bridge) {
            add("error", "ServerLife’s tools are available", "The MCP bridge is missing: \(bridge)")
        } else if c.mcp == "none" {
            add("info", "ServerLife’s tools are available", "No MCP flag was given for \(c.name), so it opens without them. Edit the tool to add one.")
        } else if c.mcp == "persist" {
            let cfg = id == "pi" ? NSHomeDirectory() + "/.pi/agent/mcp.json" : NSHomeDirectory() + "/.gemini/settings.json"
            let has = (try? String(contentsOfFile: cfg, encoding: .utf8))?.contains("\"serverlife\"") ?? false
            add(has ? "ok" : "warn", "ServerLife’s tools are available",
                has ? "Registered in \(cfg)" : "\(c.name) keeps MCP servers in \(cfg); ServerLife is not there yet.",
                has ? nil : .init(kind: "register", label: "Add it"))
        } else {
            add("ok", "ServerLife’s tools are available", "Given to it for each session")
        }
        return AICheck(id: id, steps: steps)
    }

    // MARK: ai:preview

    struct Draft { var mode = "default"; var template = ""; var model = ""; var extraArgs = "" }

    /// What will run, for the "How it runs" dialog: settings as they would be
    /// saved (`draft`), shown as the command line — the MCP config shortened.
    static func preview(_ id: String, _ d: Draft) throws -> (command: String, recipe: String?, launched: Bool) {
        all()
        guard AIClients.byId(id) != nil else { throw AppError("Unknown assistant: \(id)") }
        var launcher: AIClients.Launcher?
        let t = d.template.trimmingCharacters(in: .whitespaces)
        if d.mode == "custom", !t.isEmpty { launcher = .init(template: t) }
        else if d.mode == "default", let g = Self.launcher(), g.clients.isEmpty || g.clients.contains(id) { launcher = .init(template: g.template) }
        let r = launcher.flatMap { AIClients.recipeFor(id, $0.template) }
        var o = AIClients.LaunchOptions()
        o.launcher = launcher
        o.model = d.model
        o.extraArgs = d.extraArgs
        if let r {
            if let port = AIClients.prismPort() { o.recipeArgs = r.args(port) }
            else { o.recipeArgs = r.args(0).map { $0.replacingOccurrences(of: "127.0.0.1:0/", with: "127.0.0.1:<gateway port>/") } }
        }
        let l = try AIClients.launch(id, o)
        let words = l.argv.map { $0.hasPrefix("{\"mcpServers\"") ? "'{…serverlife MCP…}'" : AIClients.shq($0) }
        return (words.joined(separator: " "), r?.why, l.launched)
    }

    static func registerCommand(_ id: String) -> String? {
        AIClients.registerCommand(id, spec()).map { $0.map(AIClients.shq).joined(separator: " ") }
    }

    static func register(_ id: String) async throws -> (ok: Bool, output: String) {
        guard let argv = AIClients.registerCommand(id, spec()) else {
            throw AppError("This assistant takes ServerLife for each session; nothing to register")
        }
        let out = await shellOut(argv.map(AIClients.shq).joined(separator: " ") + " 2>&1; echo \"exit=$?\"", timeout: 30)
        let ok = out.range(of: "exit=0\\s*$", options: .regularExpression) != nil
        let output = out.replacingOccurrences(of: "exit=\\d+\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return (ok, output)
    }
}
