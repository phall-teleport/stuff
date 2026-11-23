import Foundation

/// sshbin.js `sshVersion` / `parseSshVersion` / `supportsFeature`: which
/// OpenSSH the app runs, so a stale system client (the macOS-shipped one is
/// a frequent offender) can be named as the reason something does not work,
/// instead of a bare "that flag isn't understood".
enum SSHVersion {
    struct Info: Equatable, Sendable {
        var raw: String
        var major: Int?
        var minor: Int?
        var patch: Int?

        var json: JSON {
            ["raw": .string(raw), "major": major.map { .number(Double($0)) } ?? .null,
             "minor": minor.map { .number(Double($0)) } ?? .null, "patch": patch.map { .number(Double($0)) } ?? .null]
        }
    }

    /// The minimum OpenSSH release a feature needs.
    static let featureMinVersion: [String: (Int, Int)] = [
        "securityKeyIdentities": (8, 2),  // ed25519-sk / ecdsa-sk (FIDO2) keys
        "proxyJumpFlag": (7, 3),          // -J, rather than a ProxyCommand workaround
        "certificateFiles": (5, 6),       // CertificateFile in ssh_config
    ]

    /// `ssh -V`'s one-line banner ("OpenSSH_9.4p1, LibreSSL 3.3.6") as numbers.
    static func parse(_ text: String) -> Info {
        let raw = text.trimmed
        let re = try! NSRegularExpression(pattern: #"OpenSSH[_ ](?:for_Windows_)?(\d+)\.(\d+)(?:p(\d+))?"#,
                                          options: .caseInsensitive)
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else {
            return Info(raw: raw, major: nil, minor: nil, patch: nil)
        }
        func g(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i))) }
        return Info(raw: raw, major: g(1), minor: g(2), patch: g(3) ?? 0)
    }

    nonisolated(unsafe) private static var cache: (path: String, info: Info?)?
    private static let lock = NSLock()

    /// The resolved ssh's version, cached per path. OpenSSH prints it to
    /// stderr and exits 0. nil when it cannot be read.
    static func current() -> Info? {
        let path = Tools.ssh
        lock.lock()
        if let c = cache, c.path == path { lock.unlock(); return c.info }
        lock.unlock()
        let r = Proc.runSync(path, ["-V"], timeout: 5)
        let text = r.err.trimmed.isEmpty ? r.out : r.err
        let info = text.trimmed.isEmpty ? nil : parse(text)
        lock.lock(); cache = (path, info); lock.unlock()
        return info
    }

    /// Unknown feature or unreadable version: never block on what can't be checked.
    static func supports(_ feature: String, version: Info?? = .none) -> Bool {
        guard let min = featureMinVersion[feature] else { return true }
        let v: Info? = version ?? current()
        guard let v, let major = v.major else { return true }
        if major != min.0 { return major > min.0 }
        return (v.minor ?? 0) >= min.1
    }
}
