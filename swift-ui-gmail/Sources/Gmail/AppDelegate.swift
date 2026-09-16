import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationSupport.requestAuthorization(delegate: self)
    }

    /// Keep running when the window is closed so badge updates and notifications continue,
    /// like a Chrome app does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon click with no visible window: bring the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let main = sender.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            main.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    /// Registered as a `mailto:` handler in Info.plist.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "mailto" {
            Task { @MainActor in WebViewModel.shared.load(mailto: url) }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            switch info["kind"] as? String {
            case "download":
                if let path = info["path"] as? String {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            case "web":
                if let id = info["id"] as? String {
                    WebViewModel.shared.notificationClicked(id: id)
                }
            default:
                break
            }
            completionHandler()
        }
    }
}
