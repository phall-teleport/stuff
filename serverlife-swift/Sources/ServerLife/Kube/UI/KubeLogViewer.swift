import SwiftUI

/// kubelogviewer.js: one pod (or every pod behind a selector) as searchable
/// lines rather than a terminal — a capped buffer, a filter, follow, and a
/// download of the whole buffer. Opened as a view pane in its own tab.
@MainActor
final class KubeLogViewerModel: ObservableObject {
    static let maxLines = 20000
    let spec: KubeSpec
    let namespace: String?, pod: String?, container: String?, selector: String?
    let title: String
    @Published var lines: [String] = []
    @Published var trimmed = false
    @Published var filter = ""
    @Published var regex = false
    @Published var follow = true
    @Published var running = false
    @Published var status = ""
    private var sessionId: String?

    init(spec: KubeSpec, namespace: String?, pod: String?, container: String?, selector: String?, title: String) {
        self.spec = spec; self.namespace = namespace; self.pod = pod; self.container = container
        self.selector = selector; self.title = title
    }

    func matches(_ line: String) -> Bool {
        if filter.isEmpty { return true }
        if !regex { return line.localizedCaseInsensitiveContains(filter) }
        guard let re = try? NSRegularExpression(pattern: filter, options: .caseInsensitive) else { return true }
        return re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    var shown: [String] { filter.isEmpty ? lines : lines.filter(matches) }

    func stop() {
        if let id = sessionId { KubeLogs.shared.stop(id) }
        sessionId = nil
        running = false
    }

    func start() {
        stop()
        var given: String?
        let r = KubeLogs.shared.start(spec, podName: pod, selector: selector, namespace: namespace, containerName: container) { [weak self] evt in
            guard let self, evt["id"].string == (self.sessionId ?? given) else { return }
            if evt["done"].bool == true {
                self.running = false
                let code = Int(evt["code"].double ?? 0)
                self.status = evt["error"].string ?? (code != 0 ? "kubectl exited with code \(code)" : "Stopped")
                return
            }
            if let l = evt["line"].string { self.add(l) }
        }
        guard r["ok"].bool == true, let id = r["id"].string else {
            status = r["error"].string ?? "Could not start reading logs"; running = false; return
        }
        given = id
        sessionId = id
        running = true
        status = ""
    }

    private func add(_ l: String) {
        lines.append(l)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines); trimmed = true }
    }

    func download() async {
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let safe = title.replacingOccurrences(of: #"[^\w.-]+"#, with: "-", options: .regularExpression)
        if let u = await Modal.saveText(nil, text, defaultName: "\(safe).log", title: "Download \(title)") {
            StatusBus.shared.toast("Saved \(u.path)")
        }
    }
}

@MainActor
enum KubeLogViewer {
    static func open(_ spec: KubeSpec, namespace: String?, pod: String? = nil, container: String? = nil,
                     selector: String? = nil, title: String? = nil, window: WindowModel? = nil) {
        let t = title ?? selector ?? pod ?? "Logs"
        let m = KubeLogViewerModel(spec: spec, namespace: namespace, pod: pod, container: container, selector: selector, title: t)
        m.start()
        let view: () -> AnyView = { AnyView(KubeLogViewerView(m: m)) }
        let onClose: () -> Void = { m.stop() }
        Actions.shared.perform("open-view-pane", ActionContext(window: window ?? WindowManager.shared.focused,
                                                               args: ["title": t, "view": view, "onClose": onClose]))
    }
}

struct KubeLogViewerView: View {
    @ObservedObject var m: KubeLogViewerModel
    var body: some View {
        let p = Theme.shared.p
        let shown = m.shown
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Filter…", text: $m.filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Toggle("Regex", isOn: $m.regex)
                Toggle("Follow", isOn: $m.follow)
                Spacer()
                Text("\(m.lines.count)\(m.trimmed ? "+" : "") line(s)").font(.system(size: 11)).foregroundStyle(p.muted)
                Button(m.running ? "Stop" : "Restart") { if m.running { m.stop() } else { m.start() } }.buttonStyle(.ghostSmall)
                Button("Download…") { Task { await m.download() } }.buttonStyle(.ghostSmall)
            }
            if m.trimmed {
                Text("Only the most recent \(KubeLogViewerModel.maxLines.formatted()) lines are kept — earlier lines were dropped.")
                    .font(.system(size: 11)).foregroundStyle(p.muted)
            }
            if !m.status.isEmpty { Text(m.status).font(.system(size: 11)).foregroundStyle(p.muted) }
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.text)
                                .textSelection(.enabled).id(i)
                        }
                    }.padding(6)
                }
                .background(p.panel2)
                .onChange(of: shown.count) { _, n in if m.follow, n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
        }
        .padding(8)
        .background(p.bg)
    }
}
