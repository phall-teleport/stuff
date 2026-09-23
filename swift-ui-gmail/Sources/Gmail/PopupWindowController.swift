import AppKit
import WebKit

/// A secondary window for `window.open` targets that should stay in-app
/// (Google sign-in flows, "open compose in new window", etc.).
@MainActor
final class PopupWindowController: NSWindowController, NSWindowDelegate {
    let webView: WKWebView
    /// True until the popup performs its first top-level navigation.
    var isFresh = true
    var onClose: (() -> Void)?

    private var titleObserver: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, delegate: WebViewModel) {
        let width = features.width?.doubleValue ?? 1000
        let height = features.height?.doubleValue ?? 720
        let frame = NSRect(x: 0, y: 0, width: max(width, 400), height: max(height, 300))

        webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.title = "Gmail"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        titleObserver = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            let title = wv.title ?? ""
            Task { @MainActor in self?.window?.title = title.isEmpty ? "Gmail" : title }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        onClose?()
    }
}
