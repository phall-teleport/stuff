import Foundation

/// tsh integration and the host inventory (teleport.js, beams.js, livesessions.js, sshconfig.js).
///
/// Owner: teleport-service (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens: register
/// actions, slots, status items and timers here.
@MainActor
enum TeleportServiceFeature {
    static func install() {
        // Applies settings.tshHomes / tshPath (and follows later changes),
        // runs the first inventory load, starts the node, beams and request
        // loops, then logs in saved clusters flagged for it.
        Inventory.shared.start()

        // Settings → "Check what they hold" (teleport:homes). Settings applies
        // the edited list first; the settings hook re-reads it synchronously.
        MiscHooks.teleportHomes = { await Teleport.homesReportJSON() }

        // "Refresh the inventory" for anyone who wants it without a dependency.
        Actions.shared.register("inventory-refresh") { _ in
            Task { await Inventory.shared.refresh() }
        }

        // VNet per cluster: vnet-start, vnet-stop, vnet-log, vnet-status, vnet-menu.
        VnetActions.install()

        // Query: the tsh variables a run for this proxy/home gets (args
        // `proxy`, `home`; reply [String: String]) — for anyone starting tsh
        // outside Teleport.run (terminal tabs, Connections).
        Actions.shared.register("tsh-env-for") { ctx in
            let proxy = ctx.arg("proxy", as: String.self) ?? ctx.host?.proxy
            let home = ctx.arg("home", as: String.self) ?? ctx.host?.home
            ctx.arg("reply", as: ((Any?) -> Void).self)?(TshEnv.vars(home: home, proxy: proxy))
        }
    }
}
