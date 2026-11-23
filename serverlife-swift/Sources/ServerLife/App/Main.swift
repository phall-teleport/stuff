import AppKit

@main
enum Main {
    static func main() {
        // `ServerLife --mcp` is the MCP server over stdio: the same binary,
        // so registering it needs no Node and no second install.
        if CommandLine.arguments.contains("--mcp") {
            MCPBridge.runStdio()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Asked before quitting; any `false` cancels (quit guard, running transfers).
    static var shouldTerminate: [() async -> Bool] = []
    /// Run on the way out (tear down ControlMasters, stop watchers).
    static var willTerminate: [() -> Void] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Proc.warmUp()
        AppDelegate.installSignalHandlers()
        BundledFonts.registerAll()
        Store.shared.load()
        Tools.setSshPath(Store.shared.setting("sshPath", ""))
        Tools.setTshPath(Store.shared.setting("tshPath", ""))
        Theme.shared.start()
        MainMenu.shared.install()
        Features.installAll()
        AppDelegate.installResumeObservers()
        WindowManager.shared.open(slot: "w1", options: ["launch": true])
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.runIfRequested()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppDelegate.shouldTerminate.isEmpty else { return .terminateNow }
        Task { @MainActor in
            for check in AppDelegate.shouldTerminate where !(await check()) {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.cleanupBeforeExit()
    }

    private static var cleanedUp = false

    /// main.js `cleanupAndExit`: everything a quit — asked for, or forced —
    /// has to clean up before the process actually ends. Owners hook in with
    /// the `app-will-quit` action (or `willTerminate`).
    static func cleanupBeforeExit() {
        guard !cleanedUp else { return }
        cleanedUp = true
        Actions.shared.perform("app-will-quit")
        willTerminate.forEach { $0() }
        Store.shared.saveNow()
    }

    /*
     * A forceful stop — `kill`/`pkill` (SIGTERM), Ctrl-C in a foreground
     * terminal (SIGINT) — never reaches applicationShouldTerminate. Without
     * this, every helper a quit stops — `tsh proxy kube` chief among them —
     * was orphaned instead: left running with no app attached to it, for as
     * long as this Mac stayed up. No confirmation here: whatever sent the
     * signal has already decided this process ends now.
     */
    private static var signalSources: [DispatchSourceSignal] = []
    static func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    cleanupBeforeExit()
                    exit(0)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// powerMonitor `resume` / `unlock-screen` → `app-resume`: waking from
    /// sleep is when the GPU's glyph caches are most often stale, so every
    /// terminal repaints.
    static func installResumeObservers() {
        let fire: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { Actions.shared.perform("app-resume") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main, using: fire)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main, using: fire)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.open() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Every feature's `install()`, in dependency order: data and services
/// before the interface that uses them.
@MainActor
enum Features {
    static func installAll() {
        AppActions.install()
        DataFeature.install()
        ConnectionsFeature.install()
        TeleportServiceFeature.install()
        FilesServiceFeature.install()
        DevicesServiceFeature.install()
        SessionsFeature.install()
        SidebarFeature.install()
        HostsFeature.install()
        ExplorerFeature.install()
        TeleportUIFeature.install()
        FleetFeature.install()
        NetToolsFeature.install()
        ConsolesFeature.install()
        CityFeature.install()
        MiscFeature.install()
        AutomationFeature.install()
    }
}

/// The handful of actions that belong to the shell itself.
@MainActor
enum AppActions {
    static func install() {
        let a = Actions.shared
        CodeEditorDemo.install()
        a.register("new-window") { _ in WindowManager.shared.open() }
        a.register("toggle-sidebar") { ctx in
            guard let w = ctx.window else { return }
            w.sidebarVisible.toggle()
        }
        a.register("toggle-transfers") { ctx in
            guard let w = ctx.window else { return }
            // dock.js toggleDock(): show or hide, on whichever tab was last open.
            w.dockVisible.toggle()
        }
        a.register("teleport-docs") { _ in
            NSWorkspace.shared.open(URL(string: "https://goteleport.com/docs/connect-your-client/tsh/")!)
        }
    }
}
