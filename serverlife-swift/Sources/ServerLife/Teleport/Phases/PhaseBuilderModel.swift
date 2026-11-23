import SwiftUI

/*
 * A Phase put together from setups — the dialog over PhaseSetups (phasebuilder.js).
 *
 * On the left, the stages of a phase.yaml in order: each either runs
 * commands (installing Go, Postgres, the AWS CLI…) or copies files from this
 * computer (a config folder, your dotfiles), and either kind can start
 * services in every Beam made from it. On the right, the phase.yaml those
 * make, checked as it changes with the rules tsh applies, so what is built is
 * exactly what is shown. Building it runs `tsh phase apply` in a tab, where
 * each stage's log streams; it can be saved as a file instead, or kept here
 * as a setup to start from next time (settings.phaseSetups).
 */
enum PhaseBuilderKinds {
    static let labels: [(value: String, label: String)] = [
        ("commands", "Install and run commands"), ("files", "Copy files from this computer"),
    ]
}

/// A saved setup (settings.phaseSetups): `{ name, stages, savedAt }`.
struct PhaseSavedSetup {
    var name: String
    var stages: [PhaseStage]
    @MainActor static func all() -> [PhaseSavedSetup] {
        (Store.shared.settingJSON("phaseSetups").items).map {
            PhaseSavedSetup(name: $0["name"].string ?? "", stages: ($0["stages"].items).map(PhaseStage.init(json:)))
        }
    }
}

/// A name for a new stage that is not taken by this dialog or the cluster.
func phaseFreshName(_ base: String?, _ taken: Set<String>) -> String {
    var clean = (base?.nilIfEmpty ?? "setup").lowercased()
        .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
    clean = String(clean.prefix(44))
    if clean.isEmpty { clean = "setup" }
    if !taken.contains(clean) { return clean }
    var i = 2
    while taken.contains("\(clean)-\(i)") { i += 1 }
    return "\(clean)-\(i)"
}

@MainActor
final class PhaseBuilderModel: ObservableObject {
    struct Last { var errors: [String] = []; var warnings: [String] = []; var incomplete: [String] = []; var yaml = ""; var names: [String] = [] }

    let profile: TeleportProfile
    let support: BeamAddSupport
    let from: String
    let phases: [BeamPhase]
    let taken: Set<String>
    @Published var catalog: [PhaseSetup]
    @Published var stages: [PhaseStage]
    @Published var setupName: String
    /// nil: the stages are the source; text: the hand-written phase.yaml is.
    @Published var handText: String?
    @Published var last = Last()
    /// Not-filled-in-yet messages (an empty stage, a blank required field) wait for a build or a save to be asked for.
    @Published var attempted = false
    @Published var region = ""
    @Published var stream = true
    private var timer: Task<Void, Never>?
    private var pickers: [String: PhasePickerModel] = [:]

    init(profile: TeleportProfile, support: BeamAddSupport, from: String, setup: PhaseSavedSetup?) {
        self.profile = profile; self.support = support; self.from = from
        phases = PhaseRuns.phases(profile)
        taken = Set(phases.map(\.name))
        catalog = PhaseSetupFiles.catalog()
        stages = setup?.stages ?? [PhaseStage(name: phaseFreshName(from.isEmpty ? "my-setup" : "\(from)-setup", Set(phases.map(\.name))),
                                              from: from, kind: "commands")]
        setupName = setup?.name ?? ""
        check()
    }

    func setup(_ id: String) -> PhaseSetup? { catalog.first { $0.id == id } }

    /// After My add-ins…: the list read again, so new and changed add-ins are offered at once.
    func reloadCatalog() { catalog = PhaseSetupFiles.catalog(); check() }

    /// Your Phase folders and a search (phasepicker.js), the default image first.
    func makeFromPicker(_ st: PhaseStage) -> PhasePickerModel {
        if let m = pickers[st.key] { return m }
        let key = st.key
        let m = PhasePickerModel(profile: profile, phases: phases.filter { $0.state == "ready" || $0.name == from },
                                 value: st.from, standard: "The default Beam image") { [weak self] v in
            guard let self, let i = self.stages.firstIndex(where: { $0.key == key }) else { return }
            self.stages[i].from = v; self.check()
        }
        pickers[key] = m
        return m
    }

    func check() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled else { return }
            self.runCheck()
        }
    }

    /// The latest check now, rather than one a keystroke behind.
    func runCheck() {
        if let hand = handText {
            let r = PhaseSetupFiles.checkHandYaml(hand)
            last = Last(errors: r.errors, warnings: r.warnings, incomplete: r.incomplete, yaml: hand, names: r.names)
            // The stages follow the text, so going back to setups carries it on.
            if r.parsed, let s = r.stages { stages = s }
        } else {
            let r = PhaseSetupFiles.build(stages)
            last = Last(errors: r.errors, warnings: r.warnings, incomplete: r.incomplete, yaml: r.yaml)
        }
    }

    var shownErrors: [String] {
        let pending = Set(attempted ? [] : last.incomplete)
        return last.errors.filter { !pending.contains($0) }
    }

    func addStage() {
        let prev = stages.last
        let names = taken.union(stages.map(\.name))
        stages.append(PhaseStage(name: phaseFreshName("\(prev?.name.nilIfEmpty ?? "stage")-next", names),
                                 kind: prev?.kind == "commands" ? "files" : "commands"))
        check()
    }

    func load(_ s: PhaseSavedSetup) { stages = s.stages; setupName = s.name; pickers = [:]; check() }

    func keep() {
        let name = (setupName.nilIfEmpty ?? stages.first?.name.nilIfEmpty ?? "setup").trimmed
        var others = (Store.shared.settingJSON("phaseSetups").items).filter { $0["name"].string != name }
        others.append(["name": .string(name), "stages": .array(stages.map(\.json)), "savedAt": .number(nowMs())])
        Store.shared.setSettingJSON("phaseSetups", .array(others))
        setupName = name
        PHStatus.toast("Kept \"\(name)\" — start from it next time with \"Start from a saved setup\"")
    }

    func enterHand() {
        handText = last.yaml
        check()
    }

    func leaveHand(window: WindowModel?) async {
        let r = PhaseSetupFiles.checkHandYaml(handText ?? "")
        if !r.parsed {
            guard await Modal.confirm(window, title: "Leave the hand-written text?",
                                      message: "It is not readable as phase.yaml yet, so the stages cannot follow it.",
                                      detail: r.errors.joined(separator: "\n"), ok: "Back to setups") else { return }
        }
        if r.parsed, let s = r.stages { stages = s; pickers = [:] }
        handText = nil
        check()
    }

    /// Open a phase.yaml…: carry on from one already written — a saved one, or one a build left in phase-setups/.
    func openFile(window: WindowModel?) async {
        let r: (file: String, text: String, stages: [PhaseStage], warnings: [String])?
        do { r = try await PhaseSetupFiles.open() } catch {
            PHStatus.toast((error as? AppError)?.message ?? PhaseSetups.firstLine(error), "error", ms: 8000); return
        }
        guard let r else { return }
        // Writing by hand: the file's own text, comments and all, into the editor.
        if handText != nil {
            handText = r.text; check()
            PHStatus.show("Opened \(r.file)", ms: 5000)
            return
        }
        if stages.contains(where: { !$0.setups.isEmpty }) {
            guard await Modal.confirm(window, title: "Replace these stages?",
                                      message: "Load \((r.file as NSString).lastPathComponent) in place of the stages here.",
                                      ok: "Load it") else { return }
        }
        stages = r.stages; setupName = ""; pickers = [:]
        check()
        PHStatus.show("Loaded \(r.stages.count) stage\(r.stages.count == 1 ? "" : "s") from \(r.file)", ms: 6000)
        if !r.warnings.isEmpty { PHStatus.toast(r.warnings.joined(separator: "\n"), "info", ms: 12000) }
    }
}
