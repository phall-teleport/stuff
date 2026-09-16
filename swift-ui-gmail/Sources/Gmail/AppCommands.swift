import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var model: WebViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { model.compose() }
                .keyboardShortcut("n")
        }

        CommandMenu("Navigate") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Button("Inbox") { model.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Reload") { model.reload() }
                .keyboardShortcut("r")
            Divider()
            Button("Open in Browser") { model.openInBrowser() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Copy Link") { model.copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom In") { model.zoom(by: 0.1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.zoom(by: -0.1) }
                .keyboardShortcut("-")
            Button("Actual Size") { model.resetZoom() }
                .keyboardShortcut("0")
            Divider()
        }
    }
}
