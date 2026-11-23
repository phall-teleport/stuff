import SwiftUI

/// kubepanel.js `openPodRunCommandDialog`: one command in a pod, run once
/// and shown — `kubectl exec` with no pty — plus its own history
/// (settings.kubeCommandHistory, 25 most recent).
@MainActor
enum KubeRunCommand {
    static let maxHistory = 25

    static var history: [String] { Store.shared.settingJSON("kubeCommandHistory").stringArray }
    static func remember(_ cmd: String) {
        let list = Array(([cmd] + history.filter { $0 != cmd }).prefix(maxHistory))
        Store.shared.setSettingJSON("kubeCommandHistory", JSON(list))
    }
    static func clearHistory() { Store.shared.setSettingJSON("kubeCommandHistory", JSON([String]())) }

    static func open(_ k: KubeUISpec, _ pod: KubePodRef, _ container: String?) {
        Modal.sheet(title: "Run a command", width: 720, resizable: true) { h in
            KubeRunCommandView(k: k, pod: pod, container: container?.nilIfEmpty, close: { h.close() })
        }
    }
}

private struct KubeRunCommandView: View {
    let k: KubeUISpec
    let pod: KubePodRef
    let container: String?
    let close: () -> Void
    @StateObject private var cmd = Local(KubeRunCommand.history.first ?? "")
    @StateObject private var output = Local("Output appears here.")
    @StateObject private var failed = Local(false)
    @StateObject private var meta = Local("")
    @StateObject private var running = Local(false)
    @StateObject private var last = Local("")

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Run a command", subtitle: KubePanes.label(pod, container), scroll: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Command").font(.system(size: 11)).foregroundStyle(p.muted)
                ZStack(alignment: .topTrailing) {
                    KubeCommandField(text: $cmd.value, onSubmit: run)
                        .frame(height: 78)
                    Button("Recent…") { recentMenu() }.buttonStyle(.ghostSmall).padding(4)
                        .help("Pick a command run here before")
                }
                Text("Enter runs it · Shift+Enter for a new line").font(.system(size: 11)).foregroundStyle(p.muted)
                Text("Output").font(.system(size: 11)).foregroundStyle(p.muted).padding(.top, 4)
                ScrollView {
                    Text(output.value).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(failed.value ? p.red : p.text)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(9)
                }
                .frame(minHeight: 64, maxHeight: 320)
                .background(p.panel2).overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
                if !meta.value.isEmpty { Text(meta.value).font(.system(size: 11)).foregroundStyle(p.muted) }
            }
        } footer: {
            Button("Save output…") {
                if last.value.isEmpty { StatusBus.shared.toast("Nothing to save yet"); return }
                let name = container.map { "\(pod.name)-\($0)" } ?? pod.name
                Task {
                    if let u = await Modal.saveText(nil, last.value, defaultName: "\(name)-output.txt", title: "Save command output") {
                        StatusBus.shared.toast("Saved \(u.path)")
                    }
                }
            }.buttonStyle(.ghost)
            Button("Copy output") {
                if last.value.isEmpty { StatusBus.shared.toast("Nothing to copy yet"); return }
                Clipboard.write(last.value); StatusBus.shared.toast("Output copied")
            }.buttonStyle(.ghost)
            Button("Run") { run() }.buttonStyle(.primary)
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }

    private func recentMenu() {
        let list = KubeRunCommand.history
        var items: [CtxItem] = list.isEmpty ? [CtxItem("Nothing run yet", disabled: true)] : list.map { c in
            let first = String(c.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
            let label = String(first.prefix(60)) + (c.count > 60 || c.contains("\n") ? "…" : "")
            return CtxItem(label) { cmd.value = c }
        }
        items.append(.sep)
        items.append(CtxItem("Clear history", disabled: list.isEmpty) {
            KubeRunCommand.clearHistory(); StatusBus.shared.toast("History cleared")
        })
        CtxMenu.show(items)
    }

    private func run() {
        let c = cmd.value.trimmed
        if c.isEmpty { StatusBus.shared.toast("Enter a command", kind: .error); return }
        if running.value { return }
        running.value = true
        KubeRunCommand.remember(c)
        output.value = "Running…"; meta.value = ""; failed.value = false
        let t0 = nowMs()
        Task { @MainActor in
            let spec = KubePanes.podSpec(k, pod, container)
            let r = await Kube.execRun(spec, c)
            let ok = r["ok"].bool == true
            let so = r["stdout"].string ?? "", se = r["stderr"].string ?? ""
            let combined = [so, se].filter { !$0.trimmed.isEmpty }.joined(separator: "\n\n")
            last.value = ok ? so : (combined.trimmed.nilIfEmpty ?? r["error"].string ?? "Command failed")
            output.value = last.value.trimmed.nilIfEmpty ?? "(no output)"
            failed.value = !ok
            let took = Fmt.duration(ms: nowMs() - t0)
            meta.value = ok ? "Finished in \(took) · \(so.utf8.count) bytes" : "Failed after \(took)"
            running.value = false
        }
    }
}

/// A monospaced multi-line field where Return runs and Shift+Return breaks the line.
private struct KubeCommandField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.delegate = context.coordinator
        tv.string = text
        tv.backgroundColor = NSColor(Theme.shared.p.panel2)
        tv.textColor = NSColor(Theme.shared.p.text)
        sv.borderType = .bezelBorder
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = sv.documentView as? NSTextView, tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, NSTextViewDelegate {
        var parent: KubeCommandField
        init(_ p: KubeCommandField) { parent = p }
        func textDidChange(_ n: Notification) {
            if let tv = n.object as? NSTextView { parent.text = tv.string }
        }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) { tv.insertNewlineIgnoringFieldEditor(nil); return true }
                parent.onSubmit(); return true
            }
            return false
        }
    }
}
