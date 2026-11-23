import SwiftUI

/// The builder's two halves: stages on the left, the phase.yaml and its problems on the right.
struct PhaseBuilderBody: View {
    @ObservedObject var m: PhaseBuilderModel
    weak var window: WindowModel?

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
            let left = (geo.size.width - 12) * 1.1 / 2.1
            HStack(alignment: .top, spacing: 12) {
                stagesPane.frame(width: left)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("phase.yaml").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                        Spacer()
                        Button(m.handText == nil ? "Edit by hand" : "Back to setups") {
                            if m.handText == nil { m.enterHand() } else { Task { @MainActor in await m.leaveHand(window: window) } }
                        }
                        .buttonStyle(.ghost).controlSize(.small)
                        .help("Write the phase.yaml yourself — anything tsh phase apply takes; built and saved as you write it")
                    }
                    yamlBox
                    problems
                }.frame(width: max(0, geo.size.width - 12 - left))
            }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text("Region").font(.system(size: 12)).foregroundStyle(p.textDim)
                    Picker("", selection: $m.region) {
                        ForEach(BeamsUI.regions, id: \.value) { Text($0.label).tag($0.value) }
                    }.labelsHidden().fixedSize()
                }
                if m.support.noConsole { Toggle("Stream each stage\u{2019}s log in the tab", isOn: $m.stream).toggleStyle(.checkbox) }
                Spacer()
            }
        }
        .padding(.top, 4)
    }

    /*
     * The phase.yaml, colour-coded. Normally a view of what the stages on the
     * left make; with *Edit by hand* the text itself is what is built — typed
     * here, checked as it changes, and read back into the stages on the left,
     * which wait (dimmed) until *Back to setups*. Built and saved exactly as
     * typed, comments and all.
     */
    @ViewBuilder private var yamlBox: some View {
        Group {
            if m.handText != nil {
                CodeEditor(text: Binding(get: { m.handText ?? "" }, set: { m.handText = $0; m.check() }), language: .yaml)
            } else {
                YamlView(text: m.last.yaml)
            }
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.shared.p.border))
    }

    private var problems: some View {
        let p = Theme.shared.p
        let errors = m.shownErrors
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(errors.enumerated()), id: \.offset) { Text("✕ " + $0.element).foregroundStyle(p.red) }
                ForEach(Array(m.last.warnings.enumerated()), id: \.offset) { Text("⚠ " + $0.element).foregroundStyle(p.amber) }
                if m.last.errors.isEmpty {
                    Text("✓ tsh phase apply will accept this").foregroundStyle(p.green)
                } else if errors.isEmpty {
                    Text(m.handText != nil ? "Keep writing — a stage needs a name, and commands: or files:." : "Add a setup to begin.")
                        .foregroundStyle(p.muted)
                }
            }
            .font(.system(size: 12)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
    }

    private var stagesPane: some View {
        let p = Theme.shared.p
        let saved = PhaseSavedSetup.all()
        let hand = m.handText != nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // A saved setup to start from instead of what is on screen.
                if !saved.isEmpty {
                    Menu("Start from a saved setup…") {
                        ForEach(Array(saved.enumerated()), id: \.offset) { _, s in Button(s.name) { m.load(s) } }
                    }.fixedSize().disabled(hand)
                }
                Text("Each stage is its own Phase. Commands run as root and run again whenever the stage refreshes (daily, and when the one below it changes); copied files go outside /home; services start in every Beam made from it.")
                    .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                if hand {
                    Text("Editing phase.yaml by hand — the stages below follow the text. Back to setups to change them here.")
                        .font(.system(size: 11)).foregroundStyle(p.accent).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(m.stages.enumerated()), id: \.element.key) { i, _ in PhaseStageCard(m: m, index: i) }
                }
                .opacity(hand ? 0.55 : 1).allowsHitTesting(!hand)
                HStack(spacing: 6) {
                    Button("+ Add a stage") { m.addStage() }.buttonStyle(.ghost).controlSize(.small).disabled(hand)
                        .help("Another Phase built on the one above — for example files after the tools, or services after both")
                    Button("Open a phase.yaml\u{2026}") { Task { @MainActor in await m.openFile(window: window) } }
                        .buttonStyle(.ghost).controlSize(.small)
                        .help("Load an existing phase.yaml as these stages, to change and build again")
                    Button("My add-ins\u{2026}") {
                        Task { @MainActor in if await PhaseAddins.open(window: window) { m.reloadCatalog() } }
                    }
                    .buttonStyle(.ghost).controlSize(.small)
                    .help("Setups of your own — a YAML file each, in a folder you can share")
                }
            }
            .padding(.trailing, 4)
        }
    }
}
