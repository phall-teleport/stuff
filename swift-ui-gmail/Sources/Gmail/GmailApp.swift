import SwiftUI
import WebKit

@main
struct GmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = WebViewModel.shared

    var body: some Scene {
        Window("Gmail", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            AppCommands(model: model)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: WebViewModel

    var body: some View {
        ZStack(alignment: .top) {
            WebViewRepresentable(webView: model.webView)

            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .padding(.horizontal, -2)
                    .offset(y: -6)
                    .transition(.opacity)
            }

            if let error = model.loadError {
                OfflineView(message: error) { model.reload() }
            }
        }
        .navigationTitle(model.title)
    }
}

struct OfflineView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Can't reach Gmail")
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try Again", action: retry)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
