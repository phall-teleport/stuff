import SwiftUI

/// The add-in manager's two halves: the list and folder on the left, the editor and its check on the right.
struct PhaseAddinsBody: View {
    @ObservedObject var m: PhaseAddinsModel

    var body: some View {
        let p = Theme.shared.p
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Button("+ New add-in") { m.select(nil) }.buttonStyle(.ghost).controlSize(.small)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(m.entries) { e in row(e) }
                        if m.entries.isEmpty {
                            Text("None yet — New add-in starts one from an example.").font(.system(size: 11)).foregroundStyle(p.muted)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text("Folder: \(m.dir)\(m.custom ? "" : " (the app\u{2019}s own)")")
                    .font(.system(size: 11)).foregroundStyle(p.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                PhaseFlow(items: m.custom ? [0, 1, 2] : [0, 1]) { i in
                    switch i {
                    case 0: Button("Open folder") { PhaseSetupFiles.openAddinsDir() }.buttonStyle(.ghost).controlSize(.small)
                    case 1:
                        Button("Use another folder…") { Task { @MainActor in await m.chooseDir(reset: false) } }
                            .buttonStyle(.ghost).controlSize(.small)
                            .help("A shared folder — a checked-out repo, say — so a team has the same add-ins")
                    default:
                        Button("Back to the app\u{2019}s folder") { Task { @MainActor in await m.chooseDir(reset: true) } }
                            .buttonStyle(.ghost).controlSize(.small)
                    }
                }
            }
            .frame(width: 250)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("File").font(.system(size: 12)).foregroundStyle(p.text)
                    TextField("file-name (lowercase)", text: $m.name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        .disabled(m.currentFile != nil)
                        .onChange(of: m.name) { _, _ in m.check() }
                    Text(".yaml").font(.system(size: 11)).foregroundStyle(p.muted)
                }
                CodeEditor(text: $m.text, language: .yaml, controller: m.editor, onChange: { _ in m.check() })
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                Text(m.result).font(.system(size: 12)).foregroundStyle(m.ok ? p.green : p.red)
                    .frame(minHeight: 16, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Text("What it adds to a stage, with its defaults:").font(.system(size: 11)).foregroundStyle(p.muted)
                ScrollView([.horizontal, .vertical]) {
                    Text(m.preview).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ e: PhaseAddinsModel.Entry) -> some View {
        let p = Theme.shared.p
        let active = m.currentFile == e.file
        return VStack(alignment: .leading, spacing: 1) {
            Text(e.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
            Text(e.sub).font(.system(size: 11)).foregroundStyle(e.bad ? p.red : p.muted).lineLimit(2)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(active ? p.accentDim : Color.clear))
        .contentShape(Rectangle())
        .help(e.file)
        .onTapGesture { m.select(e) }
    }
}
