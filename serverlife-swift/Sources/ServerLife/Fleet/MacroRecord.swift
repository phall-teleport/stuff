import AppKit
import SwiftUI
import SwiftTerm

/**
 * Record a macro: work in a session as usual, and what you ran becomes one
 * (macrorecord.js).
 *
 * Keystrokes are the wrong thing to keep — Tab completion, the history, the
 * arrow keys and backspace would all be replayed as keys, against a shell in
 * a different state. What is kept is each command as it stood when Enter was
 * pressed, read off the screen from where its typing began: what Tab filled
 * in and what the Up arrow brought back are on the screen, so they are in the
 * command. A line still being typed when recording stops is read the same way
 * and offered as the last step, marked as not run.
 *
 * Not recorded: anything typed into a full-screen program (vim, less, top —
 * the alternate screen), a line abandoned with Ctrl+C, and what is typed at a
 * prompt that does not echo — a password is not on the screen to be read. A
 * line that looks as though it carries a secret is recorded but left unticked
 * in the review.
 *
 * Stopping shows the steps to keep, edit, reorder or drop, and then the
 * ordinary macro editor, already filled in.
 *
 * Port notes: Sessions has no input-observer hook, so recording wraps the
 * terminal's `onInput` (the wrapper passes everything on, and records only
 * while its own recording is the pane's). SwiftTerm does not expose a line's
 * wrapped flag, so a line counts as continuing the one before when that one
 * is filled to its last column.
 */
@MainActor
@Observable
final class MacroRecord {
    static let shared = MacroRecord()

    struct Point { var x: Int; var y: Int }
    final class Recorder {
        let token = UUID()
        var steps: [String] = []
        var start: Point?
        var since: Double = nowMs()
    }

    /// Recordings by pane id; observed, so the header badge redraws.
    private(set) var recorders: [String: Recorder] = [:]
    /// Bumped when a recording's step count changes.
    var revision = 0

    static func recorder(_ pane: SessionPane) -> Recorder? { shared.recorders[pane.id] }
    static func isRecording(_ pane: SessionPane) -> Bool { recorder(pane) != nil }

    static func install() {
        PaneHeaderItems.shared.register("fleet-macro-record", slot: .macroPins) { pane in
            guard shared.recorders[pane.id] != nil else { return nil }
            return AnyView(RecordBadge(paneId: pane.id))
        }
        SessionHooks.paneClosing.append { pane in shared.recorders[pane.id] = nil }
    }

    // MARK: Pure parts

    struct ScreenLine { var text: String; var wrapped: Bool }

    /**
     * The command in a run of screen lines: from column `startX` of the first
     * to the end of the last, a wrapped line joined to the one before it and
     * an unwrapped one (a shell's continuation, `> `) on a line of its own.
     */
    nonisolated static func commandFromLines(_ lines: [ScreenLine], startX: Int = 0) -> String {
        var out = ""
        for (i, l) in lines.enumerated() {
            if i == 0 {
                out = String(l.text.dropFirst(max(0, startX)))
            } else if l.wrapped {
                out += l.text
            } else {
                out += "\n" + l.text.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            }
        }
        out = out.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        // Accepted from bash's reverse search before the shell redrew the line.
        if let re = try? NSRegularExpression(pattern: #"^\((?:reverse|bck)-i-search\)`[^']*':\s?(.*)$"#,
                                             options: [.dotMatchesLineSeparators]),
           let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
           let r = Range(m.range(at: 1), in: out) {
            out = String(out[r])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A command that looks as though a secret is written into it.
    nonisolated static func looksSecret(_ cmd: String) -> Bool {
        let pattern = #"(pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key)\s*[=:]\s*\S|--pass(word)?[= ]\S|(^|\s)-p[^\s-]\S{3,}|authorization:\s*\S"#
        return cmd.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The kept steps as one macro command, each on its own line.
    nonisolated static func macroCommand(_ steps: [String], stopOnFail: Bool = false) -> String {
        let lines = steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // `a &&` at the end of a line carries on to the next, so the first
        // failure stops the rest — written out, so it can be read and changed.
        return lines.joined(separator: stopOnFail ? " &&\n" : "\n")
    }

    // MARK: Reading the screen

    /// The cursor as a position in the whole buffer (scrollback included).
    private static func cursor(_ t: Terminal) -> Point {
        let c = t.getCursorLocation()
        return Point(x: c.x, y: t.buffer.yDisp + c.y)
    }

    /// The colour a cell is drawn in, to tell typed text from a suggestion.
    private static func ink(_ c: CharData?) -> String {
        guard let c else { return "" }
        return "\(c.attribute.fg):\(c.attribute.style.contains(.dim))"
    }

    private static func lineText(_ t: Terminal, _ line: BufferLine, upTo end: Int? = nil) -> String {
        let n = min(end ?? line.count, line.count)
        var s = ""
        for x in 0..<n {
            if line.getWidth(index: x) == 0 { continue }
            let ch = t.getCharacter(for: line[x])
            s.append(ch == "\u{0}" ? " " : ch)
        }
        return end == nil ? s.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) : s
    }

    /**
     * The line being typed, from where its typing began to the cursor — and
     * past the cursor only while the text is drawn the way the typed text is.
     * Grey text after the cursor is zsh's or fish's suggestion, and text far
     * to the right in another colour is a right-hand prompt; neither was run.
     */
    private static func readCommand(_ t: Terminal, _ start: Point) -> String {
        let cur = cursor(t)
        let endY = cur.y
        if endY < start.y || endY - start.y > 40 { return "" }
        let top = t.buffer.yDisp
        var lines: [ScreenLine] = []
        var prevFull = false
        for y in start.y...endY {
            guard let line = t.getLine(row: y - top) else { break }
            var text = lineText(t, line)
            if y == endY {
                let ref = ink(cur.x > 0 && cur.x - 1 < line.count ? line[cur.x - 1] : (line.count > 0 ? line[0] : nil))
                var end = cur.x
                var x = cur.x
                while x < line.count {
                    let c = line[x]
                    let ch = t.getCharacter(for: c)
                    if ch != "\u{0}" && ch != " " && ink(c) != ref { break }
                    end = x + 1
                    x += 1
                }
                text = lineText(t, line, upTo: end)
            }
            lines.append(ScreenLine(text: text, wrapped: y > start.y && prevFull))
            let last = line.count > 0 ? line[line.count - 1] : nil
            prevFull = last.map { let ch = t.getCharacter(for: $0); return ch != "\u{0}" && ch != " " } ?? false
        }
        return commandFromLines(lines, startX: start.x)
    }

    // MARK: Recording

    /// Start recording in a pane.
    static func start(_ pane: SessionPane) {
        guard pane.hasTerm, let term = pane.term else {
            StatusBus.shared.toast("Open a session to record in", kind: .error); return
        }
        if pane.kind == .view || pane.kind == .device {
            StatusBus.shared.toast("Recording is for shell sessions", kind: .error); return
        }
        guard shared.recorders[pane.id] == nil else { return }
        let r = Recorder()
        begin(pane, term, r)
        StatusBus.shared.show("Recording \u{2014} run the commands for the macro, then press \u{25CF} Stop in the pane\u{2019}s header",
                              kind: .info, seconds: 8)
        term.window?.makeFirstResponder(term)
    }

    private static func begin(_ pane: SessionPane, _ term: SessionTermView, _ r: Recorder) {
        shared.recorders[pane.id] = r
        shared.revision += 1
        let token = r.token, id = pane.id
        let next = term.onInput
        // Called before the keys are sent, so the cursor is still where the shell left it.
        term.onInput = { [weak term] d in
            if let term, let rec = MacroRecord.shared.recorders[id], rec.token == token {
                MacroRecord.recordInput(rec, term.getTerminal(), d)
            }
            next?(d)
        }
    }

    /// What was typed into a recording pane.
    private static func recordInput(_ r: Recorder, _ t: Terminal, _ data: Data) {
        // A full-screen program: its keys are not commands.
        if t.isCurrentBufferAlternate { r.start = nil; return }
        let s = String(decoding: data, as: UTF8.self)

        /*
         * A bracketed paste lands in the shell's line as text and runs at the
         * next Enter, where it is read off the screen with the rest. A paste
         * without brackets runs line by line as it arrives, so its lines are
         * the commands.
         */
        if s.hasPrefix("\u{1b}[200~") {
            if r.start == nil { r.start = cursor(t) }
            return
        }
        if s.unicodeScalars.count > 1, s.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }), !s.hasPrefix("\u{1b}") {
            let before = r.start.map { readCommand(t, $0) } ?? ""
            var parts = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            let last = parts.removeLast()
            if !parts.isEmpty { parts[0] = before + parts[0] }
            for p in parts { add(r, p) }
            r.start = last.isEmpty ? nil : cursor(t)
            return
        }
        if s == "\r" || s == "\n" {
            if let st = r.start { add(r, readCommand(t, st)) }
            r.start = nil
            return
        }
        // Ctrl+C or Ctrl+U: the line is abandoned.
        if s == "\u{03}" || s == "\u{15}" { r.start = nil; return }
        // Ctrl+D on an empty line ends the shell; nothing to record.
        if s == "\u{04}" { return }
        // The first key of a new line marks where its command starts.
        if r.start == nil { r.start = cursor(t) }
    }

    private static func add(_ r: Recorder, _ cmd: String) {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        r.steps.append(c)
        shared.revision += 1
    }

    struct Step: Identifiable {
        let id = UUID()
        var cmd: String
        var keep: Bool
        var typed = false
    }

    /// Stop, review the steps, and hand them to the macro editor.
    static func stop(_ pane: SessionPane, window: WindowModel?) async {
        guard let r = shared.recorders[pane.id] else { return }
        // A line typed but not yet run with Enter is the last step, marked as such.
        var typed = ""
        if let st = r.start, let term = pane.term {
            let t = term.getTerminal()
            if !t.isCurrentBufferAlternate { typed = readCommand(t, st) }
        }
        shared.recorders[pane.id] = nil
        shared.revision += 1
        if r.steps.isEmpty && typed.isEmpty {
            StatusBus.shared.show("Recording stopped \u{2014} nothing was run"); return
        }
        var steps = r.steps.map { Step(cmd: $0, keep: !looksSecret($0)) }
        if !typed.isEmpty { steps.append(Step(cmd: typed, keep: !looksSecret(typed), typed: true)) }

        let w = window ?? WindowManager.shared.focused
        let res: ReviewResult? = await FleetDialog.ask(w, title: "Recorded", width: 720) { done in
            ReviewForm(initial: steps, done: done)
        }
        guard let res else { StatusBus.shared.show("Recording discarded"); return }
        if res.choice == "more" {
            // The typed line is still on the command line: it is read again at Enter.
            guard let term = pane.term, pane.hasTerm else { return }
            let again = Recorder()
            again.steps = res.steps.filter { $0.keep && !$0.typed }.map(\.cmd)
            again.start = r.start
            again.since = r.since
            begin(pane, term, again)
            return
        }
        guard res.choice == "next" else { StatusBus.shared.show("Recording discarded"); return }

        let kept = res.steps.filter { $0.keep && !$0.cmd.trimmed.isEmpty }.map(\.cmd)
        if kept.isEmpty { StatusBus.shared.show("No steps kept \u{2014} nothing saved"); return }
        let whereScope = ["local": "local", "beam": "beams"][Macros.paneKind(pane)] ?? "hosts"
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        let label = pane.kind == .local ? "the local shell"
            : (pane.connId.flatMap { ConnectionManager.shared.connection($0)?.label }?.nilIfEmpty ?? pane.title?.nilIfEmpty ?? "a session")
        var m = MacroDialogs.newMacro(command: macroCommand(kept, stopOnFail: res.stopOnFail), name: "",
                                      category: "Recorded", where: whereScope)
        m.description = "Recorded on \(label), \(df.string(from: Date(timeIntervalSince1970: r.since / 1000)))"
        if let saved = await MacroDialogs.edit(m, window: w) {
            StatusBus.shared.show("Saved \(saved["name"].stringish ?? "macro") \u{2014} in the \u{25B6} menu")
        }
    }

    struct ReviewResult { var choice: String; var steps: [Step]; var stopOnFail: Bool }

    private struct ReviewForm: View {
        let done: (ReviewResult?) -> Void
        @StateObject private var steps: Local<[Step]>
        @StateObject private var stopOnFail = LocalFlag(true)

        init(initial: [Step], done: @escaping (ReviewResult?) -> Void) {
            self.done = done
            _steps = StateObject(wrappedValue: Local(initial))
        }

        private func move(_ i: Int, _ d: Int) {
            let j = i + d
            guard j >= 0, j < steps.value.count else { return }
            steps.value.swapAt(i, j)
        }

        var body: some View {
            let p = Theme.shared.p
            let n = steps.value.count
            DialogScaffold(title: "Recorded \(n) step\(n == 1 ? "" : "s")") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Untick a step to leave it out; edit one in place. Next, name the macro and choose where it runs.")
                        .font(.system(size: 12)).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                    ForEach(Array(steps.value.enumerated()), id: \.element.id) { i, s in
                        let secret = MacroRecord.looksSecret(s.cmd)
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(get: { steps.value[safe: i]?.keep ?? false },
                                                     set: { if i < steps.value.count { steps.value[i].keep = $0 } }))
                                .labelsHidden().toggleStyle(.checkbox)
                            Text(String(i + 1)).font(.system(size: 11)).foregroundStyle(p.muted).frame(width: 18, alignment: .trailing)
                            FleetField(placeholder: "", text: Binding(get: { steps.value[safe: i]?.cmd ?? "" },
                                                                      set: { if i < steps.value.count { steps.value[i].cmd = $0 } }),
                                       mono: true)
                            Button("\u{2191}") { move(i, -1) }.buttonStyle(.ghost).help("Earlier")
                            Button("\u{2193}") { move(i, 1) }.buttonStyle(.ghost).help("Later")
                            if s.typed {
                                Text("typed, not run").font(.system(size: 10.5)).foregroundStyle(p.muted)
                                    .help("On the command line when recording stopped \u{2014} Enter had not been pressed")
                            }
                            if secret {
                                Text("looks like a secret").font(.system(size: 10.5)).foregroundStyle(p.amber)
                                    .help("Left out unless you tick it \u{2014} a macro is saved as plain text")
                            }
                        }
                    }
                    Toggle("Stop at the first step that fails", isOn: $stopOnFail.on)
                        .toggleStyle(.checkbox).font(.system(size: 12)).padding(.top, 6)
                }
            } footer: {
                Button("Discard") { done(ResultFor("discard")) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Keep recording") { done(ResultFor("more")) }.buttonStyle(.ghost)
                Button("Next") { done(ResultFor("next")) }.buttonStyle(.primary)
            }
        }

        private func ResultFor(_ choice: String) -> ReviewResult {
            ReviewResult(choice: choice, steps: steps.value, stopOnFail: stopOnFail.on)
        }
    }

    /// The ● in the pane's header: how many steps so far, and Stop.
    private struct RecordBadge: View {
        let paneId: String
        var body: some View {
            let p = Theme.shared.p
            let rs = MacroRecord.shared
            let n = rs.revision >= 0 ? (rs.recorders[paneId]?.steps.count ?? 0) : 0
            Button {
                guard let s = SessionsCore.owner(ofPane: paneId), let pane = s.pane(paneId) else { return }
                Task { @MainActor in await MacroRecord.stop(pane, window: s.window) }
            } label: {
                Text("\u{25CF} Stop recording \u{00B7} \(n) step\(n == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(p.red)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(p.red.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .help("Recording a macro \u{2014} click to stop and review what was recorded")
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
