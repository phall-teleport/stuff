import AppKit

/// Opening assistants (ai.js `openAi` and what goes with it): the check
/// before one opens, the one-time registration for Pi and Gemini, the offer
/// to open it at every start, the AI menu, and the person's own tools.
@MainActor
enum AIOpen {
    /// Open an assistant in the panel on the right — checked first. All
    /// clear, it opens at once; anything missing is shown with how to fix it.
    static func openAi(_ w: AIWindow, _ id: String, fromStartup: Bool = false, skipCheck: Bool = false,
                       prompt: String = "", send: Bool = true, resume: String = "", name: String = "") async {
        guard let c = AIService.clients().first(where: { $0.id == id })?.client else {
            StatusBus.shared.toast("Unknown assistant: \(id)", kind: .error)
            return
        }
        if !skipCheck {
            StatusBus.shared.show("Checking \(c.name)…", seconds: 0)
            let chk: AICheck
            do { chk = try await AIService.check(id) } catch {
                chk = AICheck(id: id, steps: [AICheckStep(level: "error", label: "Check", detail: error.localizedDescription)])
            }
            StatusBus.shared.clear()
            let clear = chk.steps.allSatisfy { $0.level == "ok" || $0.level == "info" }
            if !clear, !(await checkDialog(w.window, c, chk)) { return }
        }
        let mcpOk = AutomationControl.enabled && (c.mcp != "persist" || Store.shared.aiMap("aiRegistered")[c.id]?.bool == true)
        let l: AILaunch
        do { l = try await AIService.launch(id, withMcp: mcpOk, resume: resume, name: name) } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error); return
        }
        do { try w.add(c, l, prompt: prompt, send: send, name: name) } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error); return
        }
        StatusBus.shared.show(l.title + (mcpOk ? " — with ServerLife’s tools" : ""), seconds: 6)
        if !fromStartup { await offerAlways(w.window, c) }
    }

    /// Another session of an assistant already running: its check has passed
    /// once, so it goes straight to a new chip in the panel, and it is not
    /// asked about again for startup.
    static func openAnother(_ w: AIWindow, _ id: String) async {
        await openAi(w, id, fromStartup: true, skipCheck: true)
    }

    /// Check an assistant without opening it: what is there, what is missing.
    static func checkAi(_ w: AIWindow, _ id: String) async {
        guard let c = AIService.clients().first(where: { $0.id == id })?.client else { return }
        let chk: AICheck
        do { chk = try await AIService.check(id) } catch { StatusBus.shared.toast(error.localizedDescription, kind: .error); return }
        if await checkDialog(w.window, c, chk) { await openAi(w, id, skipCheck: true) }
    }

    /// At launch: the assistant chosen to open every time, if any.
    static func openAtStartup(_ w: AIWindow) async {
        let id = Store.shared.aiStartup
        guard !id.isEmpty, AIService.clients().first(where: { $0.id == id })?.available == true else { return }
        await openAi(w, id, fromStartup: true)
    }

    // MARK: The check

    /// Is this assistant ready? The result as a list, with fixes, and Open
    /// when nothing blocks it. True to open, false to stop.
    static func checkDialog(_ owner: WindowModel?, _ c: AIClients.Client, _ first: AICheck) async -> Bool {
        var chk = first
        while true {
            let res = await AIDialogs.check(owner, c, chk)
            switch res {
            case .open: return true
            case .cancel: return false
            case .again: break
            case .fix(let fix):
                if fix.kind == "run" {
                    var cmd = fix.command ?? ""
                    if fix.edit {
                        guard let v = await Modal.prompt(owner, title: fix.label, value: cmd, ok: "Run"), !v.isEmpty else { continue }
                        cmd = v
                    }
                    runInTerminal(owner, cmd, title: "\(c.name): \(fix.label.lowercased())")
                    return false
                }
                if fix.kind == "automation" { _ = try? AutomationControl.setEnabled(true) }
                if fix.kind == "noToolsOk" { Store.shared.updateSettings(["aiNoToolsOk": true]) }
                if fix.kind == "register" { _ = await registered(owner, c) }
                if fix.kind == "settings" { StatusBus.shared.toast("Settings → AI assistant has the launcher", seconds: 6) }
            }
            do { chk = try await AIService.check(c.id) } catch {
                chk = AICheck(id: c.id, steps: [AICheckStep(level: "error", label: "Check", detail: error.localizedDescription)])
            }
        }
    }

    /// Run a fix the check offered, in a terminal tab the person can watch
    /// and answer: an install, a sign-in. Typed into a login shell so it
    /// finds what their own terminal would.
    static func runInTerminal(_ owner: WindowModel?, _ command: String, title: String) {
        Actions.shared.perform("open-local", window: owner, args: ["title": title])
        after(0.4) {
            Actions.shared.perform("send-text", window: owner, args: ["text": command, "enter": true])
        }
        StatusBus.shared.show("Running: \(command) — come back and press Check again when it is done", seconds: 9)
    }

    /// Pi and Gemini CLI keep MCP servers only in their own config, so
    /// ServerLife is added there once — shown first, run only when agreed to.
    static func registered(_ owner: WindowModel?, _ c: AIClients.Client) async -> Bool {
        if c.mcp != "persist" { return true }
        if Store.shared.aiMap("aiRegistered")[c.id]?.bool == true { return true }
        let cmd = AIService.registerCommand(c.id) ?? ""
        guard await AIDialogs.register(owner, c, cmd) else { return false }
        do {
            let r = try await AIService.register(c.id)
            if !r.ok {
                StatusBus.shared.toast("Could not add ServerLife to \(c.name): \(r.output.isEmpty ? "it failed" : r.output)", kind: .error, seconds: 9)
                return false
            }
        } catch {
            StatusBus.shared.toast("Could not add ServerLife to \(c.name): \(error.localizedDescription)", kind: .error, seconds: 9)
            return false
        }
        Store.shared.setAIMapEntry("aiRegistered", c.id, true)
        return true
    }

    /// After an assistant is opened by hand: offer to open it every time.
    /// Asked once per assistant — never for the one already opening at
    /// startup, and not again after "don't ask".
    static func offerAlways(_ owner: WindowModel?, _ c: AIClients.Client) async {
        if Store.shared.aiStartup == c.id { return }
        if Store.shared.aiMap("aiNoAsk")[c.id]?.bool == true { return }
        let res = await Modal.choose(owner, title: "Open \(c.name) whenever ServerLife starts?",
                                     message: "It opens on the right of the first tab, as now. Settings → AI assistant changes or stops it.",
                                     buttons: ["Always open it", "Not now", "Don’t ask again for \(c.name)"])
        if res == 0 {
            Store.shared.aiStartup = c.id
            StatusBus.shared.show("\(c.name) will open when ServerLife starts")
        } else if res == 2 {
            Store.shared.setAIMapEntry("aiNoAsk", c.id, true)
        }
    }

    // MARK: The AI menu

    /// The launcher from Settings, if one is set: { on, template, clients }.
    static func launcherSetting() -> JSON? {
        let l = Store.shared.settingJSON("aiLauncher")
        return (l["template"].string ?? "").isEmpty ? nil : l
    }

    /// One item per installed assistant, each opening its "How it runs" dialog.
    static func launcherMenuItems(_ w: AIWindow, _ clients: [AIClientInfo]) -> [AIMenuItem] {
        clients.filter(\.available).map { c in
            let mode = AIService.launchMode(c.id)
            let custom = mode.hasPrefix("custom:") ? String(mode.dropFirst(7)) : ""
            let key = mode == "direct" ? "directly" : !custom.isEmpty ? (custom.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? custom) : "default"
            return .item("\(c.name)…", key: key) { Task { await AIDialogs.howItRuns(w, c.id) } }
        }
    }

    /// The assistants as menu items, installed ones first.
    static func menuItems(_ w: AIWindow) -> [AIMenuItem] {
        let clients = AIService.clients()
        let sorted = clients.filter(\.available) + clients.filter { !$0.available }
        var items: [AIMenuItem] = [.heading("AI assistant")]
        for c in sorted {
            if c.available {
                if w.isRunning(c.id) {
                    // A running one is shown, not started again; another is its
                    // own item, a second conversation beside the first.
                    items.append(.item("\(c.name) — show", key: "\(w.runningCount(c.id)) running", title: c.path) { w.showSession(c.id) })
                    items.append(.item("Another \(c.name)", icon: "+", title: "A new session of it, in its own tab in the panel") {
                        Task { await openAnother(w, c.id) }
                    })
                } else {
                    items.append(.item(c.name, key: c.id == Store.shared.aiStartup ? "at start" : "", title: c.path) {
                        Task { await openAi(w, c.id) }
                    })
                }
            } else {
                // Not installed: checking says so, and offers the install.
                items.append(.item("\(c.name) — set up…", key: "not installed",
                                   title: c.client.install.map { "Install with: \($0)" } ?? "Not installed") {
                    Task { await checkAi(w, c.id) }
                })
            }
        }
        items += resumeMenu(w, sorted)
        items.append(.separator)
        items.append(.item("Add a custom AI tool…", title: "Any command-line assistant, with ServerLife’s tools if it takes an MCP config flag") {
            Task { await addCustomTool(w) }
        })
        let custom = Store.shared.aiCustomClients
        if !custom.isEmpty {
            items.append(.sub("Remove a custom tool", custom.map { t in
                .item(t["name"].string ?? "") { removeCustomTool(t["id"].string ?? "") }
            }))
        }
        items.append(.separator)
        items.append(.sub("How each tool runs", title: "Per tool: directly or through a launcher, its model, extra arguments — with the command shown",
                          launcherMenuItems(w, clients)))
        if let l = launcherSetting() {
            let on = l["on"].bool == true
            let template = l["template"].string ?? ""
            items.append(.item("Default launcher: \(template)", key: on ? "✓ on" : "off",
                               title: "Used by every tool set to \"Default launcher\" — set in Settings → AI assistant") {
                var n = l.object ?? [:]
                n["on"] = .bool(!on)
                Store.shared.updateSettings(["aiLauncher": .object(n)])
                StatusBus.shared.show(on ? "Default launcher off" : "Default launcher: \(template)")
            })
        }
        return items
    }

    /// Picking up where a conversation left off: the most recent one, or the
    /// assistant's own list of past ones. Assistants start in one folder of
    /// their own, so "the most recent" is the last one opened from ServerLife.
    static func resumeMenu(_ w: AIWindow, _ clients: [AIClientInfo]) -> [AIMenuItem] {
        let can = clients.filter { $0.available && $0.client.resume?.last != nil }
        if can.isEmpty { return [] }
        var sub: [AIMenuItem] = []
        for c in can {
            sub.append(.item("\(c.name) — the last one") {
                Task { await openAi(w, c.id, fromStartup: true, skipCheck: w.isRunning(c.id), resume: "last") }
            })
            if c.client.resume?.pick != nil {
                sub.append(.item("\(c.name) — choose…", title: "\(c.name)'s own list of past conversations") {
                    Task { await openAi(w, c.id, fromStartup: true, skipCheck: w.isRunning(c.id), resume: "pick") }
                })
            }
        }
        return [.separator, .sub("Pick up a past conversation", icon: "↺", sub)]
    }

    // MARK: Tools of the person's own

    /// Add any command-line assistant: a name, the command, and — if it reads
    /// MCP servers from a flag in the standard `{"mcpServers": …}` JSON, as
    /// Claude Code and Copilot do — that flag, so it gets ServerLife's tools
    /// too. Checked like the built-in ones as soon as it is added.
    static func addCustomTool(_ w: AIWindow, existing: JSON? = nil) async {
        guard let r = await AIDialogs.customTool(w.window, existing: existing) else { return }
        let command = r.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty { StatusBus.shared.toast("A command is needed", kind: .error); return }
        let id = existing?["id"].string ?? "custom-" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry: JSON = .object([
            "id": .string(id),
            "name": .string(name.isEmpty ? (command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? command) : name),
            "command": .string(command),
            "mcpFlag": .string(r.mcpFlag.trimmingCharacters(in: .whitespacesAndNewlines)),
            "install": .string(r.install.trimmingCharacters(in: .whitespacesAndNewlines)),
        ])
        let list = Store.shared.aiCustomClients.filter { $0["id"].string != id }
        Store.shared.updateSettings(["aiCustomClients": .array(list + [entry])])
        AIService.all()
        StatusBus.shared.show("\(entry["name"].string ?? "") added — checking it")
        await checkAi(w, id)
    }

    static func removeCustomTool(_ id: String) {
        let list = Store.shared.aiCustomClients
        let t = list.first { $0["id"].string == id }
        var patch: [String: JSON] = ["aiCustomClients": .array(list.filter { $0["id"].string != id })]
        if Store.shared.aiStartup == id { patch["aiStartup"] = "" }
        Store.shared.updateSettings(patch)
        AIService.all()
        if let t { StatusBus.shared.show("\(t["name"].string ?? "") removed") }
    }

    /// The name of the assistant that opens at startup, if one is set and present.
    static func startupName() -> String? {
        let id = Store.shared.aiStartup
        guard !id.isEmpty else { return nil }
        return AIService.clients().first { $0.id == id && $0.available }?.name
    }

    /// A host, described for an assistant.
    static func describeHost(_ h: Host) -> String {
        let labels = h.labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        let rows: [(String, String?)] = [
            ("Name", h.name), ("Hostname", h.hostname), ("Address", h.addr), ("Cluster", h.cluster?.nilIfEmpty ?? h.proxy),
            ("UUID", h.uuid), ("Logins", (h.extra["logins"]?.items.compactMap(\.stringish) ?? []).joined(separator: ", ")), ("Labels", labels),
        ]
        return rows.compactMap { k, v in (v ?? "").isEmpty ? nil : "\(k): \(v!)" }.joined(separator: "\n")
    }
}
