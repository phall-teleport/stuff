import Foundation

/// Settings, findable — the port of settingsnav.js: the dialog's groups
/// (split where it already draws a divider) become titled sections, with a
/// dropdown to show one section and a search box that keeps only the
/// settings whose words match — a setting's explanation stays with it.
/// Nothing about the settings themselves changes; this only arranges what
/// the dialog already built.
enum SettingsNav {
    /// Section names, from words in the group's first setting. The first rule that matches wins.
    static let names: [(pattern: String, title: String)] = [
        ("Teleport homes", "Teleport homes and tsh"),
        ("^Theme|Accent colour|Skin", "Appearance"),
        ("font size|Scrollback|Font family", "Text and fonts"),
        ("Local automation", "Local automation (MCP)"),
        ("recent connections", "Recent connections"),
        ("While a session connects", "Connecting"),
        ("Refresh the file list|Refresh the Teleport", "Refreshing and lists"),
        ("MFA", "MFA"),
        ("X11", "X11 forwarding"),
        ("Follow the terminal|hidden files|file details|Folders first", "File browser"),
        ("KubeLife|Kubernetes", "KubeLife"),
        ("Cursor style", "Sessions and the interface"),
        ("SSH config files", "SSH config files"),
        ("AI assistant", "Assistants, tmux and watching"),
        ("Highlight", "Highlighting"),
        ("starred", "Starred hosts"),
        ("agent", "SSH agent"),
        ("Editor for remote files", "Editors"),
        ("^tsh:", "About"),
    ]

    static func title(forFirstLabel label: String) -> String {
        for (pat, title) in names where label.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil {
            return title
        }
        let t = String(label.prefix(40))
        return t.isEmpty ? "More" : t
    }

    /// One thing in the dialog: a setting (its label, hint, option labels and
    /// typed values make up `text`), or an explanation that goes with the
    /// setting just above it.
    struct Item {
        var label: String
        var text: String
        var isHint = false
    }

    struct Section {
        var title: String
        /// Indices into the flat item list.
        var items: [Int]
    }

    /// Groups (between dividers) → sections. Two groups with one name read as one section.
    static func organize(_ groups: [[Item]]) -> (sections: [Section], items: [Item]) {
        var flat: [Item] = []
        var sections: [Section] = []
        for g in groups where !g.isEmpty {
            let label = g.first { !$0.label.trimmed.isEmpty }?.label.trimmed ?? ""
            let title = title(forFirstLabel: label)
            let idx = Array(flat.count ..< flat.count + g.count)
            flat += g
            if let last = sections.indices.last, sections[last].title == title { sections[last].items += idx; continue }
            sections.append(Section(title: title, items: idx))
        }
        return (sections, flat)
    }

    /// Which items show for a search and a chosen section (`only` nil = all).
    /// Returns the visible item indices and the visible section indices.
    static func visible(_ sections: [Section], _ items: [Item], query: String, only: Int?) -> (items: Set<Int>, sections: Set<Int>) {
        let q = query.trimmed.lowercased()
        var shownItems = Set<Int>()
        var shownSections = Set<Int>()
        for (si, s) in sections.enumerated() {
            let inScope = only == nil || only == si
            let titleHit = !q.isEmpty && s.title.lowercased().contains(q)
            var shown = 0
            var prevShown = false
            for i in s.items {
                let n = items[i]
                let hit = q.isEmpty || titleHit || n.text.lowercased().contains(q)
                let show = inScope && (n.isHint ? (q.isEmpty ? true : prevShown) : hit)
                if !n.isHint { prevShown = show }
                if show { shownItems.insert(i); shown += 1 }
            }
            if inScope && shown > 0 { shownSections.insert(si) }
        }
        return (shownItems, shownSections)
    }
}
