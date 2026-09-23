import AppKit
import Combine
import UserNotifications
import WebKit

/// Owns the single Gmail web view and acts as its navigation / UI / download delegate.
@MainActor
final class WebViewModel: NSObject, ObservableObject {
    static let shared = WebViewModel()

    static let homeURL = URL(string: "https://mail.google.com/mail/u/0/")!
    static let composeURL = URL(string: "https://mail.google.com/mail/u/0/#inbox?compose=new")!

    /// Hosts that are allowed to open as in-app windows. Everything else a user clicks
    /// opens in the default browser, like a Chrome app would.
    private static let inAppHosts: Set<String> = [
        "mail.google.com",
        "accounts.google.com",
        "accounts.youtube.com",
        "myaccount.google.com",
        "ogs.google.com",
    ]

    let webView: WKWebView

    @Published private(set) var title = "Gmail"
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loadError: String?
    @Published private(set) var unreadCount = 0

    private var observers: [NSKeyValueObservation] = []
    /// Set once the injected script has reported a count; the page title is then ignored
    /// as a source because it only carries the count while the inbox is showing.
    private var scriptReportsUnread = false
    private var popups: [PopupWindowController] = []
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    private static let zoomKey = "pageZoom"

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Google refuses sign-in from user agents it doesn't recognise as a browser, and
        // flags old Safari versions as unsupported. Appending the installed Safari's product
        // tokens makes the UA look like the current desktop Safari.
        config.applicationNameForUserAgent = "Version/\(Self.installedSafariVersion) Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let content = WKUserContentController()
        content.addUserScript(
            WKUserScript(source: NotificationBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        content.addUserScript(
            WKUserScript(source: UnreadBadgeScript.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        config.userContentController = content

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        content.add(WeakScriptMessageHandler(self), name: NotificationBridge.handlerName)
        content.add(WeakScriptMessageHandler(self), name: UnreadBadgeScript.handlerName)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = false

        let savedZoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        if savedZoom > 0 { webView.pageZoom = savedZoom }

        observers = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.titleDidChange(wv.title) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.isLoading = wv.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
        ]

        webView.load(URLRequest(url: Self.homeURL))
    }

    // MARK: - Actions

    func reload() {
        loadError = nil
        if webView.url == nil {
            webView.load(URLRequest(url: Self.homeURL))
        } else {
            webView.reload()
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func goHome() { webView.load(URLRequest(url: Self.homeURL)) }
    func compose() { webView.load(URLRequest(url: Self.composeURL)) }

    func openInBrowser() {
        NSWorkspace.shared.open(webView.url ?? Self.homeURL)
    }

    func copyLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString((webView.url ?? Self.homeURL).absoluteString, forType: .string)
    }

    func zoom(by delta: Double) {
        setZoom(webView.pageZoom + delta)
    }

    func resetZoom() { setZoom(1.0) }

    private func setZoom(_ value: Double) {
        let clamped = min(max(value, 0.5), 3.0)
        webView.pageZoom = clamped
        UserDefaults.standard.set(clamped, forKey: Self.zoomKey)
    }

    /// Opens a `mailto:` URL in Gmail's compose window.
    func load(mailto url: URL) {
        var comps = URLComponents(string: "https://mail.google.com/mail/")!
        comps.queryItems = [
            URLQueryItem(name: "extsrc", value: "mailto"),
            URLQueryItem(name: "url", value: url.absoluteString),
        ]
        if let target = comps.url {
            webView.load(URLRequest(url: target))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called when the user clicks a macOS notification that originated from the page.
    func notificationClicked(id: String) {
        let js = "window.\(NotificationBridge.clickCallback) && window.\(NotificationBridge.clickCallback)(\(jsString(id)));"
        webView.evaluateJavaScript(js)
    }

    // MARK: - Title & badge

    private func titleDidChange(_ newTitle: String?) {
        let t = (newTitle ?? "").trimmingCharacters(in: .whitespaces)
        title = t.isEmpty ? "Gmail" : t

        // Fallback only: Gmail titles look like "Inbox (12) - you@example.com - Gmail", but
        // the count is present only while the inbox is showing. Prefer the injected script.
        guard !scriptReportsUnread, t.hasPrefix("Inbox") else { return }
        let count: Int
        if let open = t.firstIndex(of: "("), let close = t[open...].firstIndex(of: ")") {
            let digits = t[t.index(after: open)..<close].filter(\.isNumber)
            count = Int(digits) ?? 0
        } else {
            count = 0
        }
        setUnreadCount(count)
    }

    private func setUnreadCount(_ count: Int) {
        guard count != unreadCount else { return }
        unreadCount = count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: - Helpers

    /// Version of the Safari installed on this Mac (e.g. "27.0"), so the user agent
    /// always matches a browser Google currently supports.
    private static let installedSafariVersion: String = {
        let plist = "/Applications/Safari.app/Contents/Info.plist"
        if let dict = NSDictionary(contentsOfFile: plist),
           let version = dict["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return version
        }
        // Fall back to the macOS major version, which Safari tracks since macOS 26.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return os.majorVersion >= 26 ? "\(os.majorVersion).\(os.minorVersion)" : "18.5"
    }()

    private static func isInAppHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true } // about:blank etc.
        return inAppHosts.contains(host) || host.hasSuffix(".accounts.google.com")
    }

    private static func isWebScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return ["http", "https", "about", "blob", "data", "javascript"].contains(scheme)
    }

    private func removePopup(_ popup: PopupWindowController) {
        popups.removeAll { $0 === popup }
    }

    private func popup(for webView: WKWebView) -> PopupWindowController? {
        popups.first { $0.webView === webView }
    }

    private func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
    }

    private func hostWindow(for webView: WKWebView) -> NSWindow? {
        webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }
}

// MARK: - WKNavigationDelegate

extension WebViewModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            return decisionHandler(.cancel, preferences)
        }

        if navigationAction.shouldPerformDownload {
            return decisionHandler(.download, preferences)
        }

        // Non-web schemes (zoommtg:, slack:, tel:, ...) go to the system. mailto: stays in Gmail.
        if !Self.isWebScheme(url) {
            if url.scheme?.lowercased() == "mailto" {
                load(mailto: url)
            } else {
                NSWorkspace.shared.open(url)
            }
            return decisionHandler(.cancel, preferences)
        }

        let isTopLevel = navigationAction.targetFrame?.isMainFrame ?? true
        let userClicked = navigationAction.navigationType == .linkActivated

        // A user-clicked link that leaves Gmail opens in the default browser. Redirects,
        // form posts and script-driven navigations (SSO, OAuth) stay in-app.
        if isTopLevel, userClicked, !Self.isInAppHost(url) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel, preferences)
        }

        // A freshly opened popup (window.open('') then location = ...) heading off-site
        // should also go to the browser and the empty popup should close.
        if let popup = popup(for: webView), popup.isFresh, isTopLevel {
            popup.isFresh = false
            if !Self.isInAppHost(url) {
                NSWorkspace.shared.open(url)
                popup.close()
                removePopup(popup)
                return decisionHandler(.cancel, preferences)
            }
        }

        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { loadError = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error, in: webView)
    }

    private func handle(_ error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        // Cancelled navigations (redirects, downloads we intercepted) aren't failures.
        // 102 is WebKitErrorFrameLoadInterruptedByPolicyChange (WebKitErrorDomain).
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        guard webView === self.webView else { return }
        loadError = nsError.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension WebViewModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           url.scheme?.lowercased().hasPrefix("http") == true,
           !Self.isInAppHost(url) {
            NSWorkspace.shared.open(url)
            return nil
        }

        let popup = PopupWindowController(configuration: configuration, features: windowFeatures, delegate: self)
        popup.onClose = { [weak self, weak popup] in
            guard let popup else { return }
            self?.removePopup(popup)
        }
        popups.append(popup)
        popup.showWindow(nil)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let popup = popup(for: webView) else { return }
        popup.close()
        removePopup(popup)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Meet / voice notes inside Gmail. macOS still shows its own camera/mic prompt once.
        let host = origin.host.lowercased()
        decisionHandler(host.hasSuffix("google.com") ? .grant : .prompt)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        if let window = hostWindow(for: webView) {
            alert.beginSheetModal(for: window) { _ in completionHandler() }
        } else {
            alert.runModal()
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let window = hostWindow(for: webView) {
            alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
        } else {
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        if let window = hostWindow(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = hostWindow(for: webView) {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

// MARK: - WKDownloadDelegate

extension WebViewModel: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var dest = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(candidate)
            n += 1
        }

        downloadDestinations[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Makes the Downloads stack in the Dock bounce, like Safari/Chrome.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)
        NotificationSupport.post(
            title: "Download complete",
            body: dest.lastPathComponent,
            userInfo: ["kind": "download", "path": dest.path]
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let dest = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NotificationSupport.post(
            title: "Download failed",
            body: dest?.lastPathComponent ?? error.localizedDescription,
            userInfo: [:]
        )
    }
}

// MARK: - Script messages (web Notification → macOS notification)

extension WebViewModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }

        if message.name == UnreadBadgeScript.handlerName {
            // The count only arrives from the main Gmail web view, never from popups.
            guard message.webView === webView else { return }
            let count = (body["count"] as? NSNumber)?.intValue ?? 0
            NSLog("[unread] count=%d source=%@", count, (body["source"] as? String) ?? "?")
            scriptReportsUnread = true
            setUnreadCount(count)
            return
        }

        guard message.name == NotificationBridge.handlerName else { return }
        let title = (body["title"] as? String) ?? "Gmail"
        let text = (body["body"] as? String) ?? ""
        let id = (body["id"] as? String) ?? UUID().uuidString
        let tag = (body["tag"] as? String) ?? ""
        NotificationSupport.post(
            title: title,
            body: text,
            identifier: tag.isEmpty ? id : "tag-\(tag)",
            userInfo: ["kind": "web", "id": id]
        )
    }
}

/// WKUserContentController retains its handlers strongly; this breaks the cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
