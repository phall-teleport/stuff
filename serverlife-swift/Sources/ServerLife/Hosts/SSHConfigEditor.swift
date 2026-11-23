import AppKit
import SwiftUI

/// sshpresets.js `editSshConfig` and addserver.js `removeSshConfigHost`:
/// the ssh config edited in the app (file on the left, suggestions on the
/// right, checked by ssh before it is saved), and taking any ssh config host
/// out of the file it was written in. The file side is teleport-service's
/// `SSHConfig` (SSHConfigEdit.swift).
@MainActor
enum SSHConfigEditor {
    static func hostTemplate(_ alias: String = "my-server") -> String {
        ["Host \(alias)", "  HostName 203.0.113.10", "  User ubuntu", "  Port 22",
         "  IdentityFile ~/.ssh/my-key.pem", "  IdentitiesOnly yes"].joined(separator: "\n")
    }

    struct Snippet {
        let label: String
        let help: String
        let text: String
    }

    static let snippets: [Snippet] = [
        Snippet(label: "A new host", help: "A Host block to fill in — the alias is what you type after ssh.", text: hostTemplate()),
        Snippet(label: "Through a jump host", help: "Reach a private host via a bastion.",
                text: "Host private-db\n  HostName 10.0.1.20\n  User admin\n  ProxyJump bastion"),
        Snippet(label: "Defaults for every host", help: "Put it last: ssh uses the first value it finds for each option.",
                text: "Host *\n  ServerAliveInterval 30\n  ServerAliveCountMax 3\n  AddKeysToAgent yes"),
        Snippet(label: "A local port forward", help: "localhost:5432 reaches the database behind the host.",
                text: "  LocalForward 5432 localhost:5432"),
        Snippet(label: "Pull in other files", help: "At the top of the file — keep per-project hosts separate.",
                text: "Include ~/.ssh/config.d/*"),
    ]

    /// The option presets in ssh_config's own indented `Name value` form (no file pick).
    static var optionCards: [Snippet] {
        SSHPresets.all.filter { !$0.file }.map { p in
            Snippet(label: p.label,
                    help: [p.help, p.warn.map { "⚠ \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " "),
                    text: p.lines(nil).map { "  \($0.0) \($0.1)" }.joined(separator: "\n"))
        }
    }

    /// `editSshConfig(file)`; nil = ~/.ssh/config.
    static func open(_ window: WindowModel?, file: String? = nil) {
        let loaded: (path: String, text: String)
        do { loaded = try SSHConfig.readConfig(file) } catch { return HToast.error(hostsErrorText(error)) }
        let model = SSHConfigEditorModel(path: loaded.path, text: loaded.text, window: window)
        let width = min(1200, (NSScreen.main?.visibleFrame.width ?? 1300) * 0.96)
        let height = min(760, (NSScreen.main?.visibleFrame.height ?? 800) * 0.9)
        Modal.sheet(window, title: "Edit ssh config", width: width, height: height, resizable: true,
                    autosave: "sshconfig-editor", closeOnEscape: false) { handle in
            SSHConfigEditorView(model: model) { handle.close() }
        }
    }

    /// `removeSshConfigHost(host)`: the block is shown first, as it is in the
    /// file, because the file may be one the user wrote themselves.
    static func removeHost(_ host: Host, window: WindowModel?) async {
        let file = host.extra["source"]?.string?.nilIfEmpty ?? host.configFile?.nilIfEmpty
        guard let file else { return HToast.error("Not sure which file defines this host") }
        let alias = host.alias ?? host.name
        let block: SSHConfig.BlockPreview
        do { block = try SSHConfig.hostBlockPreview(file: file, alias: alias) } catch { return HToast.error(hostsErrorText(error)) }
        let shared = block.shared.isEmpty ? ""
            : "This Host line also names \(block.shared.joined(separator: ", ")). Only “\(alias)” is taken off it; the block stays for the others."
        let mode: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var answered = false
            let finish: (String?) -> Void = { v in
                if answered { return }
                answered = true
                cont.resume(returning: v)
            }
            let h = Modal.sheet(window, title: "Remove “\(alias)” from ssh config", width: 560) { handle in
                SSHRemoveHostView(alias: alias, file: file, block: block, shared: shared) { v in
                    finish(v)
                    handle.close()
                }
            }
            h.onClose.append { finish(nil) }
        }
        guard let mode else { return }
        do {
            _ = try SSHConfig.removeHostFromFile(file: file, alias: alias, mode: mode)
            StatusBus.shared.show("\(mode == "comment" ? "Commented out" : "Deleted") \(alias) in \(file)")
            await Inventory.shared.refresh()
        } catch {
            HToast.error(hostsErrorText(error))
        }
    }
}

@MainActor
final class SSHConfigEditorModel: ObservableObject {
    let path: String
    weak var window: WindowModel?
    @Published var text: String
    @Published var note = ""
    @Published var bad = false
    @Published var busy = false
    let editor = CodeEditorController()

    init(path: String, text: String, window: WindowModel?) {
        self.path = path
        self.text = text
        self.window = window
    }

    func say(_ t: String, bad: Bool = false) { note = t; self.bad = bad }

    func check() async {
        do {
            let r = try await SSHConfig.checkConfig(file: path, text: editor.value.nilIfEmpty ?? text)
            say(r.ok ? "ssh reads it fine." : "ssh can't read it:\n\(r.errors.joined(separator: "\n"))", bad: !r.ok)
        } catch {
            say("ssh can't read it:\n\(hostsErrorText(error))", bad: true)
        }
    }

    func save() async -> Bool {
        say("Checking with ssh…")
        let r: SSHConfig.WriteResult
        do { r = try await SSHConfig.writeConfig(file: path, text: text) } catch {
            r = SSHConfig.WriteResult(ok: false, errors: [hostsErrorText(error)])
        }
        if !r.ok { say("Not saved — ssh can't read it:\n\(r.errors.joined(separator: "\n"))", bad: true); return false }
        HToast.info("Saved \(r.path) — the previous version is in \((r.backup as NSString).lastPathComponent)")
        Task { @MainActor in await Inventory.shared.refresh() }
        return true
    }

    func pickKeyAndInsert() {
        Task { @MainActor in
            if let f = await SSHConfig.pickKey(window: window) { editor.insert("  IdentityFile \(f)\n  IdentitiesOnly yes") }
        }
    }
}

private struct SSHConfigEditorView: View {
    @ObservedObject var model: SSHConfigEditorModel
    let close: () -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Edit ssh config", subtitle: model.path, scroll: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    // Coloured as ssh_config; an option ssh would not know is underlined. Tab indents.
                    CodeEditor(text: $model.text, language: .sshConfig, tabIndents: true, controller: model.editor)
                        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Suggestions").font(.system(size: 12.5, weight: .semibold)).padding(.bottom, 6)
                            Text("Copy one, or put the cursor where it belongs and insert it. Options go indented under a Host line.")
                                .font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 8)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(SSHConfigEditor.snippets.enumerated()), id: \.offset) { _, s in
                                SSHSuggestionCard(snippet: s, editor: model.editor)
                            }
                            Text("Options for a Host block").font(.system(size: 12.5, weight: .semibold))
                                .padding(.top, 10).padding(.bottom, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Use only this key file…").font(.system(size: 12, weight: .semibold))
                                Text("Pick a .pem or id_* file; adds IdentityFile and IdentitiesOnly at the cursor.")
                                    .font(.system(size: 11)).foregroundStyle(p.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Choose a key and insert…") { model.pickKeyAndInsert() }.buttonStyle(.ghostSmall)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
                            .padding(.bottom, 8)
                            ForEach(Array(SSHConfigEditor.optionCards.enumerated()), id: \.offset) { _, s in
                                SSHSuggestionCard(snippet: s, editor: model.editor)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .frame(width: 340)
                }
                .frame(maxHeight: .infinity)
                Text(model.note)
                    .font(.system(size: 11)).foregroundStyle(model.bad ? p.red : p.textDim)
                    .frame(minHeight: 15, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(16)
        } footer: {
            Button("Open in external editor") {
                let path = model.path
                Task { @MainActor in
                    do { try await SSHConfig.openInEditor(path) } catch { HToast.error(hostsErrorText(error)) }
                }
            }
            .buttonStyle(.ghost)
            Button("Check") { Task { @MainActor in await model.check() } }.buttonStyle(.ghost)
            Spacer()
            Button("Cancel") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") {
                guard !model.busy else { return }
                model.busy = true
                Task { @MainActor in
                    let ok = await model.save()
                    model.busy = false
                    if ok { close() }
                }
            }
            .buttonStyle(.primary)
        }
    }
}

private struct SSHSuggestionCard: View {
    let snippet: SSHConfigEditor.Snippet
    let editor: CodeEditorController

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            Text(snippet.label).font(.system(size: 12, weight: .semibold))
            if !snippet.help.isEmpty {
                Text(snippet.help).font(.system(size: 11)).foregroundStyle(p.muted)
                    .padding(.top, 2).padding(.bottom, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(snippet.text).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            HStack(spacing: 6) {
                Button("Copy") { Clipboard.write(snippet.text); HToast.info("Copied") }.buttonStyle(.ghostSmall)
                Button("Insert at cursor") { editor.insert(snippet.text) }.buttonStyle(.ghostSmall)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
        .padding(.bottom, 8)
    }
}

private struct SSHRemoveHostView: View {
    let alias: String
    let file: String
    let block: SSHConfig.BlockPreview
    let shared: String
    let done: (String?) -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Remove “\(alias)” from ssh config", subtitle: "\(file), line \(block.line)", width: 560) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(block.text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.textDim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .padding(.bottom, 10)
                if !shared.isEmpty { MiscHint(text: shared).padding(.bottom, 6) }
                MiscHint(text: "Comment out keeps the lines, prefixed with #, so they can be restored by hand. "
                    + "The file as it is now is copied to \((file as NSString).lastPathComponent).serverlife-backup first.")
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Comment out") { done("comment") }.buttonStyle(.ghost)
            Button("Delete") { done("delete") }.buttonStyle(.danger)
        }
    }
}
