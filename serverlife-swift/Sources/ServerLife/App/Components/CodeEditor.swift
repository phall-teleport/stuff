import AppKit
import SwiftUI

/*
 * The shared code editor — what the original builds from CodeMirror in
 * yamleditor.js, yamlview.js, sshconfigeditor.js and cmtheme.js — for
 * YAML (Kubernetes resources, phase.yaml, Phase add-ins, kubeconfig),
 * ssh_config, and plain text.
 *
 * Usage:
 *
 *   CodeEditor(text: $text, language: .yaml)                 // yamlview.js, editable
 *   CodeEditor(text: $text, language: .sshConfig,            // sshconfigeditor.js
 *              controller: ctl)                              //   ctl.insert("Host x\n  HostName y")
 *   CodeEditor(text: $text, language: .yaml, tabIndents: false,   // yamleditor.js (KubeLife)
 *              linter: { text in … [CodeDiagnostic] },            //   kube:validateYaml, 700 ms after typing
 *              completer: { text, pos, explicit in … })           //   kube:explainFields
 *   YamlView(text: s)                                        // read-only, keeps its scroll when s changes
 *
 * What it does, as CodeMirror's basicSetup did: line numbers (with the
 * active line's highlighted), the active line tinted, monospace 12 pt, undo,
 * the find bar (⌘F, ⌘G), indentation kept on Return (and one level more
 * after a YAML `key:` / `|` / `>`), no wrapping (it scrolls sideways).
 * `tabIndents` (yamlview.js / sshconfigeditor.js `indentWithTab`): Tab and
 * Shift-Tab indent and outdent the selected lines by two spaces; without it
 * Tab moves to the next control as in a form.
 *
 * Escape (0.34, ui.js modal()): "Escape in a code editor is the editor's (it
 * closes its own search box), not a way to lose what was typed." Escape with
 * focus in the editor or its find bar closes the find bar (or a completion
 * list) and never reaches the dialog's Cancel button.
 *
 * Offsets everywhere (diagnostics, completions, the cursor) are UTF-16, as
 * NSString and JavaScript count them, so ported `text.indexOf(…)` arithmetic
 * carries over unchanged when done on `text as NSString`.
 *
 * Colours are cmtheme.js's, from `Theme.shared.p`: keys accent, Host/Match and
 * directives purple semibold, values and quoted text green, `|`/`>` amber,
 * comments muted italic, anchors/tags purple, punctuation dim, an unknown
 * ssh option red and underlined; lint errors underlined red with the message
 * as the tooltip and a red mark in the gutter.
 */

/// A problem to point at — @codemirror/lint's `{from, to, severity, message}`.
struct CodeDiagnostic: Equatable, Sendable {
    var from: Int
    var to: Int
    var message: String
    var severity: Severity = .error
    enum Severity { case error, warning }
}

/// Suggestions for the word ending at the cursor — @codemirror/autocomplete's
/// `{from, options}`. `from` is where the word being completed starts.
struct CodeCompletions: Sendable {
    struct Item: Sendable { var label: String; var detail: String = "" }
    var from: Int
    var items: [Item]
}

/// A handle on one editor, for what a binding cannot say: insert at the
/// cursor, focus, the selection.
@MainActor
final class CodeEditorController: ObservableObject {
    fileprivate weak var textView: CodeTextView?

    var value: String { textView?.string ?? "" }

    /// sshconfigeditor.js `insert`: lines of their own — a newline before
    /// when the cursor is mid-line, one after — at the cursor, as an undoable edit.
    func insert(_ text: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
        let pad = sel.location > line.location && !before.trimmed.isEmpty ? "\n" : ""
        tv.replaceUndoably(sel, with: pad + text + "\n")
        focus()
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Replace everything (yamleditor.js `setValue`) — only when it differs.
    func setValue(_ v: String) {
        guard let tv = textView, tv.string != v else { return }
        tv.replaceUndoably(NSRange(location: 0, length: (tv.string as NSString).length), with: v)
    }

    var selectedRange: NSRange {
        get { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }
        set { textView?.setSelectedRange(newValue); textView?.scrollRangeToVisible(newValue) }
    }
}

struct CodeEditor: View {
    @Binding var text: String
    var language: CodeLanguage = .yaml
    var readOnly = false
    var tabIndents = true
    var fontSize: CGFloat = 12
    var controller: CodeEditorController? = nil
    /// Run 700 ms after the last edit (and once at the start), off the main
    /// actor's way; its answer underlines the text. yamleditor.js's linter.
    var linter: (@Sendable (String) async -> [CodeDiagnostic])? = nil
    /// Asked while a word is typed (`explicit` false) and on ⌃Space or ⌥Esc
    /// (`explicit` true): `(text, cursor, explicit)`.
    var completer: (@Sendable (String, Int, Bool) async -> CodeCompletions?)? = nil
    /// Hears every edit (yamlview.js `onChange`), after the binding is set.
    var onChange: ((String) -> Void)? = nil

    var body: some View {
        let p = Theme.shared.p
        CodeEditorRepresentable(text: $text, language: language, readOnly: readOnly, tabIndents: tabIndents,
                                fontSize: fontSize, palette: p, controller: controller, linter: linter,
                                completer: completer, onChange: onChange)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// yamlview.js with `readOnly`: a colour-coded view whose text is set from
/// outside, and which keeps its scroll position while the text is the same.
struct YamlView: View {
    var text: String
    var language: CodeLanguage = .yaml
    var body: some View {
        CodeEditor(text: .constant(text), language: language, readOnly: true)
    }
}

// MARK: - AppKit side

private struct CodeEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var readOnly: Bool
    var tabIndents: Bool
    var fontSize: CGFloat
    var palette: Palette
    var controller: CodeEditorController?
    var linter: (@Sendable (String) async -> [CodeDiagnostic])?
    var completer: (@Sendable (String, Int, Bool) async -> CodeCompletions?)?
    var onChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let tv = CodeTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        let ruler = CodeLineRuler(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        tv.ruler = ruler

        context.coordinator.textView = tv
        context.coordinator.parent = self
        tv.string = text
        configure(tv, scroll, context.coordinator, initial: true)
        controller?.textView = tv
        CodeEditorEscape.installOnce()
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView, queue: .main) { [weak ruler] _ in
            MainActor.assumeIsolated { ruler?.needsDisplay = true }
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scheduleLint(delay: 0)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        controller?.textView = tv
        // Only when it differs, so a view refreshed on every check keeps its scroll.
        if tv.string != text && !tv.hasMarkedText() {
            let sel = tv.selectedRange()
            tv.string = text
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            context.coordinator.scheduleLint(delay: 0)
        }
        configure(tv, scroll, context.coordinator, initial: false)
    }

    private func configure(_ tv: CodeTextView, _ scroll: NSScrollView, _ coord: Coordinator, initial: Bool) {
        let p = palette
        let changed = initial || tv.palette != p || tv.language != language || tv.fontSize != fontSize
        tv.isEditable = !readOnly
        tv.isSelectable = true
        tv.tabIndents = tabIndents
        tv.language = language
        tv.wantsCompletion = completer != nil
        guard changed else { return }
        tv.palette = p
        tv.fontSize = fontSize
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.font = font
        tv.backgroundColor = NSColor(p.panel2)
        scroll.backgroundColor = NSColor(p.panel2)
        tv.textColor = NSColor(p.text)
        tv.insertionPointColor = NSColor(p.text)
        tv.selectedTextAttributes = [.backgroundColor: NSColor(p.accent).withAlphaComponent(0.32)]
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor(p.text)]
        tv.ruler?.needsDisplay = true
        coord.rehighlight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorRepresentable!
        weak var textView: CodeTextView?
        var diagnostics: [CodeDiagnostic] = []
        private var lintTask: Task<Void, Never>?
        private var completeTask: Task<Void, Never>?

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let s = tv.string
            if parent.text != s { parent.text = s }
            parent.onChange?(s)
            rehighlight()
            tv.ruler?.needsDisplay = true
            scheduleLint(delay: 0.7)
            if !tv.inCompletion && tv.lastInputWasWordChar { requestCompletion(explicit: false) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.needsDisplay = true
            textView?.ruler?.needsDisplay = true
        }

        func rehighlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            tv.applyHighlight(storage, diagnostics: diagnostics)
        }

        func scheduleLint(delay: Double) {
            lintTask?.cancel()
            guard let linter = parent?.linter, let tv = textView, !parent.readOnly else {
                if !diagnostics.isEmpty { diagnostics = []; rehighlight() }
                return
            }
            let text = tv.string
            lintTask = Task { @MainActor [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled else { return }
                let found = await linter(text)
                guard !Task.isCancelled, let self, self.textView?.string == text else { return }
                self.diagnostics = found
                self.rehighlight()
                self.textView?.ruler?.needsDisplay = true
            }
        }

        func requestCompletion(explicit: Bool) {
            completeTask?.cancel()
            guard let completer = parent?.completer, let tv = textView, tv.isEditable else { return }
            let text = tv.string
            let pos = tv.selectedRange().location
            completeTask = Task { @MainActor [weak self] in
                guard let r = await completer(text, pos, explicit), !Task.isCancelled, !r.items.isEmpty,
                      let tv = self?.textView, tv.string == text, tv.selectedRange().location == pos else { return }
                tv.pendingCompletions = r
                tv.complete(nil)
            }
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let tv = textView as? CodeTextView, let r = tv.pendingCompletions else { return [] }
            let typed = (tv.string as NSString).substring(with: charRange)
            var seen = Set<String>()
            return r.items.map(\.label).filter { $0.hasPrefix(typed) && $0 != typed && seen.insert($0).inserted }
        }
    }
}

/// Escape belongs to the editor (see the header): a local monitor sees it
/// before the dialog's `.cancelAction` button can.
@MainActor
private enum CodeEditorEscape {
    static var installed = false
    static func installOnce() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let responder = event.window?.firstResponder as? NSView else { return event }
            var v: NSView? = responder
            var scroll: NSScrollView?
            while let x = v {
                if let s = x as? NSScrollView, s.documentView is CodeTextView { scroll = s; break }
                v = x.superview
            }
            guard let scroll, let tv = scroll.documentView as? CodeTextView else { return event }
            if tv.inCompletion { return event }
            if scroll.isFindBarVisible {
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.hideFindInterface.rawValue
                tv.performTextFinderAction(item)
                tv.window?.makeFirstResponder(tv)
            }
            return nil
        }
    }
}

fileprivate final class CodeTextView: NSTextView {
    var palette: Palette?
    var language: CodeLanguage = .text
    var fontSize: CGFloat = 12
    var tabIndents = true
    var wantsCompletion = false
    weak var ruler: CodeLineRuler?
    var pendingCompletions: CodeCompletions?
    var inCompletion = false
    var lastInputWasWordChar = false
    /// Line start offsets, for the gutter.
    private(set) var lineStarts: [Int] = [0]
    private(set) var diagnosticLines: Set<Int> = []

    // MARK: colouring

    func applyHighlight(_ storage: NSTextStorage, diagnostics: [CodeDiagnostic]) {
        guard let p = palette else { return }
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        recomputeLines(ns)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor(p.text)], range: full)
        for span in CodeSyntax.spans(string, language) where NSMaxRange(span.range) <= full.length {
            var a: [NSAttributedString.Key: Any] = [:]
            switch span.token {
            case .key: a[.foregroundColor] = NSColor(p.accent)
            case .keyword: a[.foregroundColor] = NSColor(p.purple); a[.font] = bold
            case .string: a[.foregroundColor] = NSColor(p.green)
            case .special: a[.foregroundColor] = NSColor(p.amber)
            case .comment: a[.foregroundColor] = NSColor(p.muted); a[.font] = italic
            case .label: a[.foregroundColor] = NSColor(p.purple)
            case .punctuation: a[.foregroundColor] = NSColor(p.textDim)
            case .meta: a[.foregroundColor] = NSColor(p.muted)
            case .invalid:
                a[.foregroundColor] = NSColor(p.red)
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                a[.underlineColor] = NSColor(p.red)
            }
            storage.addAttributes(a, range: span.range)
        }
        var lines = Set<Int>()
        for d in diagnostics {
            let from = max(0, min(d.from, full.length))
            var to = max(from, min(d.to, full.length))
            if to == from && to < full.length { to += 1 }
            let r = NSRange(location: from, length: to - from)
            let colour = NSColor(d.severity == .error ? p.red : p.amber)
            if r.length > 0 {
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: colour,
                    .toolTip: d.message,
                ], range: r)
            }
            lines.insert(lineIndex(of: from))
        }
        storage.endEditing()
        diagnosticLines = lines
        typingAttributes = [.font: font, .foregroundColor: NSColor(p.text)]
    }

    private func recomputeLines(_ ns: NSString) {
        var starts = [0]
        let len = ns.length
        var i = 0
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: max(len, 1))
        defer { buf.deallocate() }
        ns.getCharacters(buf, range: NSRange(location: 0, length: len))
        while i < len {
            if buf[i] == 10 { starts.append(i + 1) }
            i += 1
        }
        lineStarts = starts
    }

    /// 0-based line of a UTF-16 offset.
    func lineIndex(of offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: drawing — the active line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let p = palette, let lm = layoutManager, let tc = textContainer else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        var r: NSRect
        if line.location >= ns.length && (ns.length == 0 || ns.character(at: ns.length - 1) == 10) {
            r = lm.extraLineFragmentRect
            if r.isEmpty && ns.length == 0 { r = NSRect(x: 0, y: 0, width: bounds.width, height: fontSize * 1.25) }
        } else {
            let g = lm.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
            r = lm.boundingRect(forGlyphRange: g, in: tc)
        }
        r.origin.x = 0
        r.size.width = bounds.width
        r.origin.y += textContainerOrigin.y
        NSColor(p.accent).withAlphaComponent(0.07).setFill()
        r.fill()
    }

    // MARK: editing

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        ruler?.needsDisplay = true
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        lastInputWasWordChar = wantsCompletion && s.count == 1
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
        super.insertText(string, replacementRange: replacementRange)
        lastInputWasWordChar = false
    }

    override func keyDown(with event: NSEvent) {
        // ⌃Space: ask for completions now (startCompletion).
        if wantsCompletion, event.keyCode == 49, event.modifierFlags.contains(.control) {
            (delegate as? CodeEditorRepresentable.Coordinator)?.requestCompletion(explicit: true)
            return
        }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) {
        // ⌥Esc / F5 from the system: the editor's own completer, or nothing —
        // never the dictionary's words.
        if pendingCompletions == nil || sender != nil {
            if wantsCompletion { (delegate as? CodeEditorRepresentable.Coordinator)?.requestCompletion(explicit: true) }
            return
        }
        super.complete(sender)
    }

    override var rangeForUserCompletion: NSRange {
        guard let r = pendingCompletions else { return super.rangeForUserCompletion }
        let pos = selectedRange().location
        return r.from <= pos ? NSRange(location: r.from, length: pos - r.from) : super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        inCompletion = !flag
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag { pendingCompletions = nil }
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape is never "complete" here (NSTextView's default) — see
        // CodeEditorEscape — except to dismiss a completion list.
        if inCompletion { super.cancelOperation(sender) }
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable else { return }
        let ns = string as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
        var indent = String(head.prefix { $0 == " " || $0 == "\t" })
        if language == .yaml {
            let t = head.trimmingCharacters(in: .whitespaces)
            let noComment = t.range(of: " #").map { String(t[..<$0.lowerBound]) } ?? t
            let trimmedEnd = noComment.trimmingCharacters(in: .whitespaces)
            if trimmedEnd.hasSuffix(":") {
                // `- name:` — the mapping's keys line up after the dash.
                indent += trimmedEnd.hasPrefix("- ") ? "    " : "  "
            } else if trimmedEnd == "-"
                        || trimmedEnd.range(of: #"(^|[:\s])[|>][-+1-9]*$"#, options: .regularExpression) != nil {
                indent += "  "
            }
        }
        replaceUndoably(sel, with: "\n" + indent)
    }

    override func insertTab(_ sender: Any?) {
        guard tabIndents else { window?.selectNextKeyView(sender); return }
        guard isEditable else { return }
        shiftLines(by: 2)
    }

    override func insertBacktab(_ sender: Any?) {
        guard tabIndents else { window?.selectPreviousKeyView(sender); return }
        guard isEditable else { return }
        shiftLines(by: -2)
    }

    /// indentMore / indentLess: every line the selection touches.
    private func shiftLines(by n: Int) {
        let ns = string as NSString
        let sel = selectedRange()
        let lines = ns.lineRange(for: sel)
        let block = ns.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let trailing = block.hasSuffix("\n")
        if trailing { parts.removeLast() }
        var firstDelta = 0, total = 0
        for (i, p) in parts.enumerated() {
            var q = p
            if n > 0 {
                if !(p.isEmpty && parts.count > 1) { q = String(repeating: " ", count: n) + p }
            } else {
                let lead = p.prefix { $0 == " " }.count
                let tabs = lead == 0 && p.hasPrefix("\t") ? 1 : 0
                q = String(p.dropFirst(tabs > 0 ? 1 : min(lead, -n)))
            }
            let d = (q as NSString).length - (p as NSString).length
            if i == 0 { firstDelta = d }
            total += d
            parts[i] = q
        }
        let out = parts.joined(separator: "\n") + (trailing ? "\n" : "")
        replaceUndoably(lines, with: out)
        let start = max(lines.location, sel.location + firstDelta)
        let length = sel.length == 0 ? 0 : max(0, sel.length + total - firstDelta)
        setSelectedRange(NSRange(location: start, length: length))
    }

    /// An edit that undo knows about, and that the delegate hears.
    func replaceUndoably(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }
}

/// The gutter: line numbers, the active line's brighter, a red mark on a line
/// with a lint error.
fileprivate final class CodeLineRuler: NSRulerView {
    weak var tv: CodeTextView?

    init(textView: CodeTextView, scrollView: NSScrollView) {
        tv = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 32
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv, let p = tv.palette, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor(p.panel).setFill()
        bounds.fill()
        NSColor(p.border).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, tv.fontSize - 1), weight: .regular)
        let digits = max(2, String(tv.lineStarts.count).count)
        let want = CGFloat(digits) * font.maximumAdvancement.width + 16
        if abs(want - ruleThickness) > 0.5 { ruleThickness = want; return }

        let ns = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = tv.lineIndex(of: tv.selectedRange().location)
        var line = tv.lineIndex(of: chars.location)
        let originY = convert(NSPoint(x: 0, y: tv.textContainerOrigin.y), from: tv).y

        func draw(_ n: Int, _ fragment: NSRect) {
            let y = originY + fragment.minY
            let active = n == caretLine
            if active {
                NSColor(p.accent).withAlphaComponent(0.12).setFill()
                NSRect(x: 0, y: y, width: bounds.width - 1, height: fragment.height).fill()
            }
            if tv.diagnosticLines.contains(n) {
                NSColor(p.red).setFill()
                NSBezierPath(ovalIn: NSRect(x: 3, y: y + fragment.height / 2 - 3, width: 6, height: 6)).fill()
            }
            let s = NSAttributedString(string: "\(n + 1)", attributes: [
                .font: font, .foregroundColor: NSColor(active ? p.textDim : p.muted),
            ])
            let size = s.size()
            s.draw(at: NSPoint(x: bounds.width - 6 - size.width, y: y + (fragment.height - size.height) / 2))
        }

        while line < tv.lineStarts.count {
            let start = tv.lineStarts[line]
            if start > NSMaxRange(chars) { break }
            if start >= ns.length {
                // The empty last line after a final newline, or an empty document.
                let r = lm.extraLineFragmentRect
                if !r.isEmpty { draw(line, r) } else if ns.length == 0 {
                    draw(line, NSRect(x: 0, y: 0, width: 0, height: (lm.defaultLineHeight(for: tv.font ?? font))))
                }
                break
            }
            let g = lm.glyphIndexForCharacter(at: start)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            draw(line, frag)
            line += 1
        }
    }
}
