import Foundation

// Free space in the footer (explorer.js `_loadDisk`/`diskBadge`, local.js
// `diskSpace`, connections.js `diskSpace`), "No background commands on
// servers" (files.js `quietRemote`), and the connect-failure wording
// (`explainConnectError`, `isMfaHost`).

/// Free and total bytes on the volume holding a folder.
struct XPDisk: Equatable, Sendable {
    var free: Double
    var total: Double
}

extension Store {
    /// Settings → "No background commands on servers" (enforced in main as well).
    var xpQuietRemote: Bool { settingJSON("quietRemote").bool == true }
    /// Hosts remembered as needing per-session MFA (host ids).
    var xpMfaHosts: [String] { settingJSON("mfaHosts").stringArray }
}

extension XP {
    /// `isMfaHost(id)`: the host is known to need per-session MFA.
    @MainActor
    static func isMfaHost(_ id: String?) -> Bool {
        guard let id else { return false }
        return Store.shared.xpMfaHosts.contains(id)
    }

    /// A connect failure shown in the file list, with the one thing worth
    /// saying about a failure that looks like per-session MFA.
    static func explainConnectError(_ message: String, mfa: Bool = false) -> String {
        if message.hasSuffix(" [mfa]") { return String(message.dropLast(6)) + " (MFA may be required)" }
        return mfa ? message + " (MFA may be required)" : message
    }

    static func explainConnectError(_ error: Error) -> String {
        let e = error as? AppError
        return explainConnectError(e?.message ?? error.localizedDescription, mfa: e?.code == "mfa")
    }

    /// `df -Pk` output → bytes; nil when it is not a usable answer.
    static func parseDf(_ stdout: String) -> XPDisk? {
        let lines = stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }
        let cols = lines[1].trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard cols.count > 3, let t = Double(cols[1]), let f = Double(cols[3]) else { return nil }
        let total = t * 1024, free = f * 1024
        if !total.isFinite || !free.isFinite || total <= 0 { return nil }
        return XPDisk(free: free, total: total)
    }

    /// "38.9 GB free of 48.3 GB", first in the footer, coloured by how much is
    /// left: ordinary above 20% free, amber with a warning sign below it, red
    /// with a stop sign below 10% — the point at which a log rotation or a
    /// deploy that writes a few gigabytes is a real risk, not a theoretical one.
    static func diskBadge(_ d: XPDisk) -> (text: String, level: String, tooltip: String) {
        let pct = d.total > 0 ? d.free / d.total : 1
        let level = pct < 0.10 ? "danger" : pct < 0.20 ? "warn" : ""
        let icon = level == "danger" ? "⛔ " : level == "warn" ? "⚠ " : ""
        return ("\(icon)\(Fmt.bytes(d.free)) free of \(Fmt.bytes(d.total)) · ", level,
                "\(Int((pct * 100).rounded()))% free on this volume")
    }

    /// local.js `diskSpace`: `bavail`, not `bfree` — the blocks reserved for
    /// root are not space this account can write into.
    static func localDiskSpace(_ path: String) -> XPDisk? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let bs = Double(st.f_bsize)
        let total = Double(st.f_blocks) * bs
        guard total > 0 else { return nil }
        return XPDisk(free: Double(st.f_bavail) * bs, total: total)
    }

    /// connections.js `diskSpace`: `df` over the session — refused where the
    /// transport was chosen for per-session MFA (that exec would cost an
    /// approval), and while not connected.
    @MainActor
    static func remoteDiskSpace(_ connId: String, _ dir: String) async -> XPDisk? {
        // "No background commands on servers" (conn:diskSpace).
        if Store.shared.xpQuietRemote { return nil }
        guard let c = ConnectionManager.shared.connection(connId) else { return nil }
        if c.transport == .tsh && !c.tshByNecessity { return nil }
        if c.state != .connected { return nil }
        let q = "'" + (dir.isEmpty ? "." : dir).replacingOccurrences(of: "'", with: "'\\''") + "'"
        let r = await c.execResult("df -Pk -- \(q) 2>/dev/null", timeout: 8)
        return parseDf(r.out)
    }
}

/// Disk space per `sourceKey|folder`, remembered for half a minute.
@MainActor
enum XPDiskCache {
    static var map: [String: (at: Double, disk: XPDisk?)] = [:]
}

extension ExplorerModel {
    /// Free and total space on the volume the listed folder lives on, for the
    /// footer. Asked after the listing, never before it — a slow `df` must not
    /// hold up the files — and remembered for half a minute per folder, so a
    /// refresh or a quick back-and-forth does not run it again for an answer
    /// that cannot have moved. Buckets and pods have no such thing; a host
    /// that cannot answer cheaply (per-session MFA) just shows no figure.
    func loadDisk() async {
        let view = self.view
        guard let dir = view.path, !dir.isEmpty, isLocal || isRemote else { view.disk = nil; return }
        // "No background commands on servers": no df on a host by itself.
        if isRemote && Store.shared.xpQuietRemote { view.disk = nil; return }
        let key = sourceKey + "|" + dir
        if let hit = XPDiskCache.map[key], nowMs() - hit.at < 30000 { view.disk = hit.disk; return }
        var disk: XPDisk?
        if isLocal {
            disk = await Task.detached { XP.localDiskSpace(dir) }.value
        } else if let connId {
            disk = await XP.remoteDiskSpace(connId, dir)
        }
        XPDiskCache.map[key] = (nowMs(), disk)
        // Still the same folder? A fast click elsewhere would otherwise get
        // the wrong volume's numbers painted under it.
        if self.view === view && view.path == dir { view.disk = disk }
    }
}
