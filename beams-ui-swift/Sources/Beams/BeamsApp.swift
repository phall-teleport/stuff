import SwiftUI

@main
struct BeamsApp: App {
    // The App value lives for the whole process, so a plain stored model is
    // fine here (and avoids the @State macro, see LocalState.swift).
    private let model: AppModel

    init() {
        do {
            model = try AppModel()
        } catch {
            // Application Support isn't writable; nothing sensible to show.
            fatalError("Beams could not open its data directory: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("Beams") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.boot() }
        }
        // Standard unified title bar: without it (.hiddenTitleBar) the detail
        // ScrollView renders up into the title-bar area and overlaps the toolbar.
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Beam") { Task { await model.createBeam() } }.keyboardShortcut("n")
                Button("Refresh Beams") { Task { await model.loadBeams() } }.keyboardShortcut("r")
                Divider()
                Button("Open Previous Session from GitHub…") { model.openFromGitHub() }.keyboardShortcut("o")
            }
            CommandMenu("Session") {
                Button("Stop Turn") { model.stop() }.keyboardShortcut(".", modifiers: .command).disabled(!model.currentBusy)
                Divider()
                Button("Pull Memory from Beam") { Task { await model.pullMemory() } }.disabled(model.current == nil)
                Button("Sync Beam Session to GitHub") { Task { await model.syncNow() } }.disabled(model.current == nil)
                Divider()
                Button("Toggle Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}
