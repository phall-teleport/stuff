import AppKit

/// sessions.js `ensureLoggedIn` / `relogin` / `connectWithRelogin`: make sure
/// a Teleport connection's cluster is logged in, and has had a moment to
/// settle, *before* dialling it — rather than finding out from a failed
/// connect and reacting afterward, which always raced a login that had not
/// started yet. Shared by the shell path (`connectPane`); tmux and the file
/// explorer can call `SessRelogin.connect` too.
@MainActor
enum SessRelogin {
    /// How long a login just performed here is trusted without doing it
    /// again: a manual Retry moments after one is a fresh call, and without
    /// this read as "not logged in" all over again (SSO round trip included).
    static let trustMs: Double = 15000
    /// How long a login must have had before the first real connect: `tsh
    /// login` returning means the cluster says yes, not that the node is
    /// reachable the instant it does.
    static let minSettleMs: Double = 3000
    static let settleDelaysMs: [UInt64] = [1200, 2000, 3000, 4000]

    private static var recent: [String: Double] = [:]
    /// One login ceremony per cluster at a time, however many callers race it.
    private static var inFlight: [String: Task<Double?, Error>] = [:]

    static func key(proxy: String?, home: String?) -> String { "\(proxy ?? "")|\(home ?? "")" }

    /// `window.api.conn.connect`, having first made sure the cluster is
    /// logged in. A failure that still looks like "needs MFA" afterwards gets
    /// a few more tries with a growing wait — unless the host is already
    /// known to need MFA, where it would fail identically every time.
    static func connect(_ connId: String, background: Bool = false, window: WindowModel? = nil) async throws {
        let c = ConnectionManager.shared.connection(connId)
        if let c { try await ensureLoggedIn(c, background: background, window: window) }
        do { try await ConnectionManager.shared.connect(connId) } catch {
            let msg = (error as? AppError)?.message ?? error.localizedDescription
            let mfa = (error as? AppError)?.code == "mfa" || msg.hasSuffix(" [mfa]")
            guard mfa, let c, c.type == "teleport", c.spec.node?.proxy?.isEmpty == false else { throw error }
            if let h = c.hostId, HostPrefs.isMfaHost(h) { throw error }
            var last: Error = error
            for ms in settleDelaysMs {
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
                do { try await ConnectionManager.shared.connect(connId); return } catch { last = error }
            }
            throw last
        }
    }

    static func ensureLoggedIn(_ c: Connection, background: Bool, window: WindowModel?) async throws {
        guard c.type == "teleport", let proxy = c.spec.node?.proxy, !proxy.isEmpty else { return }
        let home = c.spec.tshHome
        let k = key(proxy: Teleport.proxyAddress(proxy), home: home)
        if let at = recent[k], nowMs() - at < trustMs {
            await settle(since: at)
            return
        }
        let task: Task<Double?, Error>
        if let t = inFlight[k] { task = t } else {
            task = Task { @MainActor in try await relogin(c, proxy: proxy, home: home, key: k, background: background, window: window) }
            inFlight[k] = task
        }
        defer { if inFlight[k] == task { inFlight[k] = nil } }
        guard let at = try await task.value else { return }
        await settle(since: at)
    }

    private static func settle(since at: Double) async {
        let remaining = minSettleMs - (nowMs() - at)
        if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining) * 1_000_000) }
    }

    /// The login ceremony for one lapsed cluster. Returns when it logged in
    /// (ms), or nil when nothing here logged in (already in, or declined).
    private static func relogin(_ c: Connection, proxy: String, home: String?, key k: String,
                                background: Bool, window: WindowModel?) async throws -> Double? {
        if background && Teleport.wasLoggedOutDeliberately(proxy: proxy, home: c.spec.node?.home) { return nil }
        // A fresh read, not the inventory's copy — that can be tens of
        // seconds stale, and a cluster logged into since then (by hand, by
        // another window, by tsh's own renewal) would still read expired.
        let fresh = await Teleport.status().profiles
        let profiles = fresh.isEmpty ? Inventory.shared.profiles : fresh
        let dir = home ?? TeleportHomes.defaultHome
        let prof = profiles.first { Teleport.proxyAddress($0.proxy) == Teleport.proxyAddress(proxy) && $0.homeDir == dir }
        if let prof, !prof.expired { return nil }
        let cluster = c.host.cluster
        if !background, !(await confirmLoginNeeded(cluster: cluster, proxy: proxy, window: window)) {
            throw AppError("Login cancelled — \(cluster?.nilIfEmpty ?? proxy) needs a fresh login to connect")
        }
        let p = prof ?? TeleportProfile(proxy: proxy, cluster: cluster ?? "", home: c.spec.node?.home, homeDir: dir)
        guard await TeleportPanel.doLogin(p, window: window) else { return nil }
        let at = nowMs()
        recent[k] = at
        return at
    }

    /// Ask before logging back in, unless told not to: a browser tab, a
    /// terminal or a Touch ID prompt nobody explicitly asked for should not
    /// just happen (the same reasoning as confirmClosing).
    static func confirmLoginNeeded(cluster: String?, proxy: String, window: WindowModel?) async -> Bool {
        if Store.shared.setting("confirmLoginToConnect", true) == false { return true }
        let whereName = cluster?.nilIfEmpty ?? proxy
        let alert = NSAlert()
        alert.messageText = "Log in to \(whereName)?"
        alert.informativeText = "\(whereName)'s session has lapsed. Connecting means logging back in first — "
            + "a browser tab, a terminal, or a Touch ID prompt, depending on how this cluster authenticates."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not ask again"
        alert.suppressionButton?.state = .off
        alert.addButton(withTitle: "Log in")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let ok: Bool
        if let w = (window?.nsWindow ?? NSApp.keyWindow) {
            ok = await withCheckedContinuation { cont in
                alert.beginSheetModal(for: w) { cont.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        } else {
            ok = alert.runModal() == .alertFirstButtonReturn
        }
        if ok && alert.suppressionButton?.state == .on {
            Store.shared.setSetting("confirmLoginToConnect", false)
            StatusBus.shared.show("Won’t ask before logging in again — turn it back on in Settings")
        }
        return ok
    }
}
