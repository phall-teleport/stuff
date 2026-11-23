import Foundation
import CryptoKit

// decoders.js — an OpenSSH certificate, as `ssh-keygen -L` would print it.

struct SSHCertResult {
    struct Option: Equatable { var name: String; var value: String }
    struct Trait: Equatable { var name: String; var values: [String] }
    struct Readable: Equatable {
        var permissions: [String] = []
        var roles: [String] = []
        var traits: [Trait] = []
        var device: [Option] = []
        var teleport: [Option] = []
        var other: [Option] = []
        var restrictions: [Option] = []
    }
    var type: String
    var keyType: String
    var keyFingerprint: String
    var serial: String
    var keyId: String
    var principals: [String]
    var validAfter: String
    var validBefore: String
    var state: String
    var expiresIn: Int?
    var critical: [Option]
    var extensions: [Option]
    var teleport: Bool
    var ca: (type: String, fingerprint: String, signatureAlgorithm: String)
    var comment: String
    var readable: Readable
    var raw: String = ""
}

/// The SSH wire format's length-prefixed fields.
struct NTSSHReader {
    let buf: [UInt8]
    var o = 0
    init(_ b: [UInt8]) { buf = b }
    func need(_ n: Int) throws { if o + n > buf.count { throw AppError("The certificate is cut short.") } }
    mutating func u32() throws -> UInt32 {
        try need(4)
        let v = buf[o..<o + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        o += 4; return v
    }
    mutating func u64() throws -> UInt64 {
        try need(8)
        let v = buf[o..<o + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        o += 8; return v
    }
    mutating func bytes() throws -> [UInt8] {
        let n = Int(try u32()); try need(n)
        let v = Array(buf[o..<o + n]); o += n; return v
    }
    mutating func str() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
    var done: Bool { o >= buf.count }
}

extension NTDecode {
    static let keyFields: [String: Int] = [
        "ssh-rsa": 2, "ssh-dss": 4,
        "ecdsa-sha2-nistp256": 2, "ecdsa-sha2-nistp384": 2, "ecdsa-sha2-nistp521": 2,
        "ssh-ed25519": 1,
        "sk-ecdsa-sha2-nistp256@openssh.com": 3, "sk-ssh-ed25519@openssh.com": 2,
    ]
    static let forever = UInt64.max

    static func sshFingerprint(_ blob: [UInt8]) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// The name/value pairs of critical options or extensions.
    static func optionList(_ blob: [UInt8]) throws -> [SSHCertResult.Option] {
        var r = NTSSHReader(blob)
        var out: [SSHCertResult.Option] = []
        while !r.done {
            let name = try r.str()
            let data = try r.bytes()
            // A value is itself wrapped in a string; most extensions carry none.
            var value = ""
            if data.count >= 4, data[0..<4].reduce(0, { $0 << 8 | Int($1) }) == data.count - 4 {
                value = String(decoding: data[4...], as: UTF8.self)
            } else if !data.isEmpty { value = String(decoding: data, as: UTF8.self) }
            out.append(.init(name: name, value: value))
        }
        return out
    }

    /// An OpenSSH certificate, from the `...-cert.pub` line or just its
    /// base64. Teleport's own extensions come through as they are.
    static func sshCert(_ input: String, now: Double = Date().timeIntervalSince1970 * 1000) throws -> SSHCertResult {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let b64 = fields.first(where: { $0.range(of: "^AAAA[0-9A-Za-z+/=]+$", options: .regularExpression) != nil }),
              let blobData = Data(base64Encoded: b64.padding(toLength: (b64.count + 3) / 4 * 4, withPad: "=", startingAt: 0))
        else { throw AppError("Paste the certificate line from a -cert.pub file.") }
        var r = NTSSHReader(Array(blobData))
        let certType = try r.str()
        guard certType.hasSuffix("-cert-v01@openssh.com") else {
            throw AppError("\"\(certType)\" is a plain key, not a certificate.")
        }
        let keyType = String(certType.dropLast("-cert-v01@openssh.com".count))
        guard let nParts = keyFields[keyType] else { throw AppError("Unknown certificate key type \(keyType).") }
        _ = try r.bytes() // nonce
        // The certified public key, re-wrapped as a plain key to fingerprint it.
        var plain: [UInt8] = []
        func wrap(_ b: [UInt8]) {
            let n = UInt32(b.count)
            plain += [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + b
        }
        wrap(Array(keyType.utf8))
        for _ in 0..<nParts { wrap(try r.bytes()) }
        let serial = try r.u64()
        let type = try r.u32()
        let keyId = try r.str()
        var pr = NTSSHReader(try r.bytes())
        var principals: [String] = []
        while !pr.done { principals.append(try pr.str()) }
        let after = try r.u64()
        let before = try r.u64()
        let critical = try optionList(try r.bytes())
        let extensions = try optionList(try r.bytes())
        _ = try r.bytes() // reserved
        let caBlob = try r.bytes()
        var cr = NTSSHReader(caBlob)
        let caType = try cr.str()
        var sigAlg = ""
        // A cut-short signature still decodes the rest.
        if let sig = try? r.bytes() { var sr = NTSSHReader(sig); sigAlg = (try? sr.str()) ?? "" }

        let t: (UInt64) -> String = { $0 == forever ? "forever" : ntISO(ms: Double($0) * 1000) }
        let nowS = UInt64(max(0, (now / 1000).rounded(.down)))
        let state = nowS < after ? "not yet valid" : (before != forever && nowS >= before ? "expired" : "valid")
        let teleport = extensions.contains { $0.name.contains("teleport") || $0.name.hasPrefix("login@") }
        let typeName = type == 1 ? "user" : type == 2 ? "host" : "unknown (\(type))"
        var out = SSHCertResult(
            type: typeName, keyType: keyType, keyFingerprint: sshFingerprint(plain), serial: String(serial),
            keyId: keyId, principals: principals, validAfter: t(after), validBefore: t(before), state: state,
            expiresIn: before == forever ? nil : Int(Int64(bitPattern: before &- nowS)),
            critical: critical, extensions: extensions, teleport: teleport,
            ca: (caType, sshFingerprint(caBlob), sigAlg),
            comment: fields.count > 2 ? fields[2...].joined(separator: " ") : "",
            readable: readableExtensions(extensions, critical))
        out.raw = keygenListing(certType, out, after: after, before: before)
        return out
    }

    /// What each `permit-*` extension lets the holder do, in words.
    static let permits: [String: String] = [
        "permit-pty": "Interactive terminal",
        "permit-port-forwarding": "Port forwarding",
        "permit-agent-forwarding": "Agent forwarding",
        "permit-X11-forwarding": "X11 forwarding",
        "permit-user-rc": "Run ~/.ssh/rc",
        "no-touch-required": "No security-key touch",
        "verify-required": "Security-key PIN",
    ]

    /// Teleport's extensions, with names a person would use.
    static let teleportNames: [String: String] = [
        "teleport-route-to-cluster": "Cluster",
        "login-ip": "Login IP",
        "private-key-policy": "Private key policy",
        "teleport-active-requests": "Active access requests",
        "teleport-allowed-resources": "Allowed resources",
        "teleport-previous-identity-expires": "Previous identity expires",
        "teleport-disallow-reissue": "Reissue",
        "teleport-renewable": "Renewable",
        "teleport-generation": "Generation",
        "teleport-impersonator": "Impersonated by",
        "teleport-bot": "Machine ID bot",
        "teleport-bot-instance-id": "Bot instance",
        "teleport-join-token": "Join token",
        "teleport-pin-ip": "Pinned to IP",
        "teleport-mfa-verified": "MFA verified",
        "teleport-connection-diagnostic-id": "Connection diagnostic",
        "teleport-request-reason": "Request reason",
    ]

    /// The extensions sorted into what a reader asks about. Values that are
    /// JSON are parsed; names lose their `@domain` and `teleport-` noise.
    static func readableExtensions(_ extensions: [SSHCertResult.Option], _ critical: [SSHCertResult.Option]) -> SSHCertResult.Readable {
        var out = SSHCertResult.Readable()
        for e in extensions {
            let bare = e.name.replacingOccurrences(of: "@[^@]+$", with: "", options: .regularExpression)
            let value = e.value
            if let p = permits[bare] { out.permissions.append(p); continue }
            if bare == "teleport-roles" {
                let j = try? JSON.parse(value)
                if let roles = j?["roles"].array { out.roles = roles.map(ntJSString) } else { out.roles = value.isEmpty ? [] : [value] }
                continue
            }
            if bare == "teleport-traits" {
                let j = (try? JSON.parse(value))?.object ?? [:]
                out.traits = j.map { k, v in
                    SSHCertResult.Trait(name: k, values: (v.array ?? [v]).filter { $0 != .string("") && !$0.isNull }.map(ntJSString))
                }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                continue
            }
            if bare.hasPrefix("teleport-device-") {
                let label = ["teleport-device-id": "Device ID", "teleport-device-asset-tag": "Asset tag",
                             "teleport-device-credential-id": "Credential ID"][bare]
                    ?? String(bare.dropFirst("teleport-device-".count))
                out.device.append(.init(name: label, value: value))
                continue
            }
            if teleportNames[bare] != nil || bare.hasPrefix("teleport-") {
                let j: JSON? = value.first.map { "[{".contains($0) } == true ? (try? JSON.parse(value)) : nil
                let label = teleportNames[bare]
                    ?? String(bare.dropFirst("teleport-".count)).replacingOccurrences(of: "-", with: " ")
                out.teleport.append(.init(name: label.prefix(1).uppercased() + label.dropFirst(),
                                          value: j.map { $0.jsText() } ?? (value.isEmpty ? "yes" : value)))
                continue
            }
            out.other.append(e)
        }
        for c in critical {
            let label = ["force-command": "Only runs", "source-address": "Only from"][c.name] ?? c.name
            out.restrictions.append(.init(name: label, value: c.value.isEmpty ? "(set)" : c.value))
        }
        return out
    }

    /// The way `ssh-keygen -L` lays a certificate out, for the Raw view.
    static func keygenListing(_ certType: String, _ c: SSHCertResult, after: UInt64, before: UInt64) -> String {
        func algo(_ t: String) -> String {
            ["ssh-ed25519": "ED25519", "ssh-rsa": "RSA", "ssh-dss": "DSA",
             "sk-ssh-ed25519@openssh.com": "ED25519-SK", "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK"][t]
                ?? (t.hasPrefix("ecdsa-") ? "ECDSA" : t.uppercased())
        }
        // Local time without a zone, as ssh-keygen prints it.
        func ts(_ v: UInt64) -> String {
            if v == forever { return "forever" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f.string(from: Date(timeIntervalSince1970: TimeInterval(v)))
        }
        func list(_ items: [String]) -> String {
            items.isEmpty ? " (none)" : "\n" + items.map { "                " + $0 }.joined(separator: "\n")
        }
        let opt: (SSHCertResult.Option) -> String = { "\($0.name) \($0.value)".trimmingCharacters(in: .whitespaces) }
        return [
            "Type: \(certType) \(c.type) certificate",
            "Public key: \(algo(c.keyType))-CERT \(c.keyFingerprint)",
            "Signing CA: \(algo(c.ca.type)) \(c.ca.fingerprint)\(c.ca.signatureAlgorithm.isEmpty ? "" : " (using \(c.ca.signatureAlgorithm))")",
            "Key ID: \"\(c.keyId)\"",
            "Serial: \(c.serial)",
            "Valid: \(after == 0 && before == forever ? "forever" : "from \(ts(after)) to \(ts(before))")",
            "Principals:\(list(c.principals))",
            "Critical Options:\(list(c.critical.map(opt)))",
            "Extensions:\(list(c.extensions.map(opt)))",
        ].map { "        " + $0 }.joined(separator: "\n")
    }
}
