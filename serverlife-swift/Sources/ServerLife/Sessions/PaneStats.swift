import Foundation

/// Live stats under a server session: CPU, memory, swap, load, disk and
/// network for the host the pane is connected to, as MobaXterm's bar shows
/// (monitor.js).
///
/// The numbers come from one long-running command per connection, not a
/// command per sample — on a Teleport node every exec is an audit-log
/// session. Every pane on a connection shares that one command: the first
/// pane starts it, the last one to go stops it.
///
/// Off where it would cost something it should not: a per-session-MFA host
/// would ask for an approval, so the bar says it is off there and asks for
/// nothing. Off everywhere with Settings → "Live stats under each server
/// session", or for one host from the pane's menu.
///
/// A local shell has the same bar for this computer, kept as the connection
/// "local". The commands themselves are the connections owner's
/// (`LiveStats`, ConnMonitor); this decides who shows a bar and keeps the
/// CPU history for the sparkline. Hiding it from a local
/// pane's menu is remembered (settings.localStats) — it is the same computer
/// every time.
@MainActor @Observable
final class PaneStats {
    static let shared = PaneStats()
    static let history = 40                 // samples kept for the CPU sparkline
    static let local = LocalMonitor.key

    typealias Status = LiveStats.Status

    /// CPU history (the last `history` samples) per machine, and the OS a
    /// host without /proc reported.
    private(set) var samples: [String: [MonitorSample]] = [:]
    private(set) var unsupportedOS: [String: String] = [:]
    @ObservationIgnored private var panesOn: [String: [String]] = [:]   // key -> pane ids, in order
    @ObservationIgnored private var hiddenConns = Set<String>()
    @ObservationIgnored private var token: UUID?

    private func listen() {
        guard token == nil else { return }
        token = ConnectionManager.shared.subscribe { ev in
            guard case .monitor(let id, let e) = ev else { return }
            MainActor.assumeIsolated { PaneStats.shared.took(id, e) }
        }
    }

    private func took(_ k: String, _ e: MonitorEvent) {
        guard panesOn[k] != nil else { return }
        switch e {
        case .sample(let s):
            var all = samples[k] ?? []
            all.append(s)
            if all.count > Self.history { all.removeFirst(all.count - Self.history) }
            samples[k] = all
        case .unsupported(let os): unsupportedOS[k] = os
        default: break
        }
    }

    func status(_ k: String) -> Status { LiveStats.shared.entries[k]?.status ?? .starting }
    func entry(_ k: String) -> LiveStats.Entry? { LiveStats.shared.entries[k] }

    // MARK: who gets a bar

    private func setting(_ k: String) -> JSON { Store.shared.settingJSON(k) }
    /// Settings → "No background commands on servers" outranks the stats switch.
    var enabled: Bool { setting("liveStats").bool != false && setting("quietRemote").bool != true }
    /// No background commands on servers does not touch this computer; the
    /// stats switch and a hidden local bar do.
    private var localEnabled: Bool { setting("liveStats").bool != false && setting("localStats").bool != false }
    /// Settings → "One live stats bar per machine in a tab".
    private var onePerTab: Bool { setting("statsOncePerTab").bool == true }

    /// A server session or a tmux pane on one: both ride a connection to the host.
    private func onAHost(_ p: SessionPane) -> Bool { (p.kind == .remote || p.kind == .tmux) && p.connId != nil }
    /// A plain local shell, where this computer can be read.
    private func isLocal(_ p: SessionPane) -> Bool { p.kind == .local && p.plainShell }
    private func monitored(_ p: SessionPane) -> Bool { onAHost(p) || isLocal(p) }
    private func key(_ p: SessionPane) -> String { isLocal(p) ? Self.local : (p.connId ?? "") }
    private func enabled(for p: SessionPane) -> Bool {
        isLocal(p) ? localEnabled : enabled && !hiddenConns.contains(p.connId ?? "")
    }

    private var allPanes: [SessionPane] {
        SessionsCore.allWindows().flatMap { s in s.tabs.flatMap { t in s.panesOf(t.id).compactMap { s.pane($0) } } }
    }
    private func pane(_ id: String) -> SessionPane? { allPanes.first { $0.id == id } }
    private func shownInTab(_ p: SessionPane, _ k: String) -> Bool {
        allPanes.contains { $0 !== p && $0.tabId == p.tabId && $0.statsKey != nil && key($0) == k }
    }

    /// The pane menu offers "Show/Hide live stats" only for these.
    func canShow(_ p: SessionPane) -> Bool { monitored(p) }
    func hasBar(_ p: SessionPane) -> Bool { p.statsKey != nil }

    // MARK: attach / detach

    /// Start (or join) the monitor for a pane, and give it its bar.
    func attach(_ p: SessionPane) {
        guard monitored(p), enabled(for: p) else { return }
        let k = key(p)
        if p.statsKey == nil && onePerTab && shownInTab(p, k) { return }
        // Already showing: a reconnect restarts a monitor the drop ended.
        if p.statsKey != nil {
            if status(k) == .ended { LiveStats.shared.restart(k) }
            return
        }
        listen()
        var on = panesOn[k] ?? []
        if !on.contains(p.id) { on.append(p.id) }
        panesOn[k] = on
        p.statsKey = k
        LiveStats.shared.attach(k)
    }

    /// A pane going away leaves its connection's monitor; the last one stops it.
    func detach(_ p: SessionPane) {
        guard let k = p.statsKey else { return }
        p.statsKey = nil
        panesOn[k]?.removeAll { $0 == p.id }
        // One bar per machine in a tab: the next pane on it takes the bar
        // over — unless the bar is being hidden. It joins before this one
        // leaves, so the command keeps running.
        if onePerTab && enabled(for: p),
           let next = allPanes.first(where: { $0 !== p && $0.tabId == p.tabId && $0.statsKey == nil && monitored($0) && key($0) == k }) {
            attach(next)
        }
        LiveStats.shared.detach(k)
        if panesOn[k]?.isEmpty == true { panesOn[k] = nil; samples[k] = nil; unsupportedOS[k] = nil }
    }

    /// The bar's Restart button.
    func restart(_ k: String) { LiveStats.shared.restart(k) }

    // MARK: menu and settings

    /// Hide or show the bar for every pane on this pane's host, until restart.
    func toggle(_ p: SessionPane) {
        if isLocal(p) {
            // Every local shell at once, and remembered: it is this computer each time.
            let showing = p.statsKey != nil
            Store.shared.setSetting("localStats", !showing)
            for q in allPanes where isLocal(q) { showing ? detach(q) : attach(q) }
            return
        }
        guard let c = p.connId else { return }
        let panes = allPanes.filter { $0.connId == c }
        if p.statsKey != nil {
            hiddenConns.insert(c)
            for q in panes { detach(q) }
        } else {
            hiddenConns.remove(c)
            for q in panes { attach(q) }
        }
    }

    /// Settings changed: bring every pane in line with the switch.
    func applySetting() {
        let panes = allPanes.filter(monitored)
        for (i, p) in panes.enumerated() {
            // Turned on: the extra bars in a tab go first, so the first pane keeps its own.
            let extra = onePerTab && p.statsKey != nil && panes.prefix(i).contains {
                $0.tabId == p.tabId && $0.statsKey != nil && key($0) == key(p)
            }
            if !enabled(for: p) || extra { detach(p) }
        }
        for p in panes where enabled(for: p) { attach(p) }
    }
}
