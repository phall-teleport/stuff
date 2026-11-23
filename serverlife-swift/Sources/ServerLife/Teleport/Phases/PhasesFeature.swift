import SwiftUI

/// The phases owner's actions (the `phase-*` contract in BeamsPhaseUI.swift and CLAUDE.md).
@MainActor
enum PhasesFeature {
    private static func profile(_ ctx: ActionContext) -> TeleportProfile? {
        if let p = PhaseRuns.profile(key: ctx.arg("profileKey", as: String.self)) { return p }
        if let px = ctx.arg("proxy", as: String.self) ?? ctx.host?.proxy {
            return PhaseRuns.profile(proxy: px, home: ctx.arg("home", as: String.self) ?? ctx.host?.home)
        }
        if let c = ctx.arg("cluster", as: String.self) {
            return Inventory.shared.profiles.first { $0.cluster == c || $0.proxy == c }
        }
        return nil
    }

    static func install() {
        let a = Actions.shared
        // New Phase… (beams.js newPhase): args `profileKey`, `mode`, `source`.
        a.register("phase-new-build") { ctx in
            guard let p = profile(ctx) else { return }
            let mode = ctx.arg("mode", as: String.self) ?? "base", source = ctx.arg("source", as: String.self) ?? ""
            Task { await PhaseRuns.newPhase(p, mode: mode, source: source, window: ctx.window) }
        }
        // Build a Phase from setups: args `profileKey`, `from` (or `path`, a phase.yaml to open, and `cluster`).
        a.register("phase-builder") { ctx in
            guard let p = profile(ctx) else { return }
            PhaseBuilder.open(p, from: ctx.arg("from", as: String.self), window: ctx.window)
        }
        // My add-ins.
        a.register("phase-addins") { ctx in
            Task { _ = await PhaseAddins.open(window: ctx.window) }
        }
        // The picker (reply AnyView): `profileKey`, `phases`, `value`, `standard`, `typed`, `onChange`, `placeholder`.
        a.register("phase-picker") { ctx in
            guard let reply = ctx.arg("reply", as: ((Any?) -> Void).self) else { return }
            guard let p = profile(ctx) else { reply(nil); return }
            let onChange = ctx.arg("onChange", as: ((String) -> Void).self) ?? { _ in }
            let m = PhasePickerModel(profile: p, phases: ctx.arg("phases", as: [BeamPhase].self) ?? PhaseRuns.phases(p),
                                     value: ctx.arg("value", as: String.self) ?? "",
                                     standard: ctx.arg("standard", as: String.self),
                                     typed: ctx.arg("typed", as: Bool.self) ?? false,
                                     placeholder: ctx.arg("placeholder", as: String.self), onChange: onChange)
            reply(AnyView(PhasePickerView(m: m)))
        }
        // The Phases tab's rows (reply AnyView): `profileKey`, `mode` folders/list/relationship.
        a.register("phase-list-view") { ctx in
            guard let reply = ctx.arg("reply", as: ((Any?) -> Void).self) else { return }
            guard let p = profile(ctx) else { reply(nil); return }
            reply(AnyView(PhaseListView(profile: p, mode: ctx.arg("mode", as: String.self) ?? "folders", window: ctx.window)))
        }
        // History and beams: `profileKey` (or `proxy`/`home`), `name`.
        a.register("phase-details") { ctx in
            guard let p = profile(ctx), let name = ctx.arg("name", as: String.self) else { return }
            Task { await PhaseRuns.showPhaseDetails(p, name: name, window: ctx.window) }
        }
        a.register("phase-edit") { ctx in
            guard let p = profile(ctx), let name = ctx.arg("name", as: String.self) else { return }
            Task { await PhaseRuns.editPhase(p, name: name, window: ctx.window) }
        }
        // A beam's Phase as "a ⑂ b → c" (reply String): `proxy`, `name`.
        a.register("phase-lineage") { ctx in
            guard let reply = ctx.arg("reply", as: ((Any?) -> Void).self) else { return }
            guard let px = ctx.arg("proxy", as: String.self), let name = ctx.arg("name", as: String.self) else { reply(nil); return }
            let bare = BeamsUI.phaseName(name)
            reply(PhaseRelations.lineageText(PhaseRelations.of(px, bare), fallback: bare))
        }
        // A fresh Phase list: running builds in the journal settled against it.
        a.register("phase-list-read") { ctx in
            guard let px = ctx.arg("proxy", as: String.self), let list = ctx.arg("phases", as: [BeamPhase].self) else { return }
            PhaseJournal.settle(proxy: px, phases: list)
        }
    
        // Development only (not in any menu): the builder and add-ins on a made-up cluster, for --snapshot.
        a.register("phase-dev-builder") { ctx in
            let p = TeleportProfile(proxy: "demo.example.com:443", cluster: "demo")
            PhaseBuilder.open(p, from: "workspace", window: ctx.window,
                              support: BeamAddSupport(phases: true, roles: true, apply: true, copy: true, noConsole: true))
        }
        a.register("phase-dev-addins") { ctx in Task { _ = await PhaseAddins.open(window: ctx.window) } }
    }
}
