// Sources/Beams/Views/PhaseCenter.swift
import AppKit
import SwiftUI

/// Fields for a new phase (no @State; see LocalState.swift).
final class PhaseDraft: ObservableObject {
    enum Base: String, CaseIterable { case fresh = "Fresh", from = "Build on", fork = "Fork" }
    @Published var name = ""
    @Published var base: Base = .fresh
    @Published var basePhase = ""
    @Published var openSession = true

    func reset() { name = ""; base = .fresh; basePhase = "" }
}

/// Phase state shared by the sidebar and the Phases window. Snapshots and
/// forks run inside the build beam; listing, creating and deleting run here
/// with the user's tsh login.
@MainActor
final class PhaseCenter: ObservableObject {
    static let shared = PhaseCenter()

    @Published private(set) var phases: [BeamPhase] = []
    @Published private(set) var loading = false
    @Published private(set) var creating = false
    @Published private(set) var snapshotting: Set<String> = []   // beam ids
    @Published private(set) var startingFrom: Set<String> = []   // phase names
    @Published var note = ""
    @Published var log: [String] = []

    /// Phase name → build beam uuid, from `phase add` output this run
    /// (`phase ls` doesn't report the build beam).
    private var knownBuilds: [String: String] = [:]

    static let maxLog = 2_000

    private init() {}

    func refresh(_ model: AppModel) async {
        if model.isMock {
            phases = BeamPhase.markLocked([BeamPhase(name: "mock-base"),
                                           BeamPhase(name: "mock-web", parent: "mock-base", raw: ["state": "building"])])
            note = "Simulated phases (BEAMSUI_MOCK=1)"
            return
        }
        guard model.tsh.loggedIn else { note = "Log in to Teleport first."; return }
        guard let tsh = model.client as? TshClient else { note = "Phases need the tsh backend."; return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            phases = try await tsh.phaseList().sorted { $0.name < $1.name }
            note = phases.isEmpty ? "No phases yet. Create one above." : ""
        } catch {
            note = ModelCatalog.clean(error.localizedDescription)
        }
    }

    /// The phase this beam is building, if it's a build beam. Matches the uuid
    /// remembered from `phase add`, else the build beam id pattern
    /// `<phase>-<first 8 of uuid>` (e.g. "x-af775672") for building phases.
    func buildPhase(for beam: Beam) -> BeamPhase? {
        let uuid = beam.raw["uuid"] ?? ""
        guard !uuid.isEmpty else { return nil }
        if let p = phases.first(where: { knownBuilds[$0.name] == uuid || $0.raw["build_beam"] == uuid }) { return p }
        return phases.first { $0.isBuilding && beam.id == "\($0.name)-\(uuid.prefix(8))" }
    }

    /// `tsh phase add --no-console`: provisions a build beam, then (optionally)
    /// opens a session in it so the agent can set it up before a snapshot.
    func create(_ draft: PhaseDraft, model: AppModel) async {
        guard !creating else { return }
        let name = BeamPhase.safeName(draft.name)
        let base = BeamPhase.safeRef(draft.basePhase)
        let kind = draft.base
        let openSession = draft.openSession
        if kind != .fresh && base.isEmpty { model.toast("Pick a phase to \(kind == .fork ? "fork" : "build on").", .err); return }
        if model.isMock { model.toast("Simulated phase \(name.isEmpty ? "(generated)" : name)", .ok); draft.reset(); return }
        guard model.tsh.loggedIn, let tsh = model.client as? TshClient else { model.toast("Log in to Teleport first.", .err); return }

        creating = true
        defer { creating = false }
        append("── tsh phase add \(name.isEmpty ? "(generated name)" : name)\(kind == .from ? " --from=\(base)" : kind == .fork ? " --fork-from=\(base)" : "")")
        do {
            let build = try await tsh.phaseAdd(name: name,
                                               from: kind == .from ? base : "",
                                               forkFrom: kind == .fork ? base : "")
            if !build.buildBeam.isEmpty { knownBuilds[build.name] = build.buildBeam }
            append("phase \(build.name) · build beam \(build.buildBeam.isEmpty ? "unknown" : build.buildBeam)")
            if let out = build.raw["output"] { out.split(separator: "\n").forEach { append(String($0)) } }
            draft.reset()
            await model.loadBeams()
            await refresh(model)
            if let beam = findBeam(build.buildBeam, in: model) {
                model.toast("Phase \(build.name) is building in \(beam.name). Set it up, then save a snapshot.", .ok, seconds: 8)
                if openSession { await model.startSession(on: beam) }
            } else {
                model.toast("Phase \(build.name) created; its build beam will appear after a refresh.", .ok, seconds: 8)
            }
        } catch {
            append("error: \(ModelCatalog.clean(error.localizedDescription))")
            model.fail(error)
        }
    }

    /// `tsh beams add --phase`: an ordinary beam with the phase's latest /home,
    /// then a session in it.
    func startBeam(from phase: BeamPhase, model: AppModel) async {
        guard !startingFrom.contains(phase.name) else { return }
        if model.isMock { model.toast("Simulated beam from phase \(phase.name)", .ok); return }
        guard model.tsh.loggedIn, let tsh = model.client as? TshClient else { model.toast("Log in to Teleport first.", .err); return }

        startingFrom.insert(phase.name)
        defer { startingFrom.remove(phase.name) }
        append("── tsh beams add --phase=\(phase.name)")
        do {
            let id = try await tsh.beamAddFromPhase(phase.name)
            append("beam \(id)")
            await model.loadBeams()
            if let beam = findBeam(id, in: model) {
                model.toast("Started \(beam.name) from phase \(phase.name)", .ok, seconds: 6)
                await model.startSession(on: beam)
            } else {
                model.toast("Beam \(id) started from \(phase.name); it will appear after a refresh.", .ok, seconds: 8)
            }
        } catch {
            append("error: \(ModelCatalog.clean(error.localizedDescription))")
            model.fail(error)
        }
    }

    func remove(_ phase: BeamPhase, _ model: AppModel) async {
        guard confirm("Delete phase “\(phase.name)”?",
                      "Beams already using it keep running until they expire. If a build is still open, finish it with a final snapshot first, or its unsaved changes are lost.",
                      ok: "Delete Phase") else { return }
        if model.isMock { model.toast("Simulated delete of \(phase.name)", .ok); return }
        guard let tsh = model.client as? TshClient else { return }
        do {
            try await tsh.phaseRemove(phase.name)
            knownBuilds[phase.name] = nil
            model.toast("Deleted phase \(phase.name)", .ok)
        } catch {
            model.fail(error)
        }
        await refresh(model)
    }

    /// Saves the build beam's /home to its phase.
    func snapshot(_ beam: Beam, final: Bool, model: AppModel) async {
        guard !snapshotting.contains(beam.id), model.sshAllowed() else { return }
        if final {
            guard confirm("Save a final snapshot and delete \(beam.name)?",
                          "Everything in /home is saved to the beam's phase, then the beam is deleted. Anything outside /home is lost.",
                          ok: "Snapshot and Delete") else { return }
        }
        if model.isMock { model.toast("Simulated snapshot of \(beam.name)", .ok); return }
        snapshotting.insert(beam.id)
        defer { snapshotting.remove(beam.id) }
        append("── \(beam.name): tsh phase snapshot\(final ? " --final" : "")")
        do {
            let res = try await model.client.run(id: beam.id, script: PhaseScripts.snapshot(final: final), timeout: 900)
            String(decoding: res.stdout, as: UTF8.self).split(separator: "\n").forEach { append(Shell.stripANSI(String($0))) }
            model.toast(final ? "Saved final snapshot; \(beam.name) is being deleted" : "Saved snapshot of \(beam.name)", .ok, seconds: 6)
            if final { await model.loadBeams() }
            await refresh(model)
        } catch {
            let msg = ModelCatalog.clean(error.localizedDescription)
            append("error: \(msg)")
            if PhaseError.isLocked(msg) {
                await offerFork(beam, model: model)
            } else {
                model.noteSSHFailure(msg)
                model.fail(error)
            }
        }
    }

    /// A locked phase takes no snapshots; `tsh phase add <new> --fork` in the
    /// build beam captures its filesystem as a new phase instead.
    private func offerFork(_ beam: Beam, model: AppModel) async {
        guard let newName = promptName("This beam's phase is locked",
                                       "Other phases are built on it, so it can't take new snapshots. Fork this beam's filesystem into a new phase instead?",
                                       placeholder: "my-phase-v2"),
              !BeamPhase.safeName(newName).isEmpty else { return }
        snapshotting.insert(beam.id)
        defer { snapshotting.remove(beam.id) }
        append("── \(beam.name): tsh phase add \(BeamPhase.safeName(newName)) --fork")
        do {
            let res = try await model.client.run(id: beam.id, script: PhaseScripts.fork(newName: newName), timeout: 900)
            String(decoding: res.stdout, as: UTF8.self).split(separator: "\n").forEach { append(Shell.stripANSI(String($0))) }
            model.toast("Forked \(beam.name) into phase \(BeamPhase.safeName(newName))", .ok, seconds: 6)
            await model.loadBeams()
            await refresh(model)
        } catch {
            append("error: \(ModelCatalog.clean(error.localizedDescription))")
            model.fail(error)
        }
    }

    /// tsh reports beams by id ("x-af775672") or uuid; match either.
    private func findBeam(_ ref: String, in model: AppModel) -> Beam? {
        guard !ref.isEmpty else { return nil }
        return model.beams.first { $0.id == ref || $0.name == ref || $0.raw["id"] == ref || $0.raw["uuid"] == ref }
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

    private func promptName(_ title: String, _ message: String, placeholder: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        a.accessoryView = field
        a.addButton(withTitle: "Fork")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// Window listing the cluster's phases, a form to create one, and the log.
struct PhasesWindow: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var center = PhaseCenter.shared
    @StateObject private var draft = PhaseDraft()

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
            newPhaseForm.padding(10)
            Divider()
            List(center.phases) { p in
                PhaseRow(phase: p, starting: center.startingFrom.contains(p.name)) {
                    Task { await center.startBeam(from: p, model: model) }
                }
                .contextMenu {
                    Button("New Beam from This Phase") { Task { await center.startBeam(from: p, model: model) } }
                        .disabled(center.startingFrom.contains(p.name))
                    Divider()
                    Button("Build a New Phase on This") { draft.base = .from; draft.basePhase = p.name }
                    Button("Fork This Phase") { draft.base = .fork; draft.basePhase = p.name; draft.name = "\(p.name)-v2" }
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
        .frame(minWidth: 560, minHeight: 520)
        .task { await center.refresh(model) }
    }

    private var newPhaseForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New phase").font(.subheadline.weight(.semibold))
            TextField("Name (optional; generated if empty)", text: $draft.name)
                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
            Picker("Start", selection: $draft.base) {
                ForEach(PhaseDraft.Base.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if draft.base != .fresh {
                Picker(draft.base == .fork ? "Phase to fork" : "Base phase", selection: $draft.basePhase) {
                    Text("Choose…").tag("")
                    ForEach(center.phases) { p in Text(p.name).tag(p.name) }
                }
            }
            Toggle("Open a session in the build beam", isOn: $draft.openSession)
            Text("Creates a build beam. Set it up (or let the agent do it), then right-click the beam → Save Snapshot. Snapshots save everything in /home, including .env files and other credentials there.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await center.create(draft, model: model) }
            } label: {
                if center.creating { ProgressView().controlSize(.small) } else { Text("Create Phase") }
            }
            .buttonStyle(.borderedProminent).disabled(center.creating)
        }
    }
}

/// One phase: name, parent, state, lock and a "New Beam" button.
private struct PhaseRow: View {
    let phase: BeamPhase
    let starting: Bool
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: phase.locked ? "lock.fill" : phase.isBuilding ? "hammer" : "square.stack.3d.up")
                .foregroundStyle(phase.isBuilding ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(phase.name).font(.body.monospaced())
                if !phase.parent.isEmpty { Text("from \(phase.parent)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if phase.locked {
                Text("locked").font(.caption).foregroundStyle(.orange)
            } else if !phase.state.isEmpty {
                Text(phase.state).font(.caption).foregroundStyle(phase.isBuilding ? .blue : .secondary)
            }
            Button(action: onStart) {
                if starting { ProgressView().controlSize(.small) } else { Text("New Beam") }
            }
            .disabled(starting)
            .help("tsh beams add --phase=\(phase.name), then open a session in it")
        }
    }
}
