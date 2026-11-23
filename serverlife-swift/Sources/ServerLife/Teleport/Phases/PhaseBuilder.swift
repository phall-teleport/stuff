import SwiftUI

/// The builder dialog (phasebuilder.js `openPhaseBuilder`).
@MainActor
enum PhaseBuilder {
    struct Answer { var region: String?; var noConsole: Bool; var thenInteractive: Bool }

    /// Open the builder. `from` starts the first stage on an existing Phase;
    /// `setup` is a saved one to start from.
    static func open(_ p: TeleportProfile, from: String? = nil, setup: PhaseSavedSetup? = nil, window: WindowModel?,
                     support: BeamAddSupport? = nil) {
        Task { @MainActor in _ = await run(p, from: from ?? "", setup: setup, window: window, support: support) }
    }

    @discardableResult
    static func run(_ p: TeleportProfile, from: String, setup: PhaseSavedSetup?, window: WindowModel?,
                    support known: BeamAddSupport? = nil) async -> Bool {
        var support = BeamAddSupport()
        if let known { support = known } else { support = await Beams.addSupport(proxy: p.proxy, home: p.homeDir) }
        if !support.apply {
            PHStatus.toast("This tsh has no `tsh phase apply` — update tsh (or let the cluster pick its version) to build Phases from setups",
                           "error", ms: 9000)
            return false
        }
        let m = PhaseBuilderModel(profile: p, support: support, from: from, setup: setup)
        let res: Answer? = await withCheckedContinuation { cont in
            var done = false
            let finish: (Answer?) -> Void = { v in if !done { done = true; cont.resume(returning: v) } }
            let sub = p.cluster.nilIfEmpty ?? p.proxy
            let h = Modal.sheet(window, title: "Build a Phase from setups", width: 1220, height: 820, resizable: true,
                                autosave: "phase-builder") { handle in
                DialogScaffold(title: "Build a Phase from setups", subtitle: sub, scroll: false) {
                    PhaseBuilderBody(m: m, window: window)
                } footer: {
                    Spacer()
                    Button("Cancel") { finish(nil); handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                    Button("Keep this setup") { m.keep() }.buttonStyle(.ghost)
                    Button("Save phase.yaml…") { Task { @MainActor in await saveYaml(m, window: window) } }.buttonStyle(.ghost)
                    /*
                     * Command and copy stages are not worked in by hand; an interactive
                     * Phase on top of them is — a build console with everything the
                     * stages installed, saved with tsh phase snapshot.
                     */
                    Button("Build it, then work in it\u{2026}") {
                        Task { @MainActor in if let a = await startBuild(m, true, window: window) { finish(a); handle.close() } }
                    }.buttonStyle(.ghost)
                        .help("tsh phase apply, then New Phase on top of the last stage: an interactive build console you can save")
                    Button("Build it") {
                        Task { @MainActor in if let a = await startBuild(m, false, window: window) { finish(a); handle.close() } }
                    }.buttonStyle(.primary)
                }
            }
            h.onClose.append { finish(nil) }
        }
        guard let res else { return false }
        let written: PhaseSetupFiles.Written
        do {
            written = m.handText != nil ? try PhaseSetupFiles.write(stages: [], handText: m.handText)
                                        : try PhaseSetupFiles.write(stages: m.stages)
        } catch let e as PhaseWriteError {
            PHStatus.toast(e.errors.first ?? "Could not write the phase.yaml", "error"); return false
        } catch { PHStatus.toast(error.localizedDescription, "error"); return false }
        let args: [String]
        do { args = try Beams.phaseApplyArgs(proxy: p.proxy, file: written.file, noConsole: res.noConsole, region: res.region) }
        catch { PHStatus.toast(error.localizedDescription, "error"); return false }
        let lastStage = written.stages.last ?? ""
        let ok = await PhaseRuns.runPhaseBuild(p, PhaseRuns.run(p, args), title: "Phase apply · \(written.stages.joined(separator: " → "))",
                                               meta: ["kind": "apply", "name": .string(lastStage), "mode": "apply",
                                                      "commandsFile": .string(written.file), "stages": PhaseBuildMeta.strs(written.stages),
                                                      "region": .string(res.region ?? "")], window: window)
        Task { await BeamPhaseLists.shared.refreshPhases(p) }
        // On to the interactive part once the stages are saved: New Phase, built on the last one.
        if ok && res.thenInteractive { return await PhaseRuns.newPhase(p, mode: "from", source: lastStage, window: window) }
        if !ok && res.thenInteractive {
            PHStatus.toast("The setup did not finish building, so there is nothing to work in yet — the tab has its log", "error", ms: 9000)
        }
        return ok
    }

    private static func saveYaml(_ m: PhaseBuilderModel, window: WindowModel?) async {
        m.attempted = true
        let text = m.handText ?? m.last.yaml
        if text.isEmpty { return }
        if let u = await Modal.saveText(window, text, defaultName: "\(m.stages.first?.name.nilIfEmpty ?? "phase").yaml", title: "Save phase.yaml") {
            PHStatus.show("Saved \(u.path) — build it with tsh phase apply -f \(u.path)", ms: 8000)
        }
    }

    private static func startBuild(_ m: PhaseBuilderModel, _ thenInteractive: Bool, window: WindowModel?) async -> Answer? {
        m.attempted = true
        // Wait for the latest check rather than one a keystroke behind.
        m.runCheck()
        if let first = m.last.errors.first { PHStatus.toast(first, "error", ms: 7000); return nil }
        let existing = (m.handText != nil ? m.last.names : m.stages.map(\.name)).filter { m.taken.contains($0) }
        if !existing.isEmpty {
            guard await Modal.confirm(window, title: "Replace \(existing.joined(separator: ", "))?",
                                      message: "Applying a stage whose name is already a Phase replaces its commands or files, and rebuilds it.",
                                      detail: "Its parent and kind must stay the same; tsh refuses otherwise.",
                                      ok: "Replace and build") else { return nil }
        }
        return Answer(region: m.region.nilIfEmpty, noConsole: m.support.noConsole ? !m.stream : false, thenInteractive: thenInteractive)
    }
}
