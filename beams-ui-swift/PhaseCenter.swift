// PhaseCenter.swift
import AppKit
import SwiftUI

/// Phase state shared by the sidebar and the Phases window. Snapshots run
/// inside the beam (`tsh phase snapshot` uses the beam's own identity);
/// listing and deleting run here with the user's tsh login.
@MainActor
final class PhaseCenter: ObservableObject {
    static let shared = PhaseCenter()

    @Published private(set) var phases: [BeamPhase] = []
    @Published private(set) var loading = false
    @Published private(set) var snapshotting: Set<String> = []   // beam ids
    @Published var note = ""
    @Published var log: [String] = []

    static let maxLog = 2_000

    private init() {}

    func refresh(_ model: AppModel) async {
        if model.isMock {
            phases = [BeamPhase(name: "mock-base", locked: true), BeamPhase(name: "mock-web", parent: "mock-base")]
            note = "Simulated phases (BEAMSUI_MOCK=1)"
            return
        }
        // An expired certificate makes tsh start a login, so check first (as mcpList's callers do).
        guard model.tsh.loggedIn else { note = "Log in to Teleport first."; return }
        guard let tsh = model.client as? TshClient else { note = "Phases need the tsh backend."; return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            phases = try await tsh.phaseList().sorted { $0.name < $1.name }
            note = phases.isEmpty ? "No phases yet. Create one with `tsh phase add <name>` in Terminal (it opens a build console)." : ""
        } catch {
            note = ModelCatalog.clean(error.localizedDescription)
        }
    }

    func remove(_ phase: BeamPhase, _ model: AppModel) async {
        guard confirm("Delete phase “\(phase.name)”?",
                      "Beams already using it keep running until they expire. If a build is still open, finish it with tsh phase snapshot --final first, or its unsaved changes are lost.",
                      ok: "Delete Phase") else { return }
        guard let tsh = model.client as? TshClient else { return }
        do {
            try await tsh.phaseRemove(phase.name)
            model.toast("Deleted phase \(phase.name)", .ok)
        } catch {
            model.fail(error)
        }
        await refresh(model)
    }

    /// Saves the beam's /home to the phase it came from.
    func snapshot(_ beam: Beam, final: Bool, model: AppModel) async {
        guard !snapshotting.contains(beam.id), model.sshAllowed() else { return }
        if final {
            guard confirm("Save a final snapshot and delete \(beam.name)?",
                          "Everything in /home is saved to the beam's phase, then the beam is deleted. Anything outside /home is lost.",
                          ok: "Snapshot and Delete") else { return }
        }
        if model.isMock {
            model.toast("Simulated snapshot of \(beam.name)", .ok)
            return
        }
        snapshotting.insert(beam.id)
        defer { snapshotting.remove(beam.id) }
        append("── \(beam.name): tsh phase snapshot\(final ? " --final" : "")")
        do {
            let res = try await model.client.run(id: beam.id, script: PhaseScripts.snapshot(final: final), timeout: 900)
            let out = String(decoding: res.stdout, as: UTF8.self)
            out.split(separator: "\n").forEach { append(Shell.stripANSI(String($0))) }
            model.toast(final ? "Saved final snapshot; \(beam.name) is being deleted" : "Saved snapshot of \(beam.name)", .ok, seconds: 6)
            if final { await model.loadBeams() }
        } catch {
            let msg = ModelCatalog.clean(error.localizedDescription)
            append("error: \(msg)")
            if PhaseError.isLocked(msg) {
                model.toast("This beam's phase is locked because other phases are built on it. Fork it in Terminal: tsh phase add <new-name> --fork-from=<phase>", .err, seconds: 12)
            } else {
                model.noteSSHFailure(msg)
                model.fail(error)
            }
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    private func confirm(_ title: String, _ message: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// Window listing the cluster's phases, with the snapshot log.
struct PhasesWindow: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var center = PhaseCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Phases").font(.headline)
                Spacer()
                if center.loading { ProgressView().controlSize(.small) }
                Button { Task { await center.refresh(model) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh (tsh phase ls)")
            }
            .padding(10)
            Divider()
            List(center.phases) { p in
                HStack(spacing: 8) {
                    Image(systemName: p.locked ? "lock.fill" : "square.stack.3d.up").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.body.monospaced())
                        if !p.parent.isEmpty { Text("from \(p.parent)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if p.locked { Text("locked").font(.caption).foregroundStyle(.orange) }
                }
                .contextMenu {
                    Button("Copy Fork Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("tsh phase add \(p.name)-v2 --fork-from=\(p.name)", forType: .string)
                    }
                    Divider()
                    Button("Delete Phase…", role: .destructive) { Task { await center.remove(p, model) } }
                }
            }
            .listStyle(.inset)
            if !center.note.isEmpty {
                Text(center.note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(10)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(center.log.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption2.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await center.refresh(model) }
    }
}
