import Foundation

/// sessions.js `checkTeleportPresence` / `watchTeleportInstall`: whether an
/// ssh host a session is open on has Teleport on it — for the pane header's
/// ⚡ button and the sidebar's notice. Asked after every connect, for any
/// ssh connection (saved profile, Quick connect, not just sidebar rows).
/// Not for Teleport nodes, nor when detection is off or the app may run
/// nothing on servers by itself (quietRemote).
@MainActor @Observable
final class SessPresence {
    static let shared = SessPresence()
    /// hostId → the last answer (state.teleportPresence).
    private(set) var byHost: [String: TeleportPresence] = [:]
    @ObservationIgnored private var checked = Set<String>()

    func presence(_ hostId: String?) -> TeleportPresence? { hostId.flatMap { byHost[$0] } }

    /// Whether the pane's header shows ⚡.
    func missing(connId: String?) -> Bool {
        guard let c = connId.flatMap({ ConnectionManager.shared.connection($0) }), let p = presence(c.hostId) else { return false }
        return !p.installed
    }

    /// `refresh` asks the host again rather than taking the answer held: a
    /// host that had Teleport installed afterwards would otherwise keep its
    /// ⚡ button for the connection's whole life.
    @discardableResult
    func check(_ connId: String, refresh: Bool = false) async -> TeleportPresence? {
        guard let c = ConnectionManager.shared.connection(connId), c.type == "ssh", let hostId = c.hostId else { return nil }
        let s = Store.shared
        if s.setting("detectTeleportOnSsh", true) == false || s.setting("quietRemote", false) { return nil }
        if !refresh, let have = byHost[hostId] { return have }
        if !refresh && checked.contains(hostId) { return nil }
        checked.insert(hostId)
        let before = byHost[hostId]
        do {
            let r = try await ConnectionManager.shared.teleportPresence(connId, refresh: refresh)
            byHost[hostId] = r
            if Actions.shared.isRegistered("teleport-presence") {
                Actions.shared.perform("teleport-presence", args: ["hostId": hostId, "presence": r.json])
            }
            // The notice: the first time a host is found without Teleport,
            // and again if it had it the last time and has lost it since.
            if !r.installed && (before == nil || before!.installed) && Actions.shared.isRegistered("teleport-install-offer") {
                Actions.shared.perform("teleport-install-offer", host: c.host,
                                       args: ["hostId": hostId, "label": c.label, "again": before?.installed == true])
            }
            if r.installed, let b = before, !b.installed {
                let name = c.label.replacingOccurrences(of: "\\s+\\([^)]*\\)$", with: "", options: .regularExpression)
                StatusBus.shared.toast("Teleport is on \(name.isEmpty ? "this host" : name) now"
                                       + (r.running ? " and running" : " — not running yet"))
            }
            return r
        } catch {
            checked.remove(hostId)
            return nil
        }
    }

    /// Ask again every 15 s for a few minutes — after the install has been
    /// typed into a session.
    func watchInstall(_ connId: String, every: Double = 15, forSeconds: Double = 180) {
        let until = Date().addingTimeInterval(forSeconds)
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(every * 1e9))
                let r = await check(connId, refresh: true)
                if r?.installed == true || Date() > until || ConnectionManager.shared.connection(connId) == nil { return }
            }
        }
    }

    /// The ⚡ button: ask again first (it may have been installed since the
    /// last answer), then offer the install wizard.
    func installClicked(_ connId: String?, window: WindowModel?) async {
        guard let connId, let c = ConnectionManager.shared.connection(connId), c.hostId != nil else { return }
        if await check(connId, refresh: true)?.installed == true { return }
        if Actions.shared.isRegistered("add-to-teleport") {
            Actions.shared.perform("add-to-teleport", window: window, host: c.host)
        } else {
            StatusBus.shared.show("No Teleport agent on this host", kind: .warn)
        }
    }
}
