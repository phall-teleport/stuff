import SwiftUI

extension PhaseRuns {
    private enum NewPhaseAnswer { case build(PhaseAddRequest), builder(String) }

    /**
     * A new Phase (beams.js `newPhase`): from the default base image, built on
     * top of another Phase (`--from`), or forked from one's last saved files
     * (`--fork-from`).
     */
    @discardableResult
    static func newPhase(_ p: TeleportProfile, mode: String = "base", source: String = "", window: WindowModel?) async -> Bool {
        /*
         * How it is built: by hand in a console, or from a command file — a YAML
         * recipe tsh runs and streams the log of. A fork starts from saved files,
         * so it is always a console.
         */
        let can = await Beams.addSupport(proxy: p.proxy, home: p.homeDir)
        let m = PhaseNewModel(profile: p, can: can, mode: mode, source: source)
        let answer: NewPhaseAnswer? = await withCheckedContinuation { cont in
            var done = false
            let finish: (NewPhaseAnswer?) -> Void = { v in if !done { done = true; cont.resume(returning: v) } }
            let sub = p.cluster.nilIfEmpty ?? p.proxy
            let h = Modal.sheet(window, title: "New Phase", width: 560) { handle in
                DialogScaffold(title: "New Phase", subtitle: sub, width: 560) {
                    PhaseNewView(m: m) {
                        finish(.builder(m.mode == "from" ? m.source.value.trimmed : "")); handle.close()
                    }
                } footer: {
                    Spacer()
                    Button("Cancel") { finish(nil); handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                    Button("Start the build") {
                        if let problem = m.problem() { PHStatus.toast(problem, "error"); return }
                        finish(.build(m.collect())); handle.close()
                    }.buttonStyle(.primary)
                }
            }
            h.onClose.append { finish(nil) }
        }
        guard let answer else { return false }
        let res: PhaseAddRequest
        switch answer {
        case .builder(let from):
            PhaseBuilder.open(p, from: from, window: window)
            return false
        case .build(let r): res = r
        }
        let args: [String]
        do { args = try PhaseNewModel.args(p, res) } catch { PHStatus.toast(error.localizedDescription, "error"); return false }
        let what = res.forkFrom.map { "fork of \($0)" } ?? res.from.map { "on \($0)" } ?? "new"
        let meta: PhaseBuildMeta = [
            "kind": "add", "name": .string(res.name ?? ""),
            "mode": .string(res.forkFrom != nil ? "fork" : res.from != nil ? "from" : "base"),
            "source": .string(res.forkFrom ?? res.from ?? ""), "commandsFile": .string(res.commandsFile ?? ""),
            "copies": PhaseBuildMeta.copies(res.copies ?? []), "roles": PhaseBuildMeta.strs(res.roles),
            "region": .string(res.region ?? ""),
        ]
        if res.noConsole { return await startHeadless(p, run(p, args), meta: meta, window: window) }
        return await runPhaseBuild(p, run(p, args), title: "Phase build · \(res.name ?? what)", meta: meta, window: window)
    }
}
