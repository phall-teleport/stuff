import Foundation

extension Store {
    /// Settings → "No background commands on servers" (`quietRemote`).
    var connQuietRemote: Bool { settingJSON("quietRemote").bool == true }
}

extension ConnectionManager {
    /// `conn:startMonitor`: refused while background commands on servers are off.
    func startMonitor(_ connId: String, interval: Double = 5) async -> MonitorStart {
        if Store.shared.connQuietRemote {
            return MonitorStart(ok: false, reason: "quiet", error: "Background commands on servers are off in Settings.")
        }
        guard let c = connection(connId) else { return MonitorStart(ok: false, error: "No such connection: " + connId) }
        return await c.startMonitor(interval: interval)
    }

    /// `conn:stopMonitor`.
    @discardableResult
    func stopMonitor(_ connId: String) -> Bool { connection(connId)?.stopMonitor() ?? false }

    /// `conn:teleportPresence`.
    func teleportPresence(_ connId: String, refresh: Bool = false) async throws -> TeleportPresence {
        try await require(connId).teleportPresence(refresh: refresh)
    }

    /// Local shells' sampler reports as connection "local" (main.js `local:startMonitor`).
    func emitLocalMonitor(_ ev: MonitorEvent) { emitEvent(.monitor(id: LocalMonitor.key, event: ev)) }
}

/// The live stats feed, for whoever draws the bar (monitor.js in the
/// original, [sessions] here): join a machine's monitor with `attach`, leave
/// with `detach`; the first starts it, the last stops it. The key is a
/// connection id, or `LocalMonitor.key` ("local") for this computer. What
/// arrives is the latest reading per key (`last`), observable, plus every
/// event through `ConnectionManager.subscribe` (`.monitor`).
///
/// Whether to show a bar at all — `liveStats`, `quietRemote`, `localStats`,
/// one bar per tab, a hidden host — stays with the bar's owner; this
/// starts what it is asked to.
@MainActor @Observable
final class LiveStats {
    static let shared = LiveStats()

    enum Status: String, Sendable { case idle, starting, running, ended, mfa, unsupported }

    struct Entry: Sendable {
        var status: Status = .idle
        var hello: (cpus: Int, interval: Int)?
        var last: MonitorSample?
        var error = ""
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var refs: [String: Int] = [:]
    @ObservationIgnored private var token: UUID?

    private init() {}

    /// Start (or join) the monitor for `key`. A second call for a key whose
    /// monitor ended (a drop) restarts it.
    func attach(_ key: String, interval: Double = 5) {
        listen()
        refs[key, default: 0] += 1
        let st = entries[key]?.status ?? .idle
        if st == .idle || st == .ended { Task { await start(key, interval: interval) } }
    }

    /// Leave; the last one out stops the monitor.
    func detach(_ key: String) {
        guard let n = refs[key] else { return }
        if n > 1 { refs[key] = n - 1; return }
        refs[key] = nil
        entries[key] = nil
        if key == LocalMonitor.key { LocalMonitor.shared.stop() } else { ConnectionManager.shared.stopMonitor(key) }
    }

    /// Restart one that ended (a reconnect after a drop).
    func restart(_ key: String, interval: Double = 5) {
        guard refs[key] != nil, entries[key]?.status == .ended else { return }
        Task { await start(key, interval: interval) }
    }

    private func start(_ key: String, interval: Double) async {
        entries[key, default: Entry()].status = .starting
        entries[key]?.error = ""
        let r = key == LocalMonitor.key
            ? LocalMonitor.shared.start(interval: interval)
            : await ConnectionManager.shared.startMonitor(key, interval: interval)
        guard refs[key] != nil else { return }
        if !r.ok {
            entries[key]?.status = r.reason == "mfa" ? .mfa : .ended
            entries[key]?.error = r.error ?? "Could not start live stats"
        } else if entries[key]?.status == .starting, r.running {
            entries[key]?.status = .running
        }
    }

    private func listen() {
        guard token == nil else { return }
        token = ConnectionManager.shared.subscribe { ev in
            guard case .monitor(let id, let e) = ev else { return }
            MainActor.assumeIsolated { LiveStats.shared.apply(id, e) }
        }
    }

    private func apply(_ key: String, _ e: MonitorEvent) {
        guard refs[key] != nil else { return }
        var en = entries[key] ?? Entry()
        switch e {
        case .hello(let c, let i): en.hello = (c, i); en.status = .running
        case .sample(let s): en.last = s; en.status = .running
        case .unsupported: en.status = .unsupported
        case .ended(_, let err): en.status = .ended; en.error = err
        }
        entries[key] = en
    }
}
