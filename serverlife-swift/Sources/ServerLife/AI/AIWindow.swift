import AppKit
import SwiftUI

/// One assistant in the panel: the client's own CLI in a terminal.
@MainActor
@Observable
final class AISession: Identifiable {
    let id = uid("ai")
    let client: AIClients.Client
    var title: String
    /// Two of the same assistant are told apart by number — "Claude Code 2".
    let n: Int
    @ObservationIgnored let view: SessionTermView
    /// The program behind it, while it runs (the original's `termId`).
    var backend: PTYBackend?
    /// A question is on its screen (see AIWaiting).
    var waiting = false
    @ObservationIgnored var pendingPrompt: String?
    @ObservationIgnored var pendingSend = true
    @ObservationIgnored let startedAt = Date()
    @ObservationIgnored var lastTail: String?
    @ObservationIgnored var stillSince: Date?

    init(client: AIClients.Client, title: String, n: Int) {
        self.client = client
        self.title = title
        self.n = n
        self.view = SessionTermView()
    }

    var running: Bool { backend != nil }
    var chipTitle: String { waiting ? "\(title) — has a question waiting for you" : "\(title) — \(client.vendor)" }

    func send(_ text: String) { backend?.write(Data(text.utf8)) }
    func focus() { view.window?.makeFirstResponder(view) }
}

/// The assistants of one window (ai.js's module state — one renderer, one
/// window): the sessions in the panel, the one on show, and whether the
/// panel is out.
///
/// The assistants live in a panel on the right of the window — beside every
/// tab, not inside one — so a conversation stays where it is while the tabs
/// change under it, as VS Code's secondary side bar does. Hiding the panel
/// leaves them running.
@MainActor
@Observable
final class AIWindow: WindowFeature {
    @ObservationIgnored weak var window: WindowModel?
    var sessions: [AISession] = []
    var activeId: String?
    var shown = false
    var width: CGFloat
    @ObservationIgnored private let watcher = Repeater()
    @ObservationIgnored private var watching = false

    init(window: WindowModel) {
        self.window = window
        let w = Store.shared.aiPanelWidthSetting ?? 460
        width = CGFloat(max(280, min(1200, w > 0 ? w : 460)))
    }

    var active: AISession? { sessions.first { $0.id == activeId } }
    var waitingCount: Int { sessions.filter(\.waiting).count }
    func runningCount(_ id: String? = nil) -> Int { id.map { i in sessions.filter { $0.client.id == i }.count } ?? sessions.count }
    func isRunning(_ id: String) -> Bool { sessions.contains { $0.client.id == id } }

    // MARK: Showing

    func show(_ on: Bool) {
        shown = on
        if on { after(0.05) { [weak self] in self?.active?.focus() } }
    }

    /// The toolbar's ✦: show or hide what is there, or — with nothing open
    /// yet — offer the assistants, starting with the one chosen in Settings.
    func toggle() {
        if !sessions.isEmpty { show(!shown); return }
        let start = Store.shared.aiStartup
        if !start.isEmpty { Task { await AIOpen.openAi(self, start) }; return }
        AIMenu.show(AIOpen.menuItems(self))
    }

    /// Show the panel on a running assistant of this kind.
    func showSession(_ id: String) {
        guard let rec = sessions.first(where: { $0.client.id == id }) else { Task { await AIOpen.openAi(self, id) }; return }
        show(true)
        select(rec)
    }

    func select(_ rec: AISession) {
        activeId = rec.id
        after(0.05) { rec.focus() }
    }

    func close(_ rec: AISession) {
        guard let i = sessions.firstIndex(where: { $0 === rec }) else { return }
        sessions.remove(at: i)
        rec.backend?.onExit = nil
        rec.backend?.close()
        rec.backend = nil
        rec.view.removeFromSuperview()
        rec.view.dispose()
        if activeId == rec.id { activeId = nil }
        if !sessions.isEmpty { select(sessions[max(0, i - 1)]) } else { show(false) }
    }

    // MARK: Adding

    /// A running assistant in the panel, named for its client.
    func add(_ c: AIClients.Client, _ l: AILaunch, prompt: String = "", send: Bool = true, name given: String = "") throws {
        // The lowest free number, so closing the second and opening another
        // gives a second again rather than a third.
        let used = Set(sessions.filter { $0.client.id == c.id }.map(\.n))
        var n = 1
        while used.contains(n) { n += 1 }
        let g = given.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = !g.isEmpty ? g : (n > 1 ? "\(l.title) \(n)" : l.title)
        let rec = AISession(client: c, title: name, n: n)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        rec.pendingPrompt = p.isEmpty ? nil : p
        rec.pendingSend = send

        let t = rec.view.getTerminal()
        let proc = try PTYProcess(exe: l.command, args: l.args, env: l.env.mapValues { Optional($0) },
                                  cwd: l.cwd.isEmpty ? nil : l.cwd, cols: max(t.cols, 40), rows: max(t.rows, 10))
        let backend = PTYBackend(proc, kind: "command")
        rec.backend = backend
        rec.view.onInput = { [weak rec] d in rec?.backend?.write(d) }
        rec.view.onResize = { [weak rec] cols, rows in rec?.backend?.resize(cols: cols, rows: rows) }
        rec.view.onFocus = { [weak self] in self?.focusFollows = false }
        rec.view.menuProvider = { [weak self, weak rec] _ in
            guard let self, let rec else { return nil }
            return AIMenu.build(self.chipMenu(rec, forTerminal: true))
        }
        backend.onData = { [weak rec] d in rec?.view.write(d) }
        backend.onExit = { [weak rec] code, reason in
            guard let rec else { return }
            rec.backend = nil
            rec.waiting = false
            let why = reason.map { " — \($0)" } ?? ((code ?? 0) != 0 ? " — exit \(code!)" : "")
            rec.view.writeln("\r\n\u{1b}[90m[session ended\(why) — \(Fmt.dateTimeTz(ms: nowMs()))]\u{1b}[0m")
        }
        sessions.append(rec)
        watchQuestions()
        show(true)
        select(rec)
    }

    /// Set while focus-follows-mouse has moved focus, so a click is not needed.
    @ObservationIgnored var focusFollows = false

    // MARK: Prompts

    /// Type a message into an assistant and send it.
    func sendPrompt(_ r: AISession, _ text: String, send: Bool = true) {
        // One paste, so a message of several lines arrives as one message.
        r.send(text.contains("\n") ? "\u{1b}[200~\(text)\u{1b}[201~" : text)
        if send {
            after(0.2) { r.send("\r") }
            StatusBus.shared.show("Asked \(r.title)")
        } else {
            // Left in its input for a question to be added before it goes.
            StatusBus.shared.show("Put into \(r.title) — add your question and press Enter", seconds: 6)
            r.focus()
        }
    }

    /// Give an assistant something: the one on show, else a new one (the one
    /// that opens at startup, else the first installed). `send` false leaves
    /// it in the assistant's input, for a question to be added to it.
    func askAi(_ text: String, send: Bool = false) async {
        if let rec = active ?? sessions.last {
            show(true)
            select(rec)
            sendPrompt(rec, text, send: send)
            return
        }
        let clients = AIService.clients()
        let start = Store.shared.aiStartup
        let id = (!start.isEmpty ? clients.first { $0.id == start && $0.available }?.id : nil) ?? clients.first { $0.available }?.id
        guard let id else { AIMenu.show(AIOpen.menuItems(self)); return }
        await AIOpen.openAi(self, id, fromStartup: true, prompt: text, send: send)
    }

    /// Ask about something on screen or in the host list: the text with where
    /// it came from, put into the assistant's input — not sent — so the
    /// question goes with it.
    func askAbout(_ text: String, source: String) async {
        let body = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { StatusBus.shared.show("Nothing to ask about"); return }
        await askAi("From \(source):\n```\n\(body)\n```\n", send: false)
    }

    // MARK: Watching for questions

    /// A question waiting, shown in yellow: on the assistant's chip, on the
    /// AI row in the host list — so one asking for permission behind another
    /// chip, or with the panel hidden, is not left waiting unseen. A screen
    /// counts as asking once it has held still for a moment and its last
    /// lines are a question (see AIWaiting). Answering moves it on.
    func watchQuestions() {
        guard !watching else { return }
        watching = true
        watcher.start(every: 0.7) { [weak self] in self?.tick() }
    }

    private func tick() {
        if sessions.isEmpty { watcher.stop(); watching = false; return }
        let now = Date()
        for r in sessions {
            let tail = AIWaiting.screenTail(r.view.screenLines(), 24)
            if tail != r.lastTail { r.lastTail = tail; r.stillSince = now }
            let still = now.timeIntervalSince(r.stillSince ?? now)
            let asking = AIWaiting.looksLikeQuestion(tail)
            let waiting = r.running && still >= 0.9 && asking
            // A first message goes in once the assistant has settled at its
            // prompt — not while it is starting, and not into a question it
            // asks first (a folder to trust, a sign-in), which is left for
            // the person to answer. Given up on after two minutes.
            if let text = r.pendingPrompt, r.running {
                if still >= 1.5, !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !asking {
                    r.pendingPrompt = nil
                    sendPrompt(r, text, send: r.pendingSend)
                } else if now.timeIntervalSince(r.startedAt) > 120 {
                    r.pendingPrompt = nil
                    StatusBus.shared.toast("\(r.title) did not become ready — type your question into it", kind: .error)
                }
            }
            if waiting != r.waiting { r.waiting = waiting }
        }
    }

    // MARK: Names

    /// Name an assistant's chip — "prod upgrade" rather than "Claude Code 2".
    func rename(_ rec: AISession) async {
        guard let v = await Modal.prompt(window, title: "Rename", message: "Name", value: rec.title, ok: "Rename"),
              !v.isEmpty else { return }
        rec.title = v
    }

    // MARK: Menus

    /// The chip's right-click menu (and the terminal's).
    func chipMenu(_ rec: AISession, forTerminal: Bool = false) -> [AIMenuItem] {
        var items: [AIMenuItem] = []
        if forTerminal {
            // An assistant's own pane saves what it said (sessions.js's pane menu).
            let hasSel = rec.view.hasSelection
            items.append(.item("Copy", enabled: hasSel) { Clipboard.write(rec.view.selectionText) })
            items.append(.item("Paste") { [weak self] in self?.paste(rec, Clipboard.read()) })
            items.append(.separator)
            items.append(.item("Save the selection as a response…", icon: "↓", enabled: hasSel) { [weak self] in
                Task { await self?.saveResponse(rec, rec.view.selectionText) } })
            items.append(.item("Saved responses…", icon: "☰") { [weak self] in AIDialogs.savedResponses(self) })
            items.append(.separator)
            items.append(.item("Rename…") { [weak self] in Task { await self?.rename(rec) } })
        } else {
            items.append(.item("Rename…") { [weak self] in Task { await self?.rename(rec) } })
            items += saveMenuItems(rec)
        }
        items.append(.separator)
        items.append(.item("Close \(rec.title)", icon: "✕") { [weak self] in self?.close(rec) })
        return items
    }

    /// The ways to save from an assistant's pane.
    func saveMenuItems(_ rec: AISession?) -> [AIMenuItem] {
        guard let rec else { return [.item("No assistant open", enabled: false) {}] }
        let hasSel = rec.view.hasSelection
        let rows = rec.view.getTerminal().rows
        return [
            .item("Save the selection…", icon: "↓", title: hasSel ? nil : "Select the response in the assistant first",
                  enabled: hasSel) { [weak self] in Task { await self?.saveResponse(rec, rec.view.selectionText) } },
            .item("Save what is on screen…", icon: "↓") { [weak self] in
                Task { await self?.saveResponse(rec, AIWaiting.screenTail(rec.view.screenLines(), rows > 0 ? rows : 40)) } },
            .item("Save the whole conversation…", icon: "↓") { [weak self] in
                Task { await self?.saveResponse(rec, rec.view.allText()) } },
            .separator,
            .item("Saved responses…", icon: "☰") { [weak self] in AIDialogs.savedResponses(self) },
        ]
    }

    /// Keep a response: named, and saved as Markdown in the assistants' folder.
    func saveResponse(_ rec: AISession?, _ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { StatusBus.shared.show("Nothing to save"); return }
        let title = await Modal.prompt(window, title: "Save a response", message: "Name",
                                       value: String(AIWindow.responseName(body).prefix(60)), ok: "Save")
        guard let title else { return }
        do {
            let r = try AIService.saveResponse(title: title, text: body, source: rec?.title ?? "")
            StatusBus.shared.toast("Saved — \(r.file)", kind: .ok)
        } catch { StatusBus.shared.toast(error.localizedDescription, kind: .error) }
    }

    /// A name to start from: the assistant's last answer (the line its marker
    /// starts — ⏺ or ●), else the first line that is words rather than a
    /// logo or a rule.
    nonisolated static func responseName(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        let answer = lines.reversed().first { $0.range(of: #"^\s*[⏺●•]\s+\S"#, options: .regularExpression) != nil }
        let wordy = lines.first { l in
            let letters = l.unicodeScalars.filter { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }.count
            return Double(letters) > Double(l.trimmingCharacters(in: .whitespaces).count) / 2
        }
        return (answer ?? wordy ?? "").replacingOccurrences(of: #"^[\s●⏺>❯•*\-]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The menu of saved prompts, each sent to the assistant on show.
    func promptMenuItems() -> [AIMenuItem] {
        let list = AIPrompts.list()
        var items: [AIMenuItem] = [.heading("Saved prompts")]
        if list.isEmpty { items.append(.item("None saved yet", enabled: false) {}) }
        for x in list {
            items.append(.item(x.name, title: x.text) { [weak self] in Task { await self?.askAi(x.text, send: true) } })
        }
        items.append(.separator)
        items.append(.item("Save a prompt…", icon: "+") { [weak self] in Task { await AIPrompts.edit(self?.window) } })
        if !list.isEmpty {
            items.append(.sub("Edit or remove", list.enumerated().map { i, x in
                .item(x.name) { [weak self] in Task { await AIPrompts.edit(self?.window, index: i) } }
            }))
        }
        return items
    }

    /// Paste as one bracketed paste when there are several lines.
    func paste(_ rec: AISession, _ text: String) {
        guard !text.isEmpty else { return }
        rec.send(text.contains("\n") ? "\u{1b}[200~\(text)\u{1b}[201~" : text)
    }

    /// Send a key to the assistant on show (the key bar and ⏎ Enter).
    func sendKey(_ seq: String, none: String = "No assistant running to send keys to") {
        guard let r = active, r.running else { StatusBus.shared.show(none); return }
        r.send(seq)
        r.focus()
    }
}

/// Saved prompts: questions asked often enough to keep. Until the person
/// saves their own, a few that use what ServerLife gives every assistant are
/// offered.
@MainActor
enum AIPrompts {
    struct Prompt: Equatable { var name: String; var text: String }

    static let starters = [
        Prompt(name: "What am I connected to?", text: "List my open ServerLife sessions and say in a line each what host, cluster and user each one is."),
        Prompt(name: "Explain the last output", text: "Read the output of my active ServerLife session and explain what it shows. Point out anything that looks wrong."),
        Prompt(name: "Disk and memory on my sessions", text: "For each of my open ServerLife sessions, tell me how to check disk and memory use, and what you would look at first."),
    ]

    static func list() -> [Prompt] {
        guard let raw = Store.shared.aiPromptsSetting else { return starters }
        return raw.map { Prompt(name: $0["name"].string ?? "", text: $0["text"].string ?? "") }
    }

    static func save(_ list: [Prompt]) {
        Store.shared.updateSettings(["aiPrompts": .array(list.map { .object(["name": .string($0.name), "text": .string($0.text)]) })])
    }

    /// Add a saved prompt, or change or remove one (by its place in the list).
    static func edit(_ owner: WindowModel?, index: Int? = nil, preset: String = "") async {
        var list = list()
        let cur = index.flatMap { list.indices.contains($0) ? list[$0] : nil } ?? Prompt(name: "", text: preset)
        guard let res = await AIDialogs.editPrompt(owner, isNew: index == nil, current: cur) else { return }
        switch res {
        case .remove:
            if let index, list.indices.contains(index) { list.remove(at: index) }
        case .save(let name, let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { StatusBus.shared.toast("The prompt is empty", kind: .error); return }
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = Prompt(name: n.isEmpty ? String((t.components(separatedBy: "\n").first ?? "").prefix(50)) : n, text: t)
            if let index, list.indices.contains(index) { list[index] = entry } else { list.append(entry) }
        }
        save(list)
        if case .remove = res { StatusBus.shared.show("Prompt removed") } else { StatusBus.shared.show("Prompt saved") }
    }
}
