import SwiftUI
import AppKit
import Foundation

@main
struct BeamsApp: App {
    // The App value lives for the whole process, so a plain stored model is
    // fine here (and avoids the @State macro, see LocalState.swift).
    private let model: AppModel

    init() {
        do {
            model = try AppModel()
        } catch {
            // Application Support isn't writable; nothing sensible to show.
            fatalError("Beams could not open its data directory: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("Beams") {
            ContentView()
                .environment(model)
                // Below ~990pt the sidebar + main column + inspector don't fit and
                // the split view's layout feeds back on itself until AppKit throws
                // (reproduced offscreen with Tests/BeamsTests/LayoutProbe.swift).
                // 1040 leaves a margin.
                .frame(minWidth: 1040, minHeight: 600)
                .task { await model.boot() }
        }
        // Standard unified title bar: without it (.hiddenTitleBar) the detail
        // ScrollView renders up into the title-bar area and overlaps the toolbar.
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Beam") { Task { await model.createBeam() } }.keyboardShortcut("n")
                Button("Refresh Beams") { Task { await model.loadBeams() } }.keyboardShortcut("r")
                OpenPhasesCommand()
                Divider()
                Button("Open Previous Session from GitHub…") { model.openFromGitHub() }.keyboardShortcut("o")
            }
            CommandMenu("Session") {
                Button("Stop Turn") { model.stop() }.keyboardShortcut(".", modifiers: .command).disabled(!model.currentBusy)
                Divider()
                Button("Save Work Folder to Mac") { Task { await model.saveWorkFolder() } }
                    .keyboardShortcut("s").disabled(model.current == nil)
                Button("Save Work Folder To…") { Task { await model.saveWorkFolder(choose: true) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.current == nil)
                Divider()
                Button("Sync Beam Session to GitHub") { Task { await model.syncNow() } }.disabled(model.current == nil)
                Divider()
                Button("Toggle Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        // One window per beam: its beam-init services and their logs.
        WindowGroup("Services", id: "services", for: String.self) { $beamID in
            ServicesWindow(beamID: beamID ?? "").environment(model)
        }
        .defaultSize(width: 980, height: 620)

        // The cluster's Phase images (tsh phase ls) and the snapshot log.
        Window("Phases", id: "phases") {
            PhasesWindow().environment(model)
        }
        .defaultSize(width: 620, height: 560)

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Menu item that opens the Phases window (`openWindow` needs a view).
private struct OpenPhasesCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Phases…") { openWindow(id: "phases") }.keyboardShortcut("p", modifiers: [.command, .shift])
    }
}

// MARK: - Phase: CLI models and arguments

/// One-line error text without terminal color codes (tsh colors its ERROR prefix).
/// `\x{1B}` is the regex engine's spelling of ESC; `\u{1B}` in a raw string never matches.
enum PhaseText {
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A tsh client version, e.g. from "Teleport v18.11.9 git:v18.11.9-0-g… go1.24".
struct TshVersion: Comparable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    /// `tsh phase` and `tsh beams add --phase` need this or newer.
    static let phaseMinimum = TshVersion(major: 18, minor: 11, patch: 9)

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (a: TshVersion, b: TshVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    /// The client version from `tsh version` output. When logged in, tsh also
    /// prints "Proxy version: …", so the "Teleport v…" line is preferred.
    static func parse(_ text: String) -> TshVersion? {
        let lines = text.split(separator: "\n").map(String.init)
        let line = lines.first { $0.contains("Teleport v") }
            ?? lines.first { !$0.lowercased().contains("proxy") }
            ?? text
        guard let r = line.range(of: #"v?\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        let parts = line[r].trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TshVersion(major: parts[0], minor: parts[1], patch: parts[2])
    }
}

/// A Phase image from `tsh phase ls -f json`. Verified row shape:
/// `{"name","owner","strategy","parent","state","region","roles"}`, where
/// `parent` is a reference like "default:v1" and `state` is e.g. "building".
/// Rows have no lock flag and no build beam.
struct BeamPhase: Identifiable, Hashable {
    var name: String
    /// The phase this one was built on, e.g. "default:v1".
    var parent: String = ""
    /// Other phases are built on it, so it takes no new snapshots (fork instead).
    var locked: Bool = false
    /// Every scalar field from the listing.
    var raw: [String: String] = [:]
    var id: String { name }

    var state: String { raw["state"] ?? "" }
    var isBuilding: Bool { state == "building" }

    /// JSON rows (flat, or Teleport-resource style). `null` parses to [].
    static func parse(_ json: Any) -> [BeamPhase] {
        let rows: [[String: Any]]
        if let a = json as? [[String: Any]] { rows = a }
        else if let d = json as? [String: Any], let a = (d["phases"] ?? d["items"]) as? [[String: Any]] { rows = a }
        else { return [] }
        let phases: [BeamPhase] = rows.compactMap { row in
            let flat = PhaseJSON.flatten(row)
            guard let name = flat["name"], !name.isEmpty else { return nil }
            let parent = flat["parent"] ?? flat["from"] ?? flat["base"] ?? ""
            let locked = ["true", "1", "yes"].contains((flat["locked"] ?? "").lowercased())
                || (flat["state"] ?? "").lowercased() == "locked"
            return BeamPhase(name: name, parent: parent, locked: locked, raw: flat)
        }
        return markLocked(phases)
    }

    /// Fallback for a plain-text table: header row, optional dashed separator, columns.
    static func parseTable(_ text: String) -> [BeamPhase] {
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let headers = lines.removeFirst().split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let nameCol = headers.firstIndex(of: "name") ?? 0
        let phases: [BeamPhase] = lines.compactMap { line in
            if line.allSatisfy({ $0 == "-" || $0 == " " }) { return nil }
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard nameCol < cols.count else { return nil }
            var raw: [String: String] = [:]
            for (i, h) in headers.enumerated() where i < cols.count { raw[h] = cols[i] }
            return BeamPhase(name: cols[nameCol], parent: raw["parent"] ?? raw["from"] ?? "",
                             locked: (raw["locked"] ?? raw["state"] ?? "").lowercased().hasPrefix("locked") || raw["locked"] == "true",
                             raw: raw)
        }
        return markLocked(phases)
    }

    /// A phase is locked once another phase is built on it.
    static func markLocked(_ phases: [BeamPhase]) -> [BeamPhase] {
        let parents = Set(phases.map(\.parent).filter { !$0.isEmpty })
        return phases.map { p in
            var p = p
            if parents.contains(p.name) { p.locked = true }
            return p
        }
    }

    /// A *new* phase name: letters, digits, `-_.`.
    static func safeName(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
    }

    /// An *existing* phase reference: "x", "default:v1" or "name@sha256:digest".
    static func safeRef(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@:".contains($0)) })
    }
}

/// `tsh phase add --no-console --format=json` output. Verified shape:
/// `{"name":"x","parent":"default:v1","state":"building","build_beam":"<uuid>",…}`.
struct PhaseBuild: Hashable {
    var name: String
    var buildBeam: String
    var raw: [String: String] = [:]

    static func parse(_ data: Data, fallbackName: String) -> PhaseBuild? {
        guard let i = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try? JSONSerialization.jsonObject(with: data[i...]) as? [String: Any] else { return nil }
        let flat = PhaseJSON.flatten(obj)
        var beam = ""
        for key in ["build_beam", "buildBeam", "build_beam_id", "beam_id", "beam"] {
            if let s = obj[key] as? String, !s.isEmpty { beam = s; break }
            if let d = obj[key] as? [String: Any] {
                let f = PhaseJSON.flatten(d)
                beam = f["uuid"] ?? f["id"] ?? f["name"] ?? ""
                if !beam.isEmpty { break }
            }
        }
        return PhaseBuild(name: flat["name"] ?? fallbackName, buildBeam: beam, raw: flat)
    }
}

enum PhaseJSON {
    /// Top-level scalars plus those under metadata/spec/status.
    static func flatten(_ d: [String: Any]) -> [String: String] {
        var flat: [String: String] = [:]
        func absorb(_ d: [String: Any]) {
            for (k, v) in d {
                switch v {
                case let s as String: flat[k] = s
                case let n as NSNumber: flat[k] = n.stringValue
                default: break
                }
            }
        }
        absorb(d)
        for k in ["metadata", "spec", "status"] { if let sub = d[k] as? [String: Any] { absorb(sub) } }
        return flat
    }
}

struct PhaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// Heuristic until a real message is captured.
    static func isLocked(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("locked") || l.contains("has dependent") || l.contains("fork")
    }

    /// A tsh too old for Phase: it rejects the `phase` command or the `--phase` flag.
    /// Check this before `isLocked`, since the help dump that follows may mention "fork".
    static func isUnsupportedCommand(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains(#"expected command but got "phase""#)
            || l.contains("unknown flag: --phase")
            || l.contains("unknown long flag '--phase'")
    }
}

/// Scripts run *inside* a build beam through `client.run`.
enum PhaseScripts {
    private static let needTsh = "command -v tsh >/dev/null || { echo 'beams: tsh not found in this beam' >&2; exit 127; }\n"

    /// Saves the build beam's /home to its phase. `final` also deletes the beam.
    static func snapshot(final: Bool = false) -> String {
        needTsh + "exec tsh phase snapshot" + (final ? " --final" : "") + " 2>&1\n"
    }

    /// Captures this build beam's filesystem as a new phase (the way out of a locked phase).
    static func fork(newName: String) -> String {
        needTsh + "exec tsh phase add \(Shell.quote(BeamPhase.safeName(newName))) --fork --no-console --format=json 2>&1\n"
    }
}

extension TshClient {
    /// Arguments after `tsh [--proxy=…]` for a headless `phase add`.
    static func phaseAddArgs(name: String, from: String = "", forkFrom: String = "", region: String = "") throws -> [String] {
        let n = BeamPhase.safeName(name)
        let f = BeamPhase.safeRef(from)
        let ff = BeamPhase.safeRef(forkFrom)
        if !f.isEmpty && !ff.isEmpty { throw PhaseError(message: "Choose either a base phase or a phase to fork, not both.") }
        var a = ["phase", "add"]
        if !f.isEmpty { a.append("--from=\(f)") }
        if !ff.isEmpty { a.append("--fork-from=\(ff)") }
        let r = region.trimmingCharacters(in: .whitespaces)
        if !r.isEmpty { a.append("--region=\(r)") }
        a += ["--no-console", "--format=json"]
        if !n.isEmpty { a.append(n) }   // omitted: tsh generates a name
        return a
    }

    /// Arguments after `tsh [--proxy=…]` for an ordinary beam started from a phase.
    static func beamAddArgs(phase: String, region: String = "") throws -> [String] {
        let p = BeamPhase.safeRef(phase)
        guard !p.isEmpty else { throw PhaseError(message: "Pick a phase to start the beam from.") }
        var a = ["beams", "add", "--no-console", "-f", "json", "--phase=\(p)"]
        let r = region.trimmingCharacters(in: .whitespaces)
        if !r.isEmpty { a.append("--region=\(r)") }
        return a
    }

    /// The `id` from `tsh beams add -f json` (log lines before the JSON are skipped).
    static func beamID(fromAddOutput data: Data) -> String? {
        guard let i = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try? JSONSerialization.jsonObject(with: data[i...]) as? [String: Any] else { return nil }
        let flat = PhaseJSON.flatten(obj)
        let id = flat["id"] ?? flat["uuid"] ?? flat["name"] ?? ""
        return id.isEmpty ? nil : id
    }

    /// This binary's client version. `--client` skips the proxy round trip;
    /// older builds without that flag fall back to plain `tsh version`.
    /// nil if it can't be read (the "too old" error mapping still applies).
    func clientVersion() async -> TshVersion? {
        for args in [[bin, "version", "--client"], [bin, "version"]] {
            if let res = try? await Shell.run(args, extraEnv: Self.env, timeout: 20, check: false),
               res.ok, let v = TshVersion.parse(res.stdoutText) {
                return v
            }
        }
        return nil
    }

    /// `tsh phase add … --no-console --format=json`: provisions a build beam.
    func phaseAdd(name: String, from: String = "", forkFrom: String = "", region: String = "") async throws -> PhaseBuild {
        let args = try Self.phaseAddArgs(name: name, from: from, forkFrom: forkFrom, region: region)
        let res = try await Shell.run(phaseArgs(args), extraEnv: Self.env, timeout: 600)
        return PhaseBuild.parse(res.stdout, fallbackName: BeamPhase.safeName(name))
            ?? PhaseBuild(name: BeamPhase.safeName(name), buildBeam: "", raw: ["output": res.stdoutText])
    }

    /// `tsh beams add --no-console -f json --phase=<phase>`. Returns the beam id.
    func beamAddFromPhase(_ phase: String, region: String = "") async throws -> String {
        let args = try Self.beamAddArgs(phase: phase, region: region)
        let res = try await Shell.run(phaseArgs(args), extraEnv: Self.env, timeout: 180)
        guard let id = Self.beamID(fromAddOutput: res.stdout) else {
            throw PhaseError(message: "tsh beams add didn't return a beam id: \(res.stdoutText.prefix(200))")
        }
        return id
    }

    /// `tsh phase ls -f json`, falling back to the text table.
    /// An expired certificate makes tsh start a login, so callers check status first.
    func phaseList() async throws -> [BeamPhase] {
        let json = try await Shell.run(phaseArgs(["phase", "ls", "-f", "json"]), extraEnv: Self.env, timeout: 45, check: false)
        if json.ok, let i = json.stdout.firstIndex(where: { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "{") }),
           let obj = try? JSONSerialization.jsonObject(with: json.stdout[i...], options: [.fragmentsAllowed]) {
            return BeamPhase.parse(obj)
        }
        let text = try await Shell.run(phaseArgs(["phase", "ls"]), extraEnv: Self.env, timeout: 45)
        return BeamPhase.parseTable(text.stdoutText)
    }

    /// `tsh phase rm <name>`. Beams already using the phase keep running.
    func phaseRemove(_ name: String) async throws {
        let n = BeamPhase.safeRef(name)
        guard !n.isEmpty else { throw PhaseError(message: "Invalid phase name “\(name)”") }
        try await Shell.run(phaseArgs(["phase", "rm", n]), extraEnv: Self.env, timeout: 60)
    }

    /// `tsh phase apply -f <file>`: define phases in YAML, non-interactively.
    @discardableResult
    func phaseApply(file: URL) async throws -> String {
        try await Shell.run(phaseArgs(["phase", "apply", "-f", file.path]), extraEnv: Self.env, timeout: 600).stdoutText
    }

    private func phaseArgs(_ sub: [String]) -> [String] {
        var a = [bin]
        if !proxy.isEmpty { a.append("--proxy=\(proxy)") }
        return a + sub
    }
}

// MARK: - Phase: shared state and window

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

    /// The Mac's tsh version, once checked; nil if unknown.
    @Published private(set) var tshVersion: TshVersion?
    /// Non-empty when the Mac's tsh can't run Phase commands.
    @Published private(set) var tshProblem = ""
    /// The tsh path last checked, so a changed path (or a rebuild + ↻) re-checks.
    private var checkedBin: String?

    /// Phase name → build beam uuid, from `phase add` output this run
    /// (`phase ls` doesn't report the build beam).
    private var knownBuilds: [String: String] = [:]

    static let maxLog = 2_000

    private init() {}

    /// Checks the tsh version once per path. Returns false if it's too old.
    /// An unreadable version is allowed; errors are still mapped by `describe`.
    private func tshSupportsPhase(_ tsh: TshClient) async -> Bool {
        if checkedBin != tsh.bin {
            checkedBin = tsh.bin
            let v = await tsh.clientVersion()
            tshVersion = v
            if let v, v < TshVersion.phaseMinimum {
                tshProblem = "tsh at \(tsh.bin) is v\(v); Phase needs v\(TshVersion.phaseMinimum) or newer."
                append("tsh \(tsh.bin): v\(v), too old for Phase")
            } else {
                tshProblem = ""
                append("tsh \(tsh.bin): \(v.map { "v\($0)" } ?? "version unknown")")
            }
        }
        return tshProblem.isEmpty
    }

    /// Error text for the Mac's tsh, turning "unknown command" dumps into a version message.
    private func describe(_ error: Error, bin: String) -> String {
        let msg = PhaseText.clean(error.localizedDescription)
        guard PhaseError.isUnsupportedCommand(msg) else { return msg }
        tshProblem = "tsh at \(bin) doesn't support Phase. Phase needs v\(TshVersion.phaseMinimum) or newer."
        return tshProblem
    }

    /// Reports an error, replacing tsh's help dump with the version message.
    private func report(_ error: Error, bin: String, model: AppModel) {
        let msg = describe(error, bin: bin)
        append("error: \(msg)")
        if msg == tshProblem { model.fail(PhaseError(message: msg)) } else { model.fail(error) }
    }

    /// `recheck` forgets the cached version (the window's ↻ button), so a
    /// rebuilt tsh is picked up without relaunching.
    func refresh(_ model: AppModel, recheck: Bool = false) async {
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
        if recheck { checkedBin = nil }
        guard await tshSupportsPhase(tsh) else {
            phases = []
            note = tshProblem
            return
        }
        do {
            phases = try await tsh.phaseList().sorted { $0.name < $1.name }
            note = phases.isEmpty ? "No phases yet. Create one above." : ""
        } catch {
            phases = []
            note = describe(error, bin: tsh.bin)
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

    /// Sets (or with nil, clears) the phase ＋ New Beam starts from.
    func setDefault(_ name: String?, model: AppModel) {
        model.config.defaultPhase = name ?? ""
        model.saveConfig()
        model.toast(name.map { "New beams will start from phase \($0)" } ?? "New beams will use the cluster's default image", .ok)
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
        guard await tshSupportsPhase(tsh) else { model.toast(tshProblem, .err, seconds: 10); return }
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
            report(error, bin: tsh.bin, model: model)
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
        guard await tshSupportsPhase(tsh) else { model.toast(tshProblem, .err, seconds: 10); return }
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
            report(error, bin: tsh.bin, model: model)
        }
    }

    func remove(_ phase: BeamPhase, _ model: AppModel) async {
        guard confirm("Delete phase “\(phase.name)”?",
                      "Beams already using it keep running until they expire. If a build is still open, finish it with a final snapshot first, or its unsaved changes are lost.",
                      ok: "Delete Phase") else { return }
        if model.isMock { model.toast("Simulated delete of \(phase.name)", .ok); return }
        guard let tsh = model.client as? TshClient else { return }
        guard await tshSupportsPhase(tsh) else { model.toast(tshProblem, .err, seconds: 10); return }
        do {
            try await tsh.phaseRemove(phase.name)
            knownBuilds[phase.name] = nil
            model.toast("Deleted phase \(phase.name)", .ok)
            if model.config.defaultPhase == phase.name { setDefault(nil, model: model) }
        } catch {
            report(error, bin: tsh.bin, model: model)
        }
        await refresh(model)
    }

    /// Saves the build beam's /home to its phase. Uses the tsh *inside* the
    /// beam, so it doesn't depend on the Mac's version.
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
            let msg = PhaseText.clean(error.localizedDescription)
            if PhaseError.isUnsupportedCommand(msg) {
                let text = "The tsh inside \(beam.name) is too old for snapshots. Phase needs v\(TshVersion.phaseMinimum) or newer."
                append("error: \(text)")
                model.fail(PhaseError(message: text))
            } else if PhaseError.isLocked(msg) {
                append("error: \(msg)")
                await offerFork(beam, model: model)
            } else {
                append("error: \(msg)")
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
            append("error: \(PhaseText.clean(error.localizedDescription))")
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
        let usable = center.tshProblem.isEmpty
        let defaultPhase = model.config.defaultPhase
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Phases").font(.headline)
                if let v = center.tshVersion {
                    Text(verbatim: "tsh v\(v)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if center.loading { ProgressView().controlSize(.small) }
                Button { Task { await center.refresh(model, recheck: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Re-check tsh and refresh (tsh phase ls)")
            }
            .padding(10)
            Text(defaultPhase.isEmpty
                 ? "New beams (＋, ⌘N) use the cluster's default image. Right-click a phase → Use for New Beams to change that."
                 : "New beams (＋, ⌘N) start from phase \(defaultPhase).")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 8)
            if !usable {
                Label(center.tshProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.12))
            }
            Divider()
            newPhaseForm(usable: usable).padding(10)
            Divider()
            List(center.phases) { p in
                PhaseRow(phase: p, starting: center.startingFrom.contains(p.name), enabled: usable,
                         isDefault: p.name == defaultPhase) {
                    Task { await center.startBeam(from: p, model: model) }
                }
                .contextMenu {
                    Button("New Beam from This Phase") { Task { await center.startBeam(from: p, model: model) } }
                        .disabled(!usable || center.startingFrom.contains(p.name))
                    if p.name == defaultPhase {
                        Button("Stop Using for New Beams") { center.setDefault(nil, model: model) }
                    } else {
                        Button("Use for New Beams") { center.setDefault(p.name, model: model) }
                    }
                    Divider()
                    Button("Build a New Phase on This") { draft.base = .from; draft.basePhase = p.name }
                    Button("Fork This Phase") { draft.base = .fork; draft.basePhase = p.name; draft.name = "\(p.name)-v2" }
                    Divider()
                    Button("Delete Phase…", role: .destructive) { Task { await center.remove(p, model) } }
                        .disabled(!usable)
                }
            }
            .listStyle(.inset)
            if !center.note.isEmpty && center.note != center.tshProblem {
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

    private func newPhaseForm(usable: Bool) -> some View {
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
            .buttonStyle(.borderedProminent).disabled(!usable || center.creating)
        }
    }
}

/// One phase: name, parent, state, lock, default badge and a "New Beam" button.
private struct PhaseRow: View {
    let phase: BeamPhase
    let starting: Bool
    let enabled: Bool
    let isDefault: Bool
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
            if isDefault {
                Text("default").font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                    .help("＋ New Beam starts from this phase")
            }
            if phase.locked {
                Text("locked").font(.caption).foregroundStyle(.orange)
            } else if !phase.state.isEmpty {
                Text(phase.state).font(.caption).foregroundStyle(phase.isBuilding ? .blue : .secondary)
            }
            Button(action: onStart) {
                if starting { ProgressView().controlSize(.small) } else { Text("New Beam") }
            }
            .disabled(!enabled || starting)
            .help("tsh beams add --phase=\(phase.name), then open a session in it")
        }
    }
}
