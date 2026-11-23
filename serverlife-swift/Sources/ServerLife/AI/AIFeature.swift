import AppKit
import SwiftUI

/// The AI assistant: wiring (ai.js's exports, as actions and a slot).
@MainActor
enum AIFeature {
    static func ai(_ ctx: ActionContext) -> AIWindow? {
        (ctx.window ?? WindowManager.shared.focused ?? WindowManager.shared.windows.first)?.feature(AIWindow.self)
    }

    static func install() {
        Slots.rightPanel = { w in AnyView(AIPanelView(window: w, ai: w.feature(AIWindow.self))) }
        Slots.rightPanelShown = { w in w.feature(AIWindow.self).shown }

        let a = Actions.shared
        // The ✦ toolbar button.
        a.register("toggle-ai") { ctx in ai(ctx)?.toggle() }
        // Open an assistant by client id (`name` or `id`), or the menu of them.
        a.register("ai-open") { ctx in
            guard let w = ai(ctx) else { return }
            let id = ctx.arg("id", as: String.self) ?? ctx.arg("name", as: String.self) ?? ""
            if id.isEmpty { AIMenu.show(AIOpen.menuItems(w)); return }
            Task { await AIOpen.openAi(w, id, prompt: ctx.arg("prompt", as: String.self) ?? "") }
        }
        // profiles.js `openAiPicker`: the assistants menu, at the mouse.
        a.register("ai-picker") { ctx in if let w = ai(ctx) { AIMenu.show(AIOpen.menuItems(w)) } }
        // The AI row's double-click: a new session with a first message.
        a.register("ai-prompt") { ctx in if let w = ai(ctx) { Task { await AIDialogs.openAiPrompt(w) } } }
        // "Ask the AI about this": args `text`; `source` (or `title`) says
        // where it came from; with a host and no text, the host described.
        // `send` true sends it as it is (a saved prompt from search).
        a.register("ai-ask") { ctx in
            guard let w = ai(ctx) else { return }
            var text = ctx.arg("text", as: String.self) ?? ""
            var source = ctx.arg("source", as: String.self) ?? ctx.arg("title", as: String.self)
            if text.isEmpty, let h = ctx.host {
                text = AIOpen.describeHost(h)
                source = source ?? "the host \(h.name.isEmpty ? h.label : h.name) in ServerLife"
            }
            if ctx.arg("send", as: Bool.self) == true {
                Task { await w.askAi(text, send: true) }
            } else {
                Task { await w.askAbout(text, source: source ?? "ServerLife") }
            }
        }
        // automation.js `type_text` / `read_output`, for the MCP verbs.
        a.register("ai-type-request") { ctx in
            let verb = ctx.arg("verb", as: String.self) ?? "type_text"
            let params = ctx.arg("params", as: JSON.self) ?? .object([:])
            let reply = ctx.arg("reply", as: ((Result<JSON, Error>) -> Void).self)
            guard let w = ctx.window ?? WindowManager.shared.focused ?? WindowManager.shared.windows.first else {
                reply?(.failure(AppError("No ServerLife window is open."))); return
            }
            Task {
                do {
                    let r = verb == "read_output" ? try AITyping.readOutput(params, window: w)
                                                  : try await AITyping.typeText(params, window: w)
                    reply?(.success(r))
                } catch { reply?(.failure(error)) }
            }
        }
        // Queries (reply synchronously).
        a.register("ai-clients") { ctx in
            let reply = ctx.arg("reply", as: ((Any?) -> Void).self)
            reply?(AIService.clients().map { c -> JSON in
                ["id": .string(c.id), "name": .string(c.name), "vendor": .string(c.client.vendor),
                 "available": .bool(c.available), "custom": .bool(c.client.custom)]
            })
        }
        a.register("ai-saved-prompts") { ctx in
            ctx.arg("reply", as: ((Any?) -> Void).self)?(AIPrompts.list().map { p -> JSON in
                ["name": .string(p.name), "text": .string(p.text)]
            })
        }
        a.register("ai-saved-responses") { ctx in
            ctx.arg("reply", as: ((Any?) -> Void).self)?(AIService.savedList().map { r -> JSON in
                ["title": .string(r.title), "file": .string(r.file), "path": .string(r.path),
                 "size": .number(Double(r.size)), "mtime": .number(r.mtime)]
            })
        }
        a.register("ai-saved-open") { ctx in AIDialogs.savedResponses(ai(ctx)) }
        a.register("ai-prompt-save") { ctx in
            Task { await AIPrompts.edit(ctx.window, preset: ctx.arg("text", as: String.self) ?? "") }
        }
        a.register("ai-status") { ctx in
            guard let w = ai(ctx) else { return }
            ctx.arg("reply", as: ((Any?) -> Void).self)?([
                "running": .number(Double(w.runningCount())), "waiting": .number(Double(w.waitingCount)),
                "shown": .bool(w.shown), "startup": AIOpen.startupName().map(JSON.string) ?? .null,
            ] as JSON)
        }
        // The items of the assistants menu, appended to another owner's menu
        // (args `menu` NSMenu); `row` true adds the AI row's own extras.
        a.register("ai-menu") { ctx in
            guard let w = ai(ctx), let menu = ctx.arg("menu", as: NSMenu.self) else { return }
            AIMenu.append(ctx.arg("row", as: Bool.self) == true ? AISidebarRow.menuItems(w) : AIOpen.menuItems(w), to: menu)
        }
        // The "AI assistant" row for the sidebar's Local group (reply: AnyView).
        a.register("ai-sidebar-row") { ctx in
            guard let win = ctx.window else { return }
            ctx.arg("reply", as: ((Any?) -> Void).self)?(AnyView(AISidebarRow(window: win, ai: win.feature(AIWindow.self))))
        }
        // The pane menu for any other pane: give what is selected (or on
        // screen) to the assistant, with where it came from.
        a.register("ai-pane-ask") { ctx in
            guard let w = ai(ctx), let win = w.window else { return }
            let s = win.feature(SessionsWindow.self)
            guard let pane = ctx.paneId.flatMap({ s.pane($0) }) ?? s.activePane, let v = pane.term else { return }
            let text = v.hasSelection ? v.selectionText : AIWaiting.screenTail(v.screenLines(), 60)
            let conn = pane.kind == .local ? nil : pane.connId.flatMap { ConnectionManager.shared.connection($0) }
            Task { await w.askAbout(text, source: conn.map { "my session on \($0.label)" } ?? "my local shell") }
        }

        // The assistant chosen to open every time, beside whatever was
        // restored — the first window only: a second is somewhere to work.
        after(2.0) {
            guard !CommandLine.arguments.contains("--snapshot"),
                  let w = WindowManager.shared.windows.first else { return }
            Task { await AIOpen.openAtStartup(w.feature(AIWindow.self)) }
        }
    }
}

/// The "AI assistant" row in the sidebar's Local group (sidebar.js
/// `localAiRows`), offered to the sidebar through `ai-sidebar-row`.
struct AISidebarRow: View {
    let window: WindowModel
    let ai: AIWindow
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let running = ai.runningCount()
        let waiting = ai.waitingCount
        let preferred = AIOpen.startupName()
        HStack(spacing: 7) {
            Circle().fill(waiting > 0 ? p.amber : running > 0 ? p.green : p.purple).frame(width: 7, height: 7)
            Text("AI assistant").font(.system(size: 12.5))
            Spacer(minLength: 4)
            // A question waiting outranks "running": it is the one that needs you.
            Text(waiting > 0 ? "\(waiting) question\(waiting == 1 ? "" : "s") waiting" : running > 0 ? "\(running) running" : (preferred ?? "AI"))
                .font(.system(size: 10.5))
                .foregroundStyle(waiting > 0 ? Color.black : p.muted)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(waiting > 0 ? p.amber : p.panel3).cornerRadius(3)
                .help(waiting > 0 ? "An assistant is asking you something — double-click to see it" : "")
        }
        .foregroundStyle(hover.on ? p.text : p.textDim)
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover.on ? p.panel2 : .clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help("AI assistants — Claude Code, Codex, Copilot, OpenCode, Pi, Gemini or one of your own — in the panel on the right")
        // A small prompt for a new session: which assistant, and what to ask
        // it. It answers at once — nothing starts until Open.
        .onTapGesture(count: 2) { Task { await AIDialogs.openAiPrompt(ai) } }
        .overlay(AIRightClick { AIMenu.build(AISidebarRow.menuItems(ai)) })
    }

    static func menuItems(_ w: AIWindow) -> [AIMenuItem] {
        var items = AIOpen.menuItems(w)
        items.append(.separator)
        if w.runningCount() > 0 {
            items.append(.item(w.shown ? "Hide the AI panel" : "Show the AI panel") { w.show(!w.shown) })
        }
        let clients = AIService.clients()
        let start = Store.shared.aiStartup
        items.append(.sub("Open at startup", [.item("None", key: start.isEmpty ? "✓" : "") { Store.shared.aiStartup = "" }]
            + clients.filter(\.available).map { c in
                .item(c.name, key: start == c.id ? "✓" : "") { Store.shared.aiStartup = c.id }
            }))
        items.append(.sub("Check that a tool is ready", clients.map { c in
            .item(c.name) { Task { await AIOpen.checkAi(w, c.id) } }
        }))
        return items
    }
}
