import SwiftUI

/// "Teleport detected" / "⚡ Add to Teleport" (sidebar.js
/// `teleportPresenceCache`, `teleportPresenceBadge`, `offerTeleportInstall`).
/// A direct (non-Teleport) SSH host is probed once per connection, lazily, the
/// first time its connected row draws; `detectTeleportOnSsh` turns the whole
/// thing off, probe included, so a host nobody asked about is never touched.
/// Shared with the panes (`state.teleportPresence`): [sessions] can read
/// `known(hostId)` or ask `teleport-presence` (args `hostId`, `reply`).
@MainActor
@Observable
final class SBPresence {
    static let shared = SBPresence()

    static var enabled: Bool { SB.store.settingJSON("detectTeleportOnSsh").bool != false }

    private(set) var cache: [String: TeleportPresence] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    /// The offer, said once per host per run.
    @ObservationIgnored private var offered: Set<String> = []
    /// The host the offer box is about, while it shows.
    private(set) var offer: Host?

    func known(_ hostId: String) -> TeleportPresence? { cache[hostId] }

    /// Keep in step with a session's own re-check.
    func set(_ hostId: String, _ p: TeleportPresence?) {
        if let p { cache[hostId] = p } else { cache.removeValue(forKey: hostId) }
    }

    /// The badge for a row: nil, or the presence once known. Starts the probe.
    func badge(_ host: Host, connected: Bool) -> TeleportPresence? {
        guard host.type != Host.teleport, Self.enabled, connected else { return nil }
        if let c = cache[host.id] { return c }
        probe(host)
        return nil
    }

    private func probe(_ host: Host, refresh: Bool = false) {
        guard !asking.contains(host.id),
              let conn = ConnectionManager.shared.connections.first(where: { $0.hostId == host.id && $0.state == .connected })
        else { return }
        asking.insert(host.id)
        let id = conn.id
        Task { @MainActor in
            defer { asking.remove(host.id) }
            guard let r = try? await ConnectionManager.shared.teleportPresence(id, refresh: refresh) else { return }
            cache[host.id] = r
            if !r.installed { offerInstall(host) }
        }
    }

    /// `offerTeleportInstallFor`: the one-time notice, for a connection the
    /// session itself checked. `again`: Teleport was there and has gone — say
    /// so again, even if the first notice was dismissed.
    func offerInstallFor(_ host: Host, again: Bool) {
        if again { offered.remove(host.id) }
        offerInstall(host)
    }

    private func offerInstall(_ host: Host) {
        if offered.contains(host.id) { return }
        offered.insert(host.id)
        offer = host
        // Long enough to read and act on; the sidebar tag and the menu item stay.
        after(20) { [weak self] in if self?.offer?.id == host.id { self?.offer = nil } }
    }

    func dismissOffer() { offer = nil }

    /// sessions.js `watchTeleportInstall`: re-check every 15 s for three
    /// minutes after the commands were typed, so the ⚡ clears itself once the
    /// install has landed.
    func watchInstall(_ host: Host, connId: String, every: Double = 15, forSeconds: Double = 180) {
        let until = Date().addingTimeInterval(forSeconds)
        func tick() {
            after(every) { [weak self] in
                Task { @MainActor in
                    guard let self, ConnectionManager.shared.connection(connId) != nil else { return }
                    let r = try? await ConnectionManager.shared.teleportPresence(connId, refresh: true)
                    if let r { self.cache[host.id] = r }
                    if r?.installed == true || Date() > until { return }
                    tick()
                }
            }
        }
        tick()
    }
}

/// The badge after a connected ssh row's name.
struct SBPresenceTag: View {
    let host: Host
    let window: WindowModel?
    var body: some View {
        if let p = SBPresence.shared.badge(host, connected: true) {
            let name = host.name.nilIfEmpty ?? host.alias ?? ""
            if !p.installed {
                SBTag(text: "\u{26A1} Add to Teleport", kind: .req,
                      help: "\(name) has no Teleport agent.\nClick to enroll it in a Teleport cluster \u{2014} a join token and the commands to run.\n"
                        + "Turn this check off in Settings \u{2192} detectTeleportOnSsh.")
                    .onTapGesture { SBInstallTeleport.open(host, window: window) }
            } else if p.running {
                SBTag(text: "\u{26A1} Teleport detected", kind: .req,
                      help: "\(name) is already running a Teleport agent.\nThis box could be reached through Teleport instead of a direct SSH connection.\n"
                        + "Turn this check off in Settings \u{2192} detectTeleportOnSsh.")
            }
        }
    }
}

/// `offerTeleportInstall`'s notice, where it cannot be missed: a tag at the
/// end of a row is cut off as soon as the row has a long name.
struct SBPresenceOffer: View {
    let window: WindowModel?
    var body: some View {
        let p = Theme.shared.p
        if let host = SBPresence.shared.offer {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(host.name.nilIfEmpty ?? host.alias ?? "") has no Teleport agent.").font(.system(size: 12)).foregroundStyle(p.text)
                HStack(spacing: 6) {
                    Spacer()
                    Button("Not now") { SBPresence.shared.dismissOffer() }.buttonStyle(.ghost)
                    Button("Add to Teleport\u{2026}") {
                        SBPresence.shared.dismissOffer()
                        SBInstallTeleport.open(host, window: window)
                    }.buttonStyle(.primary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            .padding(8)
        }
    }
}
