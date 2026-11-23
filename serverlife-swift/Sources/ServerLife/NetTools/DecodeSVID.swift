import Foundation

// decoders.js — a SPIFFE X.509-SVID, and the tsh certificates the SSH
// certificate decoder offers (decode:tshCerts).

struct SVIDResult {
    struct Cert {
        var subject, issuer: String
        var spiffeId: String?
        var sans: [String]
        var serial: String
        var validFrom, validTo: String
        var state: String
        var expiresIn: Int
        var ca: Bool
        var keyUsage: [String]
        var publicKey: String
        var fingerprint256: String
        var signedByNext: Bool?
        var problems: [String]
    }
    var certificates: [Cert]
    var spiffeId: String?
    var ok: Bool
    var pem: String
}

struct TshCert: Equatable {
    var proxy, user, cluster, home, file: String
    var mtime: Double
    var text: String = ""
}

extension NTDecode {
    static func pemBlocks(_ text: String) -> [[UInt8]] {
        let re = try! NSRegularExpression(pattern: "-----BEGIN CERTIFICATE-----([\\s\\S]+?)-----END CERTIFICATE-----")
        let ns = text as NSString
        let blocks = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m -> [UInt8]? in
            let b64 = ns.substring(with: m.range(at: 1)).filter { !$0.isWhitespace }
            return Data(base64Encoded: b64).map { Array($0) }
        }
        if !blocks.isEmpty { return blocks }
        // Bare base64 DER, as some tools print it.
        let b64 = text.filter { !$0.isWhitespace }
        if b64.range(of: "^MI[0-9A-Za-z+/=]+$", options: .regularExpression) != nil, let d = Data(base64Encoded: b64) {
            return [Array(d)]
        }
        return []
    }

    /// An X.509-SVID and any chain pasted with it: who it names, who issued
    /// it, when it is good for, and whether it keeps the SPIFFE rules — one URI
    /// SAN that is a spiffe:// ID, a leaf that is not a CA. Each certificate is
    /// also checked against the next one in the paste, which is as far as a
    /// chain can be followed without the trust bundle.
    static func svid(_ input: String, now: Double = Date().timeIntervalSince1970 * 1000) throws -> SVIDResult {
        let blocks = pemBlocks(input)
        if blocks.isEmpty {
            if input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ey") {
                throw AppError("That is a JWT — use the JWT decoder for a JWT-SVID.")
            }
            throw AppError("Paste a PEM certificate (-----BEGIN CERTIFICATE-----).")
        }
        let certs = try blocks.map { try NTX509(der: $0) }
        let pem = certs.map(\.pem).joined(separator: "\n")
        let described = certs.enumerated().map { i, c -> SVIDResult.Cert in
            let sans = c.subjectAltName.components(separatedBy: ", ").filter { !$0.isEmpty }
            let uris = sans.filter { $0.hasPrefix("URI:") }.map { String($0.dropFirst(4)) }
            let spiffe = uris.filter { $0.hasPrefix("spiffe://") }
            var problems: [String] = []
            if i == 0 {
                if spiffe.isEmpty { problems.append("No spiffe:// URI in the subject alternative names.") }
                if uris.count > 1 { problems.append("An SVID carries exactly one URI SAN; this has \(uris.count).") }
                if c.ca { problems.append("A leaf SVID must not be a CA certificate.") }
                for id in spiffe {
                    guard let m = NetCheck.firstMatch("^spiffe://([^/]+)(/.*)?$", id), let domain = m[1] else {
                        problems.append("\(id) is not a well-formed SPIFFE ID."); continue
                    }
                    if domain != domain.lowercased() { problems.append("The trust domain must be lower case.") }
                    let p = m.count > 2 ? m[2] : nil
                    if p == nil || p == "/" { problems.append("A workload SVID needs a path after the trust domain.") }
                }
            }
            let next = i + 1 < certs.count ? certs[i + 1] : nil
            return SVIDResult.Cert(
                subject: c.subject.replacingOccurrences(of: "\n", with: ", "),
                issuer: c.issuer.replacingOccurrences(of: "\n", with: ", "),
                spiffeId: spiffe.first, sans: sans, serial: c.serialNumber,
                validFrom: ntISO(ms: c.validFrom), validTo: ntISO(ms: c.validTo),
                state: now < c.validFrom ? "not yet valid" : now >= c.validTo ? "expired" : "valid",
                expiresIn: Int(((c.validTo - now) / 1000).rounded(.toNearestOrAwayFromZero)),
                ca: c.ca, keyUsage: c.keyUsage, publicKey: c.publicKey, fingerprint256: c.fingerprint256,
                signedByNext: next.map { c.signed(by: $0) }, problems: problems)
        }
        return SVIDResult(certificates: described, spiffeId: described[0].spiffeId,
                          ok: described[0].problems.isEmpty, pem: pem)
    }

    /// The SSH certificates tsh has issued, under each Teleport home, so the
    /// decoder can offer "mine" rather than asking for a paste. Laid out as
    /// `<home>/keys/<proxy>/<user>-ssh/<cluster>-cert.pub`; newest first.
    static func tshCertificates(homes: [String]) -> [TshCert] {
        let fm = FileManager.default
        var out: [TshCert] = []
        for home in homes {
            let keys = (home as NSString).appendingPathComponent("keys")
            guard let proxies = try? fm.contentsOfDirectory(atPath: keys) else { continue }
            for proxy in proxies {
                let pdir = (keys as NSString).appendingPathComponent(proxy)
                guard let dirs = try? fm.contentsOfDirectory(atPath: pdir) else { continue }
                for d in dirs where d.hasSuffix("-ssh") {
                    let ddir = (pdir as NSString).appendingPathComponent(d)
                    guard let files = try? fm.contentsOfDirectory(atPath: ddir) else { continue }
                    for f in files where f.hasSuffix("-cert.pub") {
                        let file = (ddir as NSString).appendingPathComponent(f)
                        let m = (try? fm.attributesOfItem(atPath: file)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                        out.append(TshCert(proxy: proxy, user: String(d.dropLast(4)), cluster: String(f.dropLast(9)),
                                           home: home, file: file, mtime: m * 1000))
                    }
                }
            }
        }
        return out.sorted { $0.mtime > $1.mtime }
    }
}
