import AppKit
import SwiftUI

extension PhaseRuns {
    /**
     * Save, or save and finish, a Phase's running build — `tsh phase snapshot`
     * inside its build Beam. Whether it was saved is read back from the Phase,
     * since --final ends the Beam the command ran in.
     */
    @discardableResult
    static func snapshotBuild(_ p: TeleportProfile, _ phase: BeamPhase, final: Bool = false, force: Bool = false,
                              window: WindowModel?) async -> Bool {
        if phase.buildBeam.isEmpty { PHStatus.toast("\(phase.name) has no build running", "error"); return false }
        if final, !(await Modal.confirm(window, title: "Save \(phase.name) and end its build?",
                                         message: "Saves a snapshot, then ends the build Beam. Anything changed after the snapshot is lost.",
                                         detail: force ? "Changes outside /home are left out of the snapshot."
                                             : "If it changed files outside /home, it refuses and nothing is saved.",
                                         ok: "Save and finish")) { return false }
        PHStatus.show("\(final ? "Saving and finishing" : "Saving") \(phase.name)…", ms: 60000)
        let before = phase.publishedAt ?? 0
        let r: TshOutput
        do { r = try await Beams.phaseSnapshot(beam: phase.buildBeam, proxy: p.proxy, home: p.homeDir, final: final, force: force) }
        catch { r = TshOutput(ok: false, output: error.localizedDescription) }
        await BeamPhaseLists.shared.refreshPhases(p)
        let now = phases(p).first { $0.name == phase.name }
        if (now?.publishedAt ?? 0) > before || (r.ok && !final) {
            PHStatus.toast("Saved \(phase.name)\(final ? " and ended its build" : "")", "success", ms: 8000)
            return true
        }
        // The usual refusal: files changed outside /home. Offer the way past it.
        if !force, r.output.range(of: "outside /home|--force", options: [.regularExpression, .caseInsensitive]) != nil {
            if await Modal.confirm(window, title: "Changes outside /home",
                                   message: "The snapshot was refused because files outside /home changed.",
                                   detail: String(r.output.suffix(1200)), ok: "Save without them (--force)") {
                return await snapshotBuild(p, phase, final: final, force: true, window: window)
            }
            return false
        }
        PHStatus.toast("Not saved: \(String((r.output.nilIfEmpty ?? "tsh phase snapshot said nothing").suffix(600)))", "error", ms: 15000)
        return false
    }

    /**
     * Replace what a command or copy Phase is built from: a new command file
     * (`tsh phase edit --commands-file`), or its files copied again
     * (`--copy`). Either rebuilds it; its children follow.
     */
    @discardableResult
    static func replacePhaseInputs(_ p: TeleportProfile, _ phase: BeamPhase, window: WindowModel?) async -> Bool {
        var commandsFile = ""
        var copies: [PhaseCopy] = []
        if phase.strategy == "copy" {
            guard let rows = await askCopies(phase.name, window: window), !rows.isEmpty else { return false }
            copies = rows
        } else {
            guard let f = await Modal.openFiles(multiple: false, title: "A new command file for \(phase.name) (YAML)").first
            else { return false }
            commandsFile = f.path
        }
        let args: [String]
        do { args = try Beams.phaseEditArgs(proxy: p.proxy, name: phase.name, commandsFile: commandsFile, copies: copies) }
        catch { PHStatus.toast(error.localizedDescription, "error"); return false }
        return await runPhaseBuild(p, run(p, args), title: "Phase edit · \(phase.name)",
                                   meta: ["kind": "edit", "name": .string(phase.name), "mode": "edit",
                                          "commandsFile": .string(commandsFile), "copies": PhaseBuildMeta.copies(copies)],
                                   window: window)
    }

    private static func askCopies(_ name: String, window: WindowModel?) async -> [PhaseCopy]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[PhaseCopy]?, Never>) in
            var done = false
            let finish: ([PhaseCopy]?) -> Void = { v in if !done { done = true; cont.resume(returning: v) } }
            let m = PhaseCopyRows(blank: true)
            let h = Modal.sheet(window, title: "Copy files into \(name) again", width: 620) { handle in
                DialogScaffold(title: "Copy files into \(name) again", width: 620) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The new copy starts from its parent, not from the files it has now: list every file it should keep.")
                            .font(.system(size: 11)).foregroundStyle(Theme.shared.p.muted)
                        PhaseCopyRowsView(m: m, browse: false)
                    }
                } footer: {
                    Spacer()
                    Button("Cancel") { finish(nil); handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                    Button("Copy and rebuild") { finish(m.copies); handle.close() }.buttonStyle(.primary)
                }
            }
            h.onClose.append { finish(nil) }
        }
    }
}

/// Copied files: local source and where it goes, one row each.
@MainActor
final class PhaseCopyRows: ObservableObject {
    struct Row: Identifiable { let id = UUID(); var from = ""; var to = "" }
    @Published var rows: [Row] = []
    init(blank: Bool) { if blank { rows = [Row()] } }
    var copies: [PhaseCopy] {
        rows.map { PhaseCopy(from: $0.from.trimmed, to: $0.to.trimmed) }.filter { !$0.from.isEmpty || !$0.to.isEmpty }
    }
}

struct PhaseCopyRowsView: View {
    @ObservedObject var m: PhaseCopyRows
    var browse = true
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($m.rows) { $row in
                HStack(spacing: 6) {
                    TextField(browse ? "/local/path/config" : "/local/path", text: $row.from).textFieldStyle(.roundedBorder)
                    TextField("/opt/app/config", text: $row.to).textFieldStyle(.roundedBorder)
                    if browse {
                        Button("Browse…") {
                            let id = row.id
                            Task { @MainActor in
                                if let f = await Modal.openFiles(multiple: false, title: "A file to copy into the Phase").first,
                                   let i = m.rows.firstIndex(where: { $0.id == id }) {
                                    m.rows[i].from = f.path; onChange()
                                }
                            }
                        }.buttonStyle(.ghost).controlSize(.small)
                        Button("✕") { m.rows.removeAll { $0.id == row.id }; onChange() }.buttonStyle(.ghost).controlSize(.small)
                    }
                }
                .onChange(of: row.from) { _, _ in onChange() }
                .onChange(of: row.to) { _, _ in onChange() }
            }
            Button("+ Another file") { m.rows.append(.init()); onChange() }.buttonStyle(.ghost).controlSize(.small)
        }
    }
}
