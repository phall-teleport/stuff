import Foundation
import CryptoKit
import Security

// Just enough DER to read an X.509 certificate the way Node's
// crypto.X509Certificate presented it (decoders.js svid()).

struct NTDER {
    var tag: UInt8
    var content: ArraySlice<UInt8>
    var whole: ArraySlice<UInt8>

    static func parse(_ b: ArraySlice<UInt8>) throws -> (NTDER, ArraySlice<UInt8>) {
        let bad = AppError("The certificate is not valid DER.")
        var i = b.startIndex
        guard i < b.endIndex else { throw bad }
        let tag = b[i]; i += 1
        guard i < b.endIndex else { throw bad }
        var len = Int(b[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, i + n <= b.endIndex else { throw bad }
            len = b[i..<i + n].reduce(0) { $0 << 8 | Int($1) }
            i += n
        }
        guard i + len <= b.endIndex else { throw bad }
        return (NTDER(tag: tag, content: b[i..<i + len], whole: b[b.startIndex..<i + len]), b[(i + len)...])
    }

    /// The elements inside a constructed one.
    func children() throws -> [NTDER] {
        var out: [NTDER] = []
        var rest = content
        while !rest.isEmpty { let (e, r) = try NTDER.parse(rest); out.append(e); rest = r }
        return out
    }

    var oid: String {
        let b = Array(content)
        guard let f = b.first else { return "" }
        var parts = [Int(f) / 40, Int(f) % 40]
        var v = 0
        for x in b.dropFirst() {
            v = v << 7 | Int(x & 0x7F)
            if x & 0x80 == 0 { parts.append(v); v = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    var string: String {
        if tag == 0x1E { // BMPString
            let u = stride(from: content.startIndex, to: content.endIndex - 1, by: 2).map { UInt16(content[$0]) << 8 | UInt16(content[$0 + 1]) }
            return String(decoding: u, as: UTF16.self)
        }
        return String(decoding: content, as: UTF8.self)
    }

    /// A BIT STRING's bytes, past the unused-bits octet.
    var bits: ArraySlice<UInt8> { content.isEmpty ? content : content.dropFirst() }

    /// UTCTime / GeneralizedTime → ms since epoch.
    var timeMs: Double? {
        var s = string
        guard s.hasSuffix("Z") else { return nil }
        s.removeLast()
        if tag == 0x17 {
            guard let yy = Int(s.prefix(2)) else { return nil }
            s = (yy < 50 ? "20" : "19") + s
        }
        if s.count == 12 { s += "00" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(s.prefix(14))).map { $0.timeIntervalSince1970 * 1000 }
    }
}

/// One certificate's fields, as crypto.X509Certificate exposed them.
struct NTX509 {
    var der: [UInt8]
    var tbs: [UInt8]
    var serialNumber: String
    var issuer: String
    var subject: String
    var issuerDER: [UInt8]
    var subjectDER: [UInt8]
    var validFrom: Double
    var validTo: Double
    var subjectAltName: String
    var ca: Bool
    var keyUsage: [String]          // Node's x509.keyUsage: extended key usage OIDs
    var publicKey: String           // "ec prime256v1", "rsa 2048", "ed25519"
    var spki: [UInt8]
    var keyBits: [UInt8]
    var sigAlg: String
    var signature: [UInt8]
    var fingerprint256: String

    static let names: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST", "2.5.4.10": "O", "2.5.4.11": "OU",
        "2.5.4.5": "serialNumber", "2.5.4.4": "SN", "2.5.4.42": "GN", "2.5.4.12": "title", "2.5.4.9": "street",
        "2.5.4.17": "postalCode", "2.5.4.46": "dnQualifier", "1.2.840.113549.1.9.1": "emailAddress",
        "0.9.2342.19200300.100.1.25": "DC", "0.9.2342.19200300.100.1.1": "UID",
    ]
    static let curves: [String: String] = [
        "1.2.840.10045.3.1.7": "prime256v1", "1.3.132.0.34": "secp384r1", "1.3.132.0.35": "secp521r1",
        "1.3.132.0.10": "secp256k1",
    ]

    static func name(_ e: NTDER) throws -> String {
        try e.children().flatMap { try $0.children() }.compactMap { atv -> String? in
            let p = try atv.children()
            guard p.count >= 2 else { return nil }
            return "\(names[p[0].oid] ?? p[0].oid)=\(p[1].string)"
        }.joined(separator: "\n")
    }

    init(der: [UInt8]) throws {
        let bad = AppError("The certificate is not valid DER.")
        self.der = der
        let (cert, _) = try NTDER.parse(der[...])
        let top = try cert.children()
        guard top.count >= 3 else { throw bad }
        tbs = Array(top[0].whole)
        sigAlg = (try top[1].children().first?.oid) ?? ""
        signature = Array(top[2].bits)
        var f = try top[0].children()
        if f.first?.tag == 0xA0 { f.removeFirst() }
        guard f.count >= 6 else { throw bad }
        var serial = Array(f[0].content)
        while serial.count > 1 && serial.first == 0 { serial.removeFirst() }
        serialNumber = serial.map { String(format: "%02X", $0) }.joined()
        issuerDER = Array(f[2].whole); issuer = try NTX509.name(f[2])
        let validity = try f[3].children()
        guard validity.count == 2, let a = validity[0].timeMs, let b = validity[1].timeMs else { throw bad }
        validFrom = a; validTo = b
        subjectDER = Array(f[4].whole); subject = try NTX509.name(f[4])
        spki = Array(f[5].whole)
        let sp = try f[5].children()
        let alg = try sp.first?.children() ?? []
        keyBits = sp.count > 1 ? Array(sp[1].bits) : []
        switch alg.first?.oid ?? "" {
        case "1.2.840.10045.2.1":
            publicKey = "ec" + (alg.count > 1 && alg[1].tag == 0x06 ? " " + (NTX509.curves[alg[1].oid] ?? alg[1].oid) : "")
        case "1.2.840.113549.1.1.1", "1.2.840.113549.1.1.10":
            let rsa = (try? NTDER.parse(keyBits[...]).0.children()) ?? []
            var n = Array(rsa.first?.content ?? [])
            while n.first == 0 { n.removeFirst() }
            let bits = n.isEmpty ? 0 : n.count * 8 - n[0].leadingZeroBitCount
            publicKey = (alg.first?.oid == "1.2.840.113549.1.1.1" ? "rsa" : "rsa-pss") + " \(bits)"
        case "1.3.101.112": publicKey = "ed25519"
        case "1.3.101.113": publicKey = "ed448"
        case let o: publicKey = o
        }
        var sans: [String] = [], isCA = false, eku: [String] = []
        if let ext = f.first(where: { $0.tag == 0xA3 }), let seq = try ext.children().first {
            for e in try seq.children() {
                let p = try e.children()
                guard let id = p.first?.oid, let value = p.last, value.tag == 0x04 else { continue }
                let (inner, _) = try NTDER.parse(value.content)
                switch id {
                case "2.5.29.17": sans = try inner.children().compactMap(NTX509.generalName)
                case "2.5.29.19": isCA = (try inner.children().first { $0.tag == 0x01 })?.content.first.map { $0 != 0 } ?? false
                case "2.5.29.37": eku = try inner.children().map(\.oid)
                default: break
                }
            }
        }
        subjectAltName = sans.joined(separator: ", ")
        ca = isCA
        keyUsage = eku
        fingerprint256 = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func generalName(_ g: NTDER) -> String? {
        switch g.tag & 0x1F {
        case 1: return "email:" + g.string
        case 2: return "DNS:" + g.string
        case 6: return "URI:" + g.string
        case 7:
            let b = Array(g.content)
            if b.count == 4 { return "IP Address:" + NTAddr.v4String(b) }
            if b.count == 16 { return "IP Address:" + NTAddr.v6String(b) }
            return nil
        default: return nil
        }
    }

    var pem: String {
        let b64 = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----"
    }

    /// checkIssued(next) && verify(next.publicKey): the names chain and the
    /// signature checks out against the next certificate's key.
    func signed(by next: NTX509) -> Bool {
        guard issuerDER == next.subjectDER else { return false }
        if sigAlg == "1.3.101.112" {
            guard let k = try? Curve25519.Signing.PublicKey(rawRepresentation: next.keyBits) else { return false }
            return k.isValidSignature(signature, for: tbs)
        }
        let algs: [String: SecKeyAlgorithm] = [
            "1.2.840.113549.1.1.5": .rsaSignatureMessagePKCS1v15SHA1,
            "1.2.840.113549.1.1.11": .rsaSignatureMessagePKCS1v15SHA256,
            "1.2.840.113549.1.1.12": .rsaSignatureMessagePKCS1v15SHA384,
            "1.2.840.113549.1.1.13": .rsaSignatureMessagePKCS1v15SHA512,
            "1.2.840.10045.4.1": .ecdsaSignatureMessageX962SHA1,
            "1.2.840.10045.4.3.2": .ecdsaSignatureMessageX962SHA256,
            "1.2.840.10045.4.3.3": .ecdsaSignatureMessageX962SHA384,
            "1.2.840.10045.4.3.4": .ecdsaSignatureMessageX962SHA512,
        ]
        guard let alg = algs[sigAlg],
              let c = SecCertificateCreateWithData(nil, Data(next.der) as CFData),
              let key = SecCertificateCopyKey(c) else { return false }
        return SecKeyVerifySignature(key, alg, Data(tbs) as CFData, Data(signature) as CFData, nil)
    }
}
