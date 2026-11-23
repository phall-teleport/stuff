import Foundation

/// Is an assistant waiting on the person? (aiwaiting.js)
///
/// Each assistant draws its questions in its own terminal — a permission
/// prompt, a menu of choices, a yes/no — and while one is on screen nothing
/// moves until it is answered. These are the shapes those questions take in
/// the assistants ServerLife opens: Claude Code's "Do you want to …?" with a
/// numbered list under ❯, Codex's "Allow command?", Gemini's "Apply this
/// change?", "(y/n)" and "Press Enter" anywhere. It is the bottom of the
/// screen that is read, and only once it has stopped changing, so output
/// that merely mentions one of these in passing is not taken for a question.
enum AIWaiting {
    private static let patterns: [NSRegularExpression] = {
        let ci: NSRegularExpression.Options = [.caseInsensitive]
        let list: [(String, NSRegularExpression.Options)] = [
            (#"\bDo you want to\b"#, ci),
            (#"\bWould you like\b"#, ci),
            (#"\bDo you trust\b"#, ci),
            (#"\b(Allow|Approve|Permit|Proceed|Continue)\b[^\n]{0,100}\?"#, ci),
            (#"\b(Enter|Return) to (confirm|select|continue|approve)\b"#, ci),
            (#"\bEsc to cancel\b"#, ci),
            (#"\((y/n|yes/no)\)|\[(y/n|Y/n|y/N)\]"#, []),
            (#"\bPress (any key|Enter)\b"#, ci),
            // A numbered list with the cursor on one of its choices: ❯ 1. Yes
            (#"^\s*[❯›▶➜>]\s*\d+[.)]\s+\S"#, [.anchorsMatchLines]),
            (#"\bdon[’']t ask again\b"#, ci),
        ]
        return list.compactMap { try? NSRegularExpression(pattern: $0.0, options: $0.1) }
    }()

    /// Whether the text — the last lines of a screen — is asking something.
    static func looksLikeQuestion(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        let r = NSRange(location: 0, length: (text as NSString).length)
        return patterns.contains { $0.firstMatch(in: text, range: r) != nil }
    }

    /// The last `n` lines with anything above them, from a list of screen rows
    /// (top to bottom): up from the last line with anything on it, since a
    /// tall pane is mostly blank below a short screen.
    static func screenTail(_ rows: [String], _ n: Int = 24) -> String {
        var end = rows.count - 1
        while end > 0, rows[end].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        guard end >= 0 else { return "" }
        return rows[max(0, end - n + 1)...end].joined(separator: "\n")
    }
}
