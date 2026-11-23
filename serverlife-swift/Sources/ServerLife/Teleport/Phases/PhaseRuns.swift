import AppKit
import SwiftUI

/// Observed by the Phase views: bumped when the build journal changes.
@MainActor
@Observable
final class PhaseStore {
    static let shared = PhaseStore()
    var journalGeneration = 0
}

/// Status-bar messages with the original's names (ui.js status/toast).
@MainActor
enum PHStatus {
    static func show(_ text: String, ms: Double = 3800) {
        StatusBus.shared.show(text, kind: .info, seconds: ms / 1000)
    }
    static func toast(_ text: String, _ kind: String = "info", ms: Double? = nil) {
        let k: StatusBus.Kind = kind == "error" ? .error : kind == "success" ? .ok : .info
        if let ms { StatusBus.shared.toast(text, kind: k, seconds: ms / 1000) } else { StatusBus.shared.toast(text, kind: k) }
    }
}

/// beams.js: running Phase builds — runPhaseBuild, startPhaseHeadless,
/// replacePhaseInputs, snapshotBuild, editPhase.
@MainActor
enum PhaseRuns {
    static func profile(key: String?) -> TeleportProfile? {
        guard let key else { return nil }
        return Inventory.shared.profiles.first { $0.key == key }
    }
    static func profile(proxy: String, home: String?) -> TeleportProfile? {
        Inventory.shared.profiles.first { $0.proxy == proxy && (home == nil || $0.homeDir == home) }
            ?? Inventory.shared.profiles.first { $0.proxy == proxy }
    }

    static func phases(_ p: TeleportProfile) -> [BeamPhase] { BeamPhaseLists.shared.phaseList(p.proxy)?.phases ?? [] }

    static func run(_ p: TeleportProfile, _ args: [String]) -> TshCommand {
        TshCommand(command: Tools.tsh, args: args, teleportHome: TeleportHomes.resolve(p.homeDir, proxy: p.proxy))
    }

    /**
     * Run a Phase build in a terminal tab.
     *
     * `tsh phase add` and `tsh phase edit` open a build console — a shell on a
     * build beam — and only end when the build does (`tsh phase snapshot --final`
     * inside it, or leaving it), so they need a real terminal, as a login does.
     *
     * How it ended is read from the Phase, not from tsh's exit code: the console
     * closing ends tsh with 255 even when the snapshot was saved, which read as a
     * failure. A Phase saved since the build started is a success; one marked
     * failed brings its own error and the way to look inside it.
     */
    static func runPhaseBuild(_ p: TeleportProfile, _ run: TshCommand, title: String, meta: PhaseBuildMeta,
                              window: WindowModel?) async -> Bool {
        let before = Set(phases(p).map(\.name))
        let entry = PhaseJournal.newEntry(proxy: p.proxy, meta)
        PhaseJournal.save([entry] + PhaseJournal.entries)
        PHStatus.show(entry.commandsFile.isEmpty
            ? "In the build console: install what the image needs, then run tsh phase snapshot --final"
            : "Building from \(entry.commandsFile) — the log is in the new tab", ms: 15000)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            run.open(title: title, window: window) { code in
                Task { @MainActor in cont.resume(returning: await finished(p, entry, before: before, code: code, title: title)) }
            }
        }
    }

    private static func finished(_ p: TeleportProfile, _ entry: PhaseBuildEntry, before: Set<String>,
                                 code: Int32?, title: String) async -> Bool {
        // The cluster can take a moment to list what was just saved: look a
        // few times before calling it unknown (settle() catches it later).
        var name = entry.name
        var ph: BeamPhase?
        var result: String?
        var i = 0
        while i < 6 && result == nil {
            if i > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            await BeamPhaseLists.shared.refreshPhases(p)
            let all = phases(p)
            // A name left to tsh is the one that was not there before.
            name = entry.name.nilIfEmpty ?? all.first { !before.contains($0.name) }?.name ?? ""
            ph = name.isEmpty ? nil : all.first { $0.name == name }
            result = ph.flatMap { PhaseJournal.judge(entry, $0) }
            i += 1
        }
        let res = result ?? (code == 0 ? "saved" : "unknown")
        PhaseJournal.update(entry.id, [
            "name": .string(name), "result": .string(res), "endedAt": .number(nowMs()),
            "exitCode": code.map { .number(Double($0)) } ?? .null,
            "digest": .string(ph?.digest ?? ""), "error": .string(res == "failed" ? (ph?.lastError ?? "") : ""),
        ])
        if res == "saved" {
            PHStatus.toast("Saved Phase \(name)" + ((ph?.digest).flatMap { $0.isEmpty ? nil : " — " + String($0.prefix(19)) } ?? ""),
                           "success", ms: 9000)
        } else if res == "failed" {
            PHStatus.toast("Phase \(name) failed to build.\n\(ph?.lastError.nilIfEmpty ?? "tsh phase ls-failed has the snapshot it left.")",
                           "error", ms: 20000)
        } else {
            PHStatus.show("\(title): tsh exited with \(code.map(String.init) ?? "null") — the tab has what it said", ms: 9000)
        }
        Inventory.shared.onBeams.forEach { $0() }
        return res == "saved"
    }

    /**
     * A no-console Phase build: run captured rather than handed to tsh's own
     * console, the build recorded in the journal exactly as runPhaseBuild does,
     * then straight into its build Beam through the ordinary beam session path
     * — a real interactive session, file browser and all. Not an offer:
     * skipping tsh's console and not joining anything would leave an
     * interactive build with nobody able to type into it.
     */
    static func startHeadless(_ p: TeleportProfile, _ run: TshCommand, meta: PhaseBuildMeta, window: WindowModel?) async -> Bool {
        var entry = PhaseJournal.newEntry(proxy: p.proxy, meta)
        /*
         * A status-bar message is too easy to miss here: there is nothing else on
         * screen yet to say a build is even happening, let alone that a session is
         * about to open on its own. A popup, closed the moment the build Beam
         * answers (success or not), says so where it cannot be missed.
         */
        let wait = Modal.sheet(window, title: "Starting the Phase build…", width: 420) { handle in
            DialogScaffold(title: "Starting the Phase build…", width: 420, scroll: false) {
                Text("This can take a moment — tsh is provisioning the sandbox VM. "
                     + "A session opens on it automatically, file browser and all, as soon as it is up.")
                    .font(.system(size: 12)).foregroundStyle(Theme.shared.p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: { Spacer() }
        }
        let r = await Beams.startNonInteractive(run.args, home: run.teleportHome)
        wait.close()
        if !r.ok { PHStatus.toast(r.error ?? "Could not start the build", "error", ms: 9000); return false }
        if !r.name.isEmpty { entry.raw["name"] = .string(r.name) }
        PhaseJournal.save([entry] + PhaseJournal.entries)
        await BeamPhaseLists.shared.refreshPhases(p)
        if r.buildBeam.isEmpty {
            PHStatus.toast("\(entry.name.nilIfEmpty ?? "The build") started, but tsh did not say which Beam — open it from the Phases list",
                           "error", ms: 12000)
            return true
        }
        BeamsUI.open(buildBeam(p, r.buildBeam), window: window)
        return true
    }

    static func buildBeam(_ p: TeleportProfile, _ id: String) -> Beam {
        Beam(id: id, uuid: "", owner: "", region: "", requestedRegion: "", url: "", proxy: p.proxy, home: p.homeDir)
    }

    /// `tsh phase edit`: change a Phase in place, in a build console.
    @discardableResult
    static func editPhase(_ p: TeleportProfile, name: String, window: WindowModel?) async -> Bool {
        guard await Modal.confirm(window, title: "Edit \(name) in place?",
                                  message: "Opens a build console on its saved files; saving replaces the Phase.",
                                  detail: "tsh refuses if other Phases are built from it — fork it instead.",
                                  ok: "Open the build console") else { return false }
        let args: [String]
        do { args = try Beams.phaseEditArgs(proxy: p.proxy, name: name) }
        catch { PHStatus.toast(error.localizedDescription, "error"); return false }
        return await runPhaseBuild(p, run(p, args), title: "Phase edit · \(name)",
                                   meta: ["kind": "edit", "name": .string(name), "mode": "edit"], window: window)
    }
}
