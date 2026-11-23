import AppKit
import SwiftUI

// MARK: - Small pieces the AI dialogs share

/// A labelled field with an optional hint under it (ui.js `field`).
struct AIField<Content: View>: View {
    let label: String?
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text) }
            content()
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
    }
}

/// Monospaced text in a box (`pre.qc-debug`).
struct AIPre: View {
    let text: String
    var maxHeight: CGFloat? = nil
    var body: some View {
        let p = Theme.shared.p
        ScrollView {
            Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: maxHeight == nil)
        .background(p.panel2).overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
    }
}

/// A sheet that answers: `done(value)` closes it with that value; closing it
/// any other way (Escape) answers nil.
@MainActor
enum AISheet {
    final class Box<T> { var resumed = false }

    static func ask<T, V: View>(_ owner: WindowModel?, title: String = "", width: CGFloat,
                                @ViewBuilder content: @escaping (@escaping (T?) -> Void) -> V) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let box = Box<T>()
            var handle: ModalHandle?
            let finish: (T?) -> Void = { v in
                guard !box.resumed else { return }
                box.resumed = true
                handle?.close()
                cont.resume(returning: v)
            }
            handle = Modal.sheet(owner, title: title, width: width) { _ in content(finish) }
            handle?.onClose.append { finish(nil) }
        }
    }
}

/// The dialogs of ai.js.
@MainActor
enum AIDialogs {
    // MARK: The check

    enum CheckResult { case open, cancel, again, fix(AICheckStep.Fix) }

    static func check(_ owner: WindowModel?, _ c: AIClients.Client, _ chk: AICheck) async -> CheckResult {
        let blocking = chk.steps.contains { $0.level == "error" }
        let warned = chk.steps.contains { $0.level == "warn" }
        let r: CheckResult? = await AISheet.ask(owner, width: 620) { done in
            DialogScaffold(title: "\(c.name) — \(blocking ? "not ready yet" : "ready, with notes")", width: 620) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(chk.steps) { st in CheckRow(step: st) { done(.fix($0)) } }
                }
            } footer: {
                Button("Cancel") { done(.cancel) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Check again") { done(.again) }.buttonStyle(.ghost)
                if !blocking { Button(warned ? "Open anyway" : "Open") { done(.open) }.buttonStyle(.primary) }
            }
        }
        return r ?? .cancel
    }

    private struct CheckRow: View {
        let step: AICheckStep
        let fix: (AICheckStep.Fix) -> Void
        var body: some View {
            let p = Theme.shared.p
            let mark = ["ok": "✓", "error": "✕", "warn": "!", "info": "i"][step.level] ?? "·"
            let color = ["ok": p.green, "error": p.red, "warn": p.amber, "info": p.accent][step.level] ?? p.textDim
            HStack(alignment: .top, spacing: 8) {
                Text(mark).font(.system(size: 12, weight: .bold)).foregroundStyle(color).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.label).font(.system(size: 12.5, weight: .medium))
                    if let d = step.detail { Text(d).font(.system(size: 11.5)).foregroundStyle(p.textDim).fixedSize(horizontal: false, vertical: true) }
                    if let cmd = step.fix?.command {
                        Text(cmd).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(p.panel2).cornerRadius(3)
                    }
                }
                Spacer(minLength: 4)
                if let f = step.fix {
                    ForEach(Array(([f] + f.alt).enumerated()), id: \.offset) { _, x in
                        Button(x.label.isEmpty ? "Fix" : x.label) { fix(x) }.buttonStyle(.ghostSmall)
                    }
                }
            }
        }
    }

    // MARK: Registration (Pi, Gemini CLI)

    static func register(_ owner: WindowModel?, _ c: AIClients.Client, _ cmd: String) async -> Bool {
        let r: Bool? = await AISheet.ask(owner, width: 600) { done in
            DialogScaffold(title: "Add ServerLife to \(c.name)?", width: 600) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(c.name) reads MCP servers only from its own settings, so ServerLife has to be added there once:")
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    AIPre(text: cmd)
                }
            } footer: {
                Button("Open without ServerLife") { done(false) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Add it") { done(true) }.buttonStyle(.primary)
            }
        }
        return r ?? false
    }

    // MARK: How it runs

    @MainActor
    final class HowModel: ObservableObject {
        let id: String
        @Published var mode: String { didSet { sync() } }
        @Published var template: String { didSet { sync() } }
        @Published var model: String { didSet { sync() } }
        @Published var extra: String { didSet { sync() } }
        @Published var preview = ""
        @Published var recipe = ""
        private let debounce = Debouncer(0.15)

        init(id: String) {
            self.id = id
            let m = AIService.launchMode(id)
            mode = m == "direct" ? "direct" : m.hasPrefix("custom:") ? "custom" : "default"
            template = m.hasPrefix("custom:") ? String(m.dropFirst(7)) : ""
            model = Store.shared.aiMap("aiClientModel")[id]?.string ?? ""
            extra = Store.shared.aiMap("aiClientArgs")[id]?.string ?? ""
            refresh()
        }

        var draft: AIService.Draft {
            .init(mode: mode, template: template.trimmingCharacters(in: .whitespaces),
                  model: model.trimmingCharacters(in: .whitespaces), extraArgs: extra.trimmingCharacters(in: .whitespaces))
        }

        func sync() { debounce.call { [weak self] in self?.refresh() } }

        func refresh() {
            do {
                let pv = try AIService.preview(id, draft)
                preview = pv.command
                recipe = pv.recipe.map { "ServerLife adds: \($0)" } ?? ""
            } catch { preview = error.localizedDescription; recipe = "" }
        }

        func save() -> Bool {
            let d = draft
            if d.mode == "custom", d.template.isEmpty {
                StatusBus.shared.toast("Give the launcher command, or choose another option", kind: .error)
                return false
            }
            func put(_ key: String, _ v: String) -> JSON {
                var m = Store.shared.aiMap(key)
                m[id] = .string(v)
                return .object(m)
            }
            Store.shared.updateSettings([
                "aiClientLaunch": put("aiClientLaunch", d.mode == "custom" ? "custom:\(d.template)" : d.mode),
                "aiClientModel": put("aiClientModel", d.model),
                "aiClientArgs": put("aiClientArgs", d.extraArgs),
            ])
            return true
        }
    }

    private struct HowView: View {
        let c: AIClients.Client
        @ObservedObject var m: HowModel
        let done: (String?) -> Void
        var body: some View {
            let p = Theme.shared.p
            let g = AIOpen.launcherSetting()
            let gOn = g?["on"].bool == true ? (g?["template"].string ?? "") : ""
            DialogScaffold(title: "How \(c.name) runs", width: 640) {
                VStack(alignment: .leading, spacing: 6) {
                    radio("direct", "Directly", "\(c.name) signs in with \(c.vendor == "open source" ? "its providers" : c.vendor)")
                    radio("default", "The default launcher", gOn.isEmpty ? "none is set, so it runs directly — Settings → AI assistant" : gOn)
                    radio("custom", "Its own launcher", "a command it is run through")
                        .padding(.bottom, 6)
                    if m.mode == "custom" {
                        AIField(label: "Launcher command",
                                hint: "{client} becomes its name (\(c.id)); {command} its whole command line; with neither, the command goes after it.") {
                            TextField("mytool {client}", text: $m.template).textFieldStyle(.roundedBorder)
                        }
                    }
                    AIField(label: "Model") {
                        TextField(c.modelFlag.map { "passed as \($0) — e.g. anthropic/claude-sonnet-5" } ?? "this tool has no model flag",
                                  text: $m.model).textFieldStyle(.roundedBorder).disabled(c.modelFlag == nil)
                    }
                    AIField(label: "Extra arguments") {
                        TextField("added to its command line", text: $m.extra).textFieldStyle(.roundedBorder)
                    }
                    Text("What will run").font(.system(size: 11)).foregroundStyle(p.muted).padding(.top, 8)
                    AIPre(text: m.preview, maxHeight: 160)
                    if !m.recipe.isEmpty { Text(m.recipe).font(.system(size: 11)).foregroundStyle(p.accent).padding(.top, 6) }
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Save and check") { if m.save() { done("check") } }.buttonStyle(.ghost)
                Button("Save") { if m.save() { done("saved") } }.buttonStyle(.primary)
            }
        }

        func radio(_ value: String, _ label: String, _ sub: String) -> some View {
            let p = Theme.shared.p
            return Button { m.mode = value } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: m.mode == value ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(m.mode == value ? p.accent : p.textDim)
                    (Text(label).bold() + Text(" — " + sub).foregroundColor(p.muted)).font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// How one assistant runs, in one place: directly, through the default
    /// launcher, or through its own (typed by the person, never suggested),
    /// its model, and extra arguments. The command that will run is shown as
    /// it is edited, with anything ServerLife adds for the launcher
    /// explained, and it can be checked before it is saved.
    static func howItRuns(_ w: AIWindow, _ id: String) async {
        guard let c = AIService.clients().first(where: { $0.id == id })?.client else { return }
        let m = HowModel(id: id)
        let res: String? = await AISheet.ask(w.window, width: 640) { done in HowView(c: c, m: m, done: done) }
        if res == "saved" { StatusBus.shared.show("\(c.name): saved") }
        if res == "check" { await AIOpen.checkAi(w, c.id) }
    }

    // MARK: A custom tool

    struct CustomTool { var name = ""; var command = ""; var mcpFlag = ""; var install = "" }

    @MainActor
    final class ToolModel: ObservableObject {
        @Published var t: CustomTool
        init(_ t: CustomTool) { self.t = t }
    }

    private struct ToolView: View {
        let editing: String?
        @ObservedObject var m: ToolModel
        let done: (CustomTool?) -> Void
        var body: some View {
            DialogScaffold(title: editing.map { "Edit \($0)" } ?? "Add a custom AI tool", width: 560) {
                VStack(alignment: .leading, spacing: 2) {
                    AIField(label: "Name") { TextField("Aider", text: $m.t.name).textFieldStyle(.roundedBorder) }
                    AIField(label: "Command", hint: "What you would type to start it. The first word is what is looked for on your PATH.") {
                        TextField("aider --no-auto-commits", text: $m.t.command).textFieldStyle(.roundedBorder)
                    }
                    AIField(label: "MCP config flag",
                            hint: "If the tool takes MCP servers as {\"mcpServers\": {...}} JSON after a flag, name the flag and it gets ServerLife’s tools.") {
                        TextField("--mcp-config (leave empty if it has none)", text: $m.t.mcpFlag).textFieldStyle(.roundedBorder)
                    }
                    AIField(label: "Install command", hint: "Offered by the check when the tool is not found.") {
                        TextField("pipx install aider-chat (optional)", text: $m.t.install).textFieldStyle(.roundedBorder)
                    }
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save") { done(m.t) }.buttonStyle(.primary)
            }
        }
    }

    static func customTool(_ owner: WindowModel?, existing: JSON?) async -> CustomTool? {
        let m = ToolModel(CustomTool(name: existing?["name"].string ?? "", command: existing?["command"].string ?? "",
                                     mcpFlag: existing?["mcpFlag"].string ?? "", install: existing?["install"].string ?? ""))
        return await AISheet.ask(owner, width: 560) { done in ToolView(editing: existing?["name"].string, m: m, done: done) }
    }

    // MARK: Saved prompts

    enum PromptResult { case save(name: String, text: String), remove }

    @MainActor
    final class PromptModel: ObservableObject {
        @Published var name: String
        @Published var text: String
        init(_ p: AIPrompts.Prompt) { name = p.name; text = p.text }
    }

    private struct PromptView: View {
        let isNew: Bool
        @ObservedObject var m: PromptModel
        let done: (PromptResult?) -> Void
        var body: some View {
            DialogScaffold(title: isNew ? "Save a prompt" : "Edit a prompt", width: 560) {
                VStack(alignment: .leading, spacing: 2) {
                    AIField(label: "Name") { TextField("Check the logs", text: $m.name).textFieldStyle(.roundedBorder) }
                    AIField(label: "Prompt") { AITextArea(text: $m.text, placeholder: "What to ask", lines: 5) }
                }
            } footer: {
                if !isNew { Button("Remove") { done(.remove) }.buttonStyle(.ghost) }
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Save") { done(.save(name: m.name, text: m.text)) }.buttonStyle(.primary)
            }
        }
    }

    static func editPrompt(_ owner: WindowModel?, isNew: Bool, current: AIPrompts.Prompt) async -> PromptResult? {
        let m = PromptModel(current)
        return await AISheet.ask(owner, width: 560) { done in PromptView(isNew: isNew, m: m, done: done) }
    }

    // MARK: New AI session (double-click on the AI row)

    struct NewSession { var id: String; var prompt: String; var resume: String; var name: String }
    enum NewResult { case open(NewSession), show }

    @MainActor
    final class NewModel: ObservableObject {
        let avail: [AIClientInfo]
        @Published var pick: String { didSet { fit() } }
        @Published var start = ""
        @Published var name = ""
        @Published var ask = ""
        init(avail: [AIClientInfo], preferred: String) {
            self.avail = avail
            pick = avail.contains { $0.id == preferred } ? preferred : avail[0].id
        }
        var client: AIClients.Client? { avail.first { $0.id == pick }?.client }
        var starts: [(String, String)] {
            var o = [("", "A new conversation")]
            if client?.resume?.last != nil { o.append(("last", "The last conversation, where it left off")) }
            if client?.resume?.pick != nil { o.append(("pick", "A past conversation — choose from its list")) }
            return o
        }
        func fit() { if !starts.contains(where: { $0.0 == start }) { start = "" } }
    }

    private struct NewView: View {
        @ObservedObject var m: NewModel
        let counts: [String: Int]
        let canShow: Bool
        let done: (NewResult?) -> Void
        var body: some View {
            let prompts = AIPrompts.list()
            DialogScaffold(title: "New AI session", width: 560) {
                VStack(alignment: .leading, spacing: 2) {
                    AIField(label: "Assistant") {
                        Picker("", selection: $m.pick) {
                            ForEach(m.avail) { c in
                                let n = counts[c.id] ?? 0
                                Text(c.name + (n > 0 ? " (\(n) running — a new one)" : "")).tag(c.id)
                            }
                        }.labelsHidden()
                    }
                    AIField(label: "Start with") {
                        Picker("", selection: $m.start) {
                            ForEach(m.starts, id: \.0) { Text($0.1).tag($0.0) }
                        }.labelsHidden().disabled(m.starts.count < 2)
                    }
                    AIField(label: "Name") {
                        TextField(m.client?.nameFlag != nil ? "prod upgrade — leave empty for the assistant’s name" : "prod upgrade — the tab’s name",
                                  text: $m.name).textFieldStyle(.roundedBorder)
                    }
                    AIField(label: "Ask it", hint: "Sent once it is ready. Enter sends; Shift+Enter for a new line.") {
                        AITextArea(text: $m.ask, placeholder: "What should it do? Leave empty to just open it.", lines: 4,
                                   focusFirst: true, onEnter: { open() })
                    }
                    if !prompts.isEmpty {
                        Menu("Saved prompts…") {
                            ForEach(Array(prompts.enumerated()), id: \.offset) { _, x in Button(x.name) { m.ask = x.text } }
                        }.fixedSize()
                    }
                }
            } footer: {
                if canShow { Button("Show the panel") { done(.show) }.buttonStyle(.ghost) }
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Open") { open() }.buttonStyle(.primary)
            }
        }
        func open() {
            done(.open(NewSession(id: m.pick, prompt: m.ask, resume: m.start, name: m.name.trimmingCharacters(in: .whitespaces))))
        }
    }

    /// Double-click on the AI assistant row: a new session, with a first
    /// message if one is typed. Which assistant is chosen here — the one
    /// being looked at, else the one that opens at startup, else the first
    /// installed — and the message is sent once it has started (or after it
    /// has asked, and been answered, anything of its own first).
    static func openAiPrompt(_ w: AIWindow) async {
        let avail = AIService.clients().filter(\.available)
        if avail.isEmpty { AIMenu.show(AIOpen.menuItems(w)); return }
        let start = Store.shared.aiStartup
        let preferred = w.active?.client.id ?? (start.isEmpty ? avail[0].id : start)
        let m = NewModel(avail: avail, preferred: preferred)
        var counts: [String: Int] = [:]
        for c in avail { counts[c.id] = w.runningCount(c.id) }
        let res: NewResult? = await AISheet.ask(w.window, width: 560) { done in
            NewView(m: m, counts: counts, canShow: !w.sessions.isEmpty, done: done)
        }
        guard let res else { return }
        switch res {
        case .show: w.show(true)
        case .open(let s):
            let running = w.runningCount(s.id) > 0
            await AIOpen.openAi(w, s.id, fromStartup: running, skipCheck: running, prompt: s.prompt, resume: s.resume, name: s.name)
        }
    }

    // MARK: Saved responses

    /// What has been saved: read, copy, give back to an assistant, or remove.
    static func savedResponses(_ w: AIWindow?) {
        let m = SavedModel(w)
        Modal.sheet(w?.window, title: "Saved responses", width: 860, height: 560, resizable: true, autosave: "ai-saved") { handle in
            SavedView(m: m) { handle.close() }
        }
    }

    @MainActor
    final class SavedModel: ObservableObject {
        weak var w: AIWindow?
        @Published var list: [AISavedResponse]
        @Published var current: AISavedResponse?
        @Published var text: String
        init(_ w: AIWindow?) {
            self.w = w
            let l = AIService.savedList()
            list = l
            text = l.isEmpty ? "Nothing saved yet. Use ↓ Save in the AI panel, or right-click an assistant." : "Choose one to read it."
        }
        func show(_ it: AISavedResponse) {
            current = it
            do { text = try AIService.savedRead(it.file) } catch { text = error.localizedDescription }
        }
        func delete() {
            guard let c = current else { return }
            do { try AIService.savedDelete(c.file) } catch { StatusBus.shared.toast(error.localizedDescription, kind: .error) }
            list.removeAll { $0.file == c.file }
            text = "Deleted."
            current = nil
        }
    }

    private struct SavedView: View {
        @ObservedObject var m: SavedModel
        let close: () -> Void
        var body: some View {
            let p = Theme.shared.p
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(m.list) { it in
                                Button { m.show(it) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(it.title).font(.system(size: 12.5)).lineLimit(2)
                                        Text(Date(timeIntervalSince1970: it.mtime / 1000).formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 10.5)).foregroundStyle(p.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                    .background(m.current?.file == it.file ? p.accentDim : Color.clear).cornerRadius(4)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(8)
                    }
                    .frame(width: 260)
                    p.border.frame(width: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        if let c = m.current {
                            HStack(spacing: 6) {
                                Button("Copy") { Clipboard.write(m.text); StatusBus.shared.show("Copied") }.buttonStyle(.ghostSmall)
                                Button("Give to the assistant") {
                                    let w = m.w
                                    Task { await w?.askAbout(m.text, source: "my saved response \"\(c.title)\"") }
                                }.buttonStyle(.ghostSmall).help("Put it into the assistant’s input, to ask about it")
                                Button("Show in Finder") { AIService.savedReveal(c.file) }.buttonStyle(.ghostSmall)
                                Button("Delete") { m.delete() }.buttonStyle(GhostButtonStyle(small: true, destructive: true))
                            }
                        }
                        ScrollView {
                            Text(m.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                p.border.frame(height: 1)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Open the folder") { AIService.savedReveal() }.buttonStyle(.ghost)
                    Button("Close") { close() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(p.panel)
        }
    }
}

// MARK: - A text area with Enter-to-send

/// A multi-line field. With `onEnter`, Enter sends and Shift+Enter is a new
/// line — as in the assistants.
struct AITextArea: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var lines = 4
    var focusFirst = false
    var onEnter: (() -> Void)? = nil

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AITextArea
        init(_ p: AITextArea) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            (tv as? AIPlaceholderTextView)?.needsDisplay = true
        }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard let onEnter = parent.onEnter, sel == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSEvent.modifierFlags.contains(.shift) { tv.insertNewlineIgnoringFieldEditor(nil); return true }
            if tv.hasMarkedText() { return false }
            onEnter()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        let tv = AIPlaceholderTextView()
        tv.placeholder = placeholder
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 12.5)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.delegate = context.coordinator
        tv.string = text
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 3, height: 4)
        sv.documentView = tv
        if focusFirst {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { tv.window?.makeFirstResponder(tv) }
        }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = sv.documentView as? NSTextView, tv.string != text { tv.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: CGFloat(lines) * 17 + 10)
    }
}

final class AIPlaceholderTextView: NSTextView {
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.placeholderTextColor, .font: font ?? .systemFont(ofSize: 12.5)]
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attrs)
    }
}
