import AppKit
import SwiftUI

/// automation.js `type_text` and `read_output`: an assistant typing into a
/// session — asked of the person first, unless they have said not to ask —
/// and reading what a session shows. Reached through the `ai-type-request`
/// action (args `verb` "type_text"/"read_output", `params` JSON, `reply`
/// `(Result<JSON, Error>) -> Void`), or directly.
@MainActor
enum AITyping {
    static func lastLines(_ text: String, _ n: Int) -> String {
        var s = text
        while let l = s.last, l.isWhitespace { s.removeLast() }
        let lines = s.components(separatedBy: "\n")
        return lines.suffix(n).joined(separator: "\n")
    }

    struct Target { let tab: SessionTab; let tabIdx: Int; let pane: SessionPane; let paneIdx: Int }

    /// A pane by tab and pane index: the active tab and its focused pane by default.
    static func paneAt(_ s: SessionsWindow, tab: Int?, pane: Int?) throws -> Target {
        let tabIdx = tab ?? (s.tabs.firstIndex { $0.id == s.activeTabId } ?? -1)
        guard tabIdx >= 0, tabIdx < s.tabs.count else {
            throw AppError(tab != nil ? "No tab \(tab!)." : "No tab is open.")
        }
        let t = s.tabs[tabIdx]
        let ids = s.panesOf(t.id)
        let id: String? = pane != nil ? (pane! >= 0 && pane! < ids.count ? ids[pane!] : nil)
            : (s.activePaneId.map { ids.contains($0) } == true ? s.activePaneId : ids.first)
        guard let id, let p = s.pane(id) else { throw AppError("No pane \(pane.map(String.init) ?? "undefined") in tab \(tabIdx).") }
        return Target(tab: t, tabIdx: tabIdx, pane: p, paneIdx: ids.firstIndex(of: id) ?? 0)
    }

    static func int(_ j: JSON) -> Int? {
        guard case .number(let d) = j, d == d.rounded() else { return nil }
        return Int(d)
    }

    static func describe(_ p: SessionPane?) -> String {
        if let c = p?.connId.flatMap({ ConnectionManager.shared.connection($0) }), !c.label.isEmpty { return c.label }
        if p?.kind == .local { return "this machine" }
        return p?.title?.nilIfEmpty ?? "a session"
    }

    static func typeable(_ p: SessionPane) -> Bool { p.hasTerm && p.kind != .view }

    // MARK: type_text

    static func typeText(_ params: JSON, window w: WindowModel) async throws -> JSON {
        let mode = Store.shared.setting("automationTyping", "ask")
        if mode == "off" {
            throw AppError("Typing into sessions is turned off in ServerLife (Settings \u{2192} Local automation).")
        }
        let body = params["text"].stringish ?? ""
        if body.isEmpty { throw AppError("Nothing to type.") }
        let enter = params["enter"].truthy
        let s = w.feature(SessionsWindow.self)
        var target = try paneAt(s, tab: int(params["tab"]), pane: int(params["pane"]))
        if !typeable(target.pane) { throw AppError("That pane has no session to type into.") }
        let who = params["_client"].string?.nilIfEmpty.map { "The assistant (\($0))" } ?? "An assistant"

        var run = enter
        if mode != "allow" {
            // Two tabs can carry the same title — two sessions open on the same
            // node, say, which is exactly when the request's tab/pane numbers
            // are the only thing telling them apart. Those numbers are also a
            // request from a moment ago. So list what is actually open right
            // now, defaulted to the request's target, and let them look at each
            // one's screen before picking.
            var targets: [TypeModel.Option] = []
            for (ti, tb) in s.tabs.enumerated() {
                let ids = s.panesOf(tb.id)
                for (pi, id) in ids.enumerated() {
                    guard let pp = s.pane(id), typeable(pp) else { continue }
                    targets.append(.init(key: "\(ti):\(pi)", tabIdx: ti, paneIdx: pi,
                                         label: "Tab \(ti + 1) \u{201c}\(tb.title)\u{201d} \u{2014} \(describe(pp))" + (ids.count > 1 ? ", pane \(pi + 1)" : "")))
                }
            }
            let m = TypeModel(s: s, targets: targets, start: target)
            let answer: String? = await AISheet.ask(w, width: 640) { done in
                TypeView(m: m, who: who, text: body, enter: enter, done: done)
            }
            guard let answer else { throw AppError("The user declined to have this typed into the session.") }
            target = m.target
            if !typeable(target.pane) { throw AppError("That pane has no session to type into.") }
            run = answer == "run"
        }

        let multi = body.contains("\n")
        s.sendToPane(target.pane, multi ? "\u{1b}[200~\(body)\u{1b}[201~" : body)
        if run { s.sendToPane(target.pane, "\r") }
        return ["typed": .number(Double(body.utf16.count)), "ran": .bool(run),
                "into": ["tab": .number(Double(target.tabIdx)), "pane": .number(Double(target.paneIdx)),
                         "host": .string(describe(target.pane))]]
    }

    // MARK: read_output

    /// What a session shows, as text: the last `lines` lines of a pane.
    /// Read-only, and only what the terminal holds.
    static func readOutput(_ params: JSON, window w: WindowModel) throws -> JSON {
        let s = w.feature(SessionsWindow.self)
        let t = try paneAt(s, tab: int(params["tab"]), pane: int(params["pane"]))
        guard t.pane.kind != .view, let view = t.pane.term else { throw AppError("That pane is a screen, not text.") }
        var n = 80
        if case .number(let d) = params["lines"], d != 0, d.isFinite { n = Int(d) }
        n = max(1, min(1000, n))
        let conn = t.pane.connId.flatMap { ConnectionManager.shared.connection($0) }
        let text = lastLines(view.allText(), n)
        let host: JSON = conn.map { .string($0.label) } ?? (t.pane.kind == .local ? "local" : .null)
        return ["tab": ["index": .number(Double(t.tabIdx)), "title": .string(t.tab.title)],
                "pane": ["index": .number(Double(t.paneIdx)), "kind": .string(t.pane.kind.rawValue), "host": host],
                "lines": .number(Double(text.isEmpty ? 0 : text.components(separatedBy: "\n").count)),
                "text": .string(text)]
    }

    // MARK: The dialog

    @MainActor
    final class TypeModel: ObservableObject {
        struct Option: Identifiable { let key: String; let tabIdx: Int; let paneIdx: Int; let label: String; var id: String { key } }
        let s: SessionsWindow
        let targets: [Option]
        @Published var target: Target
        @Published var key: String { didSet { pick() } }
        @Published var preview = ""
        init(s: SessionsWindow, targets: [Option], start: Target) {
            self.s = s
            self.targets = targets
            target = start
            key = "\(start.tabIdx):\(start.paneIdx)"
            refresh()
        }
        func pick() {
            guard let o = targets.first(where: { $0.key == key }),
                  let t = try? AITyping.paneAt(s, tab: o.tabIdx, pane: o.paneIdx) else { return }
            target = t
            refresh()
        }
        func refresh() {
            let txt = AITyping.lastLines(target.pane.term?.allText() ?? "", 3)
            preview = txt.isEmpty ? "(nothing on screen yet)" : txt
        }
    }

    private struct TypeView: View {
        @ObservedObject var m: TypeModel
        let who: String
        let text: String
        let enter: Bool
        let done: (String?) -> Void
        var body: some View {
            let p = Theme.shared.p
            let select = m.targets.count > 1
            DialogScaffold(title: select ? "\(who) wants to type into a session" : "\(who) wants to type into \(AITyping.describe(m.target.pane))",
                           width: 640) {
                VStack(alignment: .leading, spacing: 4) {
                    if select {
                        AIField(label: "Where") {
                            Picker("", selection: $m.key) { ForEach(m.targets) { Text($0.label).tag($0.key) } }
                                .labelsHidden().frame(maxWidth: .infinity)
                        }
                    } else {
                        Text("Tab \(m.target.tabIdx + 1) \u{201c}\(m.target.tab.title)\u{201d}, pane \(m.target.paneIdx + 1):")
                            .font(.system(size: 11)).foregroundStyle(p.muted)
                    }
                    AIPre(text: m.preview, maxHeight: 70).opacity(0.75).padding(.bottom, 4)
                    if enter { Text("and to press Enter to run it:").font(.system(size: 11)).foregroundStyle(p.muted) }
                    AIPre(text: text, maxHeight: 300)
                    Text("Settings \u{2192} Local automation decides whether this is asked, allowed or refused.")
                        .font(.system(size: 11)).foregroundStyle(p.muted).padding(.top, 6)
                }
            } footer: {
                Button("Don\u{2019}t allow") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Paste only") { done("paste") }.buttonStyle(.ghost)
                if enter { Button("Paste and run") { done("run") }.buttonStyle(.primary) }
                else { Button("Paste") { done("paste") }.buttonStyle(.primary) }
            }
        }
    }
}
