import SwiftUI
import AppKit

/// Small copy-to-clipboard button; shows a checkmark for a moment after copying.
struct CopyButton: View {
    let text: () -> String
    var help = "Copy to clipboard"
    @StateObject private var copied = LocalFlag()

    init(_ text: String, help: String = "Copy to clipboard") { self.text = { text }; self.help = help }
    init(help: String = "Copy to clipboard", text: @escaping () -> String) { self.text = text; self.help = help }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied.on = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied.on = false }
        } label: {
            Image(systemName: copied.on ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied.on ? Color.green : Color.secondary)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .help(copied.on ? "Copied" : help)
    }
}

extension View {
    /// A copy button in the top-right corner. An overlay, so it never changes
    /// the view's size (see "Layout feedback loops" in CLAUDE.md).
    func copyable(_ text: String) -> some View {
        overlay(alignment: .topTrailing) { CopyButton(text).padding(4) }
    }
}
