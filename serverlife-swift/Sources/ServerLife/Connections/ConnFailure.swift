import Foundation

/// What a failed connect looked like, carried on the thrown `AppError.code`
/// (the original appended " [mfa]", " [hostkey]", " [authfail]" to the
/// message; here the message stays as shown and the code says which).
///
/// - "mfa": a Teleport node that seems to need per-session MFA — offer the
///   tsh transport rather than a retry that fails the same way.
/// - "hostkey": the host answered with a different key than known_hosts has
///   — offer to forget the stale entry (never done automatically).
/// - "authfail": a plain ssh host's "too many authentication failures" kind
///   of refusal — offer the authprobe replay (which keys were offered, in
///   what order).
///
/// One code per error; when two apply, the first of mfa, hostkey, authfail.
/// `Connection.lastErrorMfaLikely` / `lastErrorHostKeyChanged` /
/// `lastErrorAuthFailedLikely` carry each flag on its own.
struct ConnFailFlags: Equatable, Sendable {
    var mfa = false
    var hostKey = false
    var authFailed = false

    var code: String? {
        if mfa { return "mfa" }
        if hostKey { return "hostkey" }
        if authFailed { return "authfail" }
        return nil
    }

    static func from(_ e: AppError) -> ConnFailFlags {
        ConnFailFlags(mfa: e.code == "mfa", hostKey: e.code == "hostkey", authFailed: e.code == "authfail")
    }
}

extension ConnText {
    static let hostKeyChangedRE = re(#"REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed"#, ci: true)

    /// `looksLikeHostKeyChanged`: a host that answers with a *different* key
    /// than the one recorded for it — a rebuilt box, a reimaged VM. Distinct
    /// from a brand-new host, which `StrictHostKeyChecking accept-new`
    /// already trusts silently: this is ssh refusing outright.
    static func looksLikeHostKeyChanged(_ text: String) -> Bool { test(hostKeyChangedRE, text) }
}

extension Connection {
    /// `_explainVersion`: add the version mismatch to a failed Teleport
    /// connection, if there is one. A tsh the cluster does not support fails
    /// with whatever broke first — "ssh: no key found", a handshake error —
    /// and nothing in it says "versions". Unchanged when the versions are
    /// fine or cannot be read: the original error is the better answer then.
    func explainVersion(_ err: inout AppError) async -> Teleport.Compatibility? {
        guard type == "teleport" else { return nil }
        let c = await Teleport.compatFor(proxy: spec.node?.proxy, home: spec.tshHome)
        guard c.level == "warn" || c.level == "error" else { return nil }
        if let m = c.message?.nilIfEmpty { err.message = "\(err.message)\n\n\(m)" }
        return c
    }

    // MARK: conn:create's extra answers

    /// Forwarding only (-N), from the host's default or this opening's
    /// options: the window opens it as a tunnel, without the file browser.
    var noShell: Bool { spec.noShell }

    /// The options' forwards as summary lines (`-L …`, `-R …`, `SOCKS …`).
    var optionForwards: [String] {
        guard let o = spec.sshOptions else { return [] }
        return SSHOptions.summary(o).filter { $0.hasPrefix("-L") || $0.hasPrefix("-R") || $0.hasPrefix("SOCKS") }
    }
}
