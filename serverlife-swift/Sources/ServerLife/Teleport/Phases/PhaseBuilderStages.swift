import SwiftUI

/// One stage of the builder: its name, kind, the setups in it, and (first only) what it builds on.
struct PhaseStageCard: View {
    @ObservedObject var m: PhaseBuilderModel
    let index: Int

    var body: some View {
        let p = Theme.shared.p
        let st = m.stages[index]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Stage \(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                if m.stages.count > 1 {
                    Button("Remove stage") { m.stages.remove(at: index); m.check() }.buttonStyle(.ghost).controlSize(.small)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    label("Phase name")
                    TextField("lowercase-with-hyphens", text: Binding(get: { m.stages[safe: index]?.name ?? "" },
                                                                    set: { m.stages[index].name = $0.trimmed; m.check() }))
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 3) {
                    label("This stage")
                    Picker("", selection: Binding(get: { m.stages[safe: index]?.kind ?? "commands" },
                                                  set: { m.stages[index].kind = $0; m.check() })) {
                        ForEach(PhaseBuilderKinds.labels, id: \.value) { Text($0.label).tag($0.value) }
                    }.labelsHidden()
                }
            }
            if index == 0 {
                VStack(alignment: .leading, spacing: 3) {
                    label("Builds on")
                    PhasePickerView(m: m.makeFromPicker(st))
                    Text("Every later stage builds on the one before it.").font(.system(size: 11)).foregroundStyle(p.muted)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(st.setups.enumerated()), id: \.element.key) { j, use in block(j, use) }
            }.padding(.vertical, 6)
            addMenu(st)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(Theme.shared.p.textDim)
    }

    private func addMenu(_ st: PhaseStage) -> some View {
        let fits = m.catalog.filter { $0.stage == "any" || $0.stage == st.kind }
        var groups: [String] = []
        for s in fits where !groups.contains(s.group) { groups.append(s.group) }
        return Menu("Add a setup…") {
            ForEach(groups, id: \.self) { g in
                Section(g) {
                    ForEach(fits.filter { $0.group == g }) { s in
                        Button(s.label) { m.stages[index].setups.append(PhaseSetupUse(id: s.id)); m.check() }
                    }
                }
            }
        }.fixedSize()
    }

    @ViewBuilder private func block(_ j: Int, _ use: PhaseSetupUse) -> some View {
        let p = Theme.shared.p
        if let s = m.setup(use.id) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(s.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                    Spacer()
                    if j > 0 {
                        Button("↑") { m.stages[index].setups.swapAt(j - 1, j); m.check() }
                            .buttonStyle(.ghost).controlSize(.small).help("Run it earlier")
                    }
                    Button("✕") { m.stages[index].setups.remove(at: j); m.check() }
                        .buttonStyle(.ghost).controlSize(.small).help("Remove")
                }
                if !s.help.isEmpty { Text(s.help).font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true) }
                ForEach(s.fields, id: \.key) { f in
                    PhaseSetupFieldView(f: f, value: Binding(
                        get: { m.stages[safe: index]?.setups[safe: j]?.values[f.key] ?? f.defaultValue ?? "" },
                        set: { v in
                            guard index < m.stages.count, j < m.stages[index].setups.count else { return }
                            m.stages[index].setups[j].values[f.key] = v; m.check()
                        }))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
        } else {
            HStack(spacing: 6) {
                Text("\(use.id.replacingOccurrences(of: "^addin:", with: "", options: .regularExpression)) — this add-in is gone or has a problem (My add-ins…)")
                    .font(.system(size: 12)).foregroundStyle(p.red)
                Spacer()
                Button("✕") { m.stages[index].setups.remove(at: j); m.check() }.buttonStyle(.ghost).controlSize(.small)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border, style: StrokeStyle(lineWidth: 1, dash: [3])))
        }
    }
}

/// One field of a setup, bound to `values[key]`.
struct PhaseSetupFieldView: View {
    let f: PhaseSetupField
    @Binding var value: String

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 3) {
            Text(f.kind == "select" || f.kind == "yaml" || f.required ? f.label : f.label + " (optional)")
                .font(.system(size: 11)).foregroundStyle(p.textDim)
            switch f.kind {
            case "select":
                Picker("", selection: $value) { ForEach(f.options ?? [], id: \.self) { Text($0).tag($0) } }.labelsHidden()
            case "yaml":
                // Colour-coded, as the phase.yaml beside it is.
                CodeEditor(text: $value, language: .yaml).frame(height: 170)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            case "textarea", "paths":
                TextEditor(text: $value).font(.system(size: 12, design: .monospaced))
                    .frame(height: f.kind == "paths" ? 52 : 68)
                    .overlay(alignment: .topLeading) {
                        if value.isEmpty && !f.placeholder.isEmpty {
                            Text(f.placeholder).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
            default:
                TextField(f.placeholder, text: $value).textFieldStyle(.roundedBorder)
            }
            if f.kind == "path" || f.kind == "paths" {
                // Browse for a file or a folder; a list takes another line each time.
                HStack(spacing: 6) {
                    Button("File…") {
                        Task { @MainActor in add(await Modal.openFiles(multiple: false, title: f.label).first?.path) }
                    }.buttonStyle(.ghost).controlSize(.small)
                    Button("Folder…") {
                        Task { @MainActor in add(await Modal.chooseDirectory(title: f.label)?.path) }
                    }.buttonStyle(.ghost).controlSize(.small)
                }
            }
        }
    }

    private func add(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        value = f.kind == "paths" ? [value.trimmed, path].filter { !$0.isEmpty }.joined(separator: "\n") : path
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
