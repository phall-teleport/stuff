import SwiftUI

/*
 * My add-ins: setups of your own for "Build a Phase from setups", one YAML
 * file each in a folder (PhaseSetups reads them; the format is described at
 * the top of every new one). Here they are listed, written in an editor that
 * checks each as it is typed — the same check the builder makes, with the
 * stage it would add shown underneath — saved, deleted, and the folder opened
 * or moved (a shared, checked-out repo, say, so a team has the same ones).
 */
@MainActor
final class PhaseAddinsModel: ObservableObject {
    struct Entry: Identifiable { var file: String; var label: String; var sub: String; var bad: Bool; var text: String; var id: String { file } }

    @Published var dir = ""
    @Published var custom = false
    @Published var entries: [Entry] = []
    /// What is being edited: an existing file, or a new one (file nil) with a name to give.
    @Published var currentFile: String?
    @Published var name = ""
    @Published var text = ""
    @Published var ok = false
    @Published var result = ""
    @Published var preview = ""
    var changed = false
    let editor = CodeEditorController()
    private var timer: Task<Void, Never>?

    init() { reload(); select(entries.first) }

    /// phasesetup:addins.
    func reload() {
        let r = PhaseSetups.loadAddins(PhaseSetupFiles.addinsDir)
        let read: (String) -> String = { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "" }
        dir = r.dir
        custom = !PhaseSetupFiles.customAddinsDir.isEmpty
        entries = r.addins.map { Entry(file: $0.file ?? "", label: $0.label, sub: "\($0.group) · \($0.stage)", bad: false, text: read($0.file ?? "")) }
            + r.problems.map { Entry(file: $0.file, label: ($0.file as NSString).lastPathComponent, sub: $0.error, bad: true, text: read($0.file)) }
    }

    func select(_ e: Entry?) {
        currentFile = e?.file
        name = e.map { ($0.file as NSString).lastPathComponent.replacingOccurrences(of: #"\.ya?ml$"#, with: "", options: [.regularExpression, .caseInsensitive]) } ?? ""
        text = e?.text ?? PhaseSetups.addinTemplate
        // From the top, not wherever the caret was in the last one.
        DispatchQueue.main.async { [editor] in editor.selectedRange = NSRange(location: 0, length: 0) }
        check()
    }

    func check() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            let r = PhaseSetupFiles.checkAddin(text: self.text, name: self.name.nilIfEmpty ?? "addin")
            self.ok = r.ok
            self.result = r.ok
                ? "✓ \"\(r.label)\" — goes in a \(r.stage == "any" ? "stage of either kind" : r.stage == "files" ? "copy-files stage" : "commands stage")"
                : "✕ " + r.errors.joined(separator: " · ")
            // The stage it adds, with its defaults filled in — the header line is the builder's, not the add-in's.
            self.preview = r.yaml.replacingOccurrences(of: #"^#.*\n"#, with: "", options: .regularExpression)
        }
    }

    func save() {
        let r = PhaseSetupFiles.checkAddin(text: text, name: name)
        if !r.ok { PHStatus.toast(r.errors.first ?? "", "error", ms: 8000); return }
        do {
            let out = try PhaseSetupFiles.saveAddin(name: name.trimmed, text: text, file: currentFile)
            changed = true
            reload()
            if let e = entries.first(where: { $0.file == out && !$0.bad }) { select(e) }
            PHStatus.show("Saved \(out)", ms: 6000)
        } catch { PHStatus.toast((error as? AppError)?.message ?? error.localizedDescription, "error", ms: 8000) }
    }

    func delete(window: WindowModel?) async {
        guard let file = currentFile else { return }
        guard await Modal.confirm(window, title: "Delete \(name).yaml?",
                                  message: "The add-in file is removed. Phases already built with it are not changed.",
                                  ok: "Delete", destructive: true) else { return }
        do { try PhaseSetupFiles.removeAddin(file) } catch { PHStatus.toast((error as? AppError)?.message ?? "\(error)", "error") }
        changed = true
        reload(); select(entries.first)
    }

    func chooseDir(reset: Bool) async {
        if await PhaseSetupFiles.chooseAddinsDir(reset: reset) != nil {
            changed = true; reload(); select(entries.first { !$0.bad })
        }
    }
}

enum PhaseAddins {
    /// Open the manager. True when something was saved or deleted, so the builder reads the list again.
    @MainActor static func open(window: WindowModel?) async -> Bool {
        let m = PhaseAddinsModel()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            let finish = { if !done { done = true; cont.resume() } }
            let h = Modal.sheet(window, title: "My Phase add-ins", width: 1180, height: 780, resizable: true, autosave: "phase-addins") { handle in
                DialogScaffold(title: "My Phase add-ins", subtitle: "Setups of your own, one YAML file each", scroll: false) {
                    PhaseAddinsBody(m: m)
                } footer: {
                    Button("Delete") { Task { @MainActor in await m.delete(window: window) } }.buttonStyle(.ghost)
                    Spacer()
                    Button("Close") { finish(); handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                    Button("Save") { m.save() }.buttonStyle(.primary)
                }
            }
            h.onClose.append { finish() }
        }
        return m.changed
    }
}
