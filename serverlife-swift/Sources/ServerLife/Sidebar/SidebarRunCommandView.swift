import AppKit
import SwiftUI

struct RunCommandView: View {
    @ObservedObject var model: RunCommandModel
    let title: String
    let window: WindowModel?
    let close: () -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: title, subtitle: HostPrefs.label(model.host), width: 720) {
            VStack(alignment: .leading, spacing: 4) {
                MiscField(label: "Command", hint: "Enter runs it · Shift+Enter for a new line") {
                    SBCommandEditor(text: $model.command, placeholder: "systemctl status nginx") { model.run() }
                        .frame(height: 78)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                        .overlay(alignment: .topTrailing) { recentButton.padding(4) }
                }
                MiscField(label: "Run as") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            TextField("default login", text: $model.runAs)
                                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                                .help("The account the command runs as on this host")
                            if !model.loginChoices.isEmpty {
                                Menu("") {
                                    ForEach(model.loginChoices, id: \.self) { l in Button(l) { model.runAs = l } }
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                        MiscHint(text: model.runAsNote, size: 11)
                    }
                }
                Text("Output").font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 1)
                ScrollView {
                    Text(model.output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(model.failed ? p.red : p.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                }
                .frame(minHeight: 64, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                if !model.meta.isEmpty { MiscHint(text: model.meta, size: 11).padding(.top, 6) }
                if let prompt = model.prompt {
                    VStack(alignment: .leading, spacing: 4) {
                        MiscHint(text: prompt, size: 11)
                        SecureField("MFA code, or press Enter after tapping your key", text: $model.answer)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.answerPrompt() }
                    }
                    .padding(.top, 8)
                }
            }
        } footer: {
            Button("Copy output") { model.copyOutput() }.buttonStyle(.ghost)
            Button("Save as snippet") {
                let cmd = model.command.trimmed
                if cmd.isEmpty { SBActions.toast("Enter a command first", .error); return }
                Actions.shared.perform("snippet-from-selection", window: window, args: ["text": cmd])
            }.buttonStyle(.ghost)
            Button("Run") { model.run() }.buttonStyle(.primary)
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
        .onDisappear { model.closed() }
    }

    private var recentButton: some View {
        Button("Recent…") {
            let list = SBCommandHistory.list
            if list.isEmpty { SBActions.toast("Nothing run yet", .info); return }
            let items = list.map { c in CtxItem(SBCommandHistory.label(c)) { model.command = c } }
            CtxMenu.build(items).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        .buttonStyle(.ghost).controlSize(.small)
        .help("Pick a command run here before")
    }
}
