import Foundation

// decoders.js — the subnet calculator and the URL helper. Addresses are kept
// as big-endian byte arrays (4 or 16) in place of the original's BigInt.

struct CIDRResult: Equatable {
    struct Check: Equatable { var address: String; var inside: Bool }
    var family: Int
    var input: String
    var cidr: String
    var prefix: Int
    var network: String
    var hostBitsSet: Bool
    var first: String
    var last: String
    var total: String
    var usable: String
    var netmask: String?
    var wildcard: String?
    var broadcast: String?
    var kind: String?
    var lastAddress: String?
    var check: Check?
}

enum NTAddr {
    static func isV4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return false }
        return p.allSatisfy { o in
            !o.isEmpty && o.count <= 3 && o.allSatisfy(\.isASCIIDigit) && (Int(o) ?? 256) <= 255
                && !(o.count > 1 && o.first == "0")
        }
    }

    static func isV6(_ s: String) -> Bool {
        var a = in6_addr()
        return !s.isEmpty && !s.contains("%") && inet_pton(AF_INET6, s, &a) == 1
    }

    static func v4Bytes(_ s: String) -> [UInt8] { s.split(separator: ".").map { UInt8($0) ?? 0 } }

    static func v6Bytes(_ s: String) -> [UInt8] {
        var a = in6_addr()
        guard inet_pton(AF_INET6, s, &a) == 1 else { return Array(repeating: 0, count: 16) }
        return withUnsafeBytes(of: &a) { Array($0) }
    }

    static func v4String(_ b: [UInt8]) -> String { b.map { String($0) }.joined(separator: ".") }

    /// RFC 5952: lower-case hex, the longest run of two or more zero groups
    /// becomes `::`. Embedded dotted quads are not used (`::ffff:a00:1`).
    static func v6String(_ b: [UInt8]) -> String {
        let groups = (0..<8).map { String(Int(b[$0 * 2]) << 8 | Int(b[$0 * 2 + 1]), radix: 16) }
        var bestAt = -1, bestLen = 1, i = 0
        while i < 8 {
            if groups[i] != "0" { i += 1; continue }
            var j = i
            while j < 8 && groups[j] == "0" { j += 1 }
            if j - i > bestLen { bestAt = i; bestLen = j - i }
            i = j
        }
        if bestAt < 0 { return groups.joined(separator: ":") }
        return groups[0..<bestAt].joined(separator: ":") + "::" + groups[(bestAt + bestLen)...].joined(separator: ":")
    }

    static func parse(_ s: String) -> (family: Int, bits: Int, b: [UInt8])? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if isV4(v) { return (4, 32, v4Bytes(v)) }
        if isV6(v) { return (6, 128, v6Bytes(v)) }
        return nil
    }

    static func format(_ family: Int, _ b: [UInt8]) -> String { family == 4 ? v4String(b) : v6String(b) }

    /// A mask of `prefix` leading ones over `bytes` bytes.
    static func mask(_ prefix: Int, _ bytes: Int) -> [UInt8] {
        (0..<bytes).map { i in
            let ones = min(max(prefix - i * 8, 0), 8)
            return ones == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - ones))
        }
    }

    static func and(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { zip(a, b).map { $0 & $1 } }
    static func or(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { zip(a, b).map { $0 | $1 } }
    static func not(_ a: [UInt8]) -> [UInt8] { a.map { ~$0 } }

    /// a ± 1 with carry.
    static func add(_ a: [UInt8], _ d: Int) -> [UInt8] {
        var out = a, i = a.count - 1, carry = d
        while i >= 0 && carry != 0 {
            let v = Int(out[i]) + carry
            out[i] = UInt8(truncatingIfNeeded: v)
            carry = v < 0 ? -1 : v > 255 ? 1 : 0
            i -= 1
        }
        return out
    }

    /// 2^n − sub as a decimal string (n up to 128).
    static func pow2(_ n: Int, minus sub: Int = 0) -> String {
        var digits: [Int] = [1]   // little-endian decimal
        for _ in 0..<n {
            var carry = 0
            for i in digits.indices { let v = digits[i] * 2 + carry; digits[i] = v % 10; carry = v / 10 }
            if carry > 0 { digits.append(carry) }
        }
        var borrow = sub, i = 0
        while borrow > 0 && i < digits.count {
            var v = digits[i] - borrow % 10
            borrow /= 10
            if v < 0 { v += 10; borrow += 1 }
            digits[i] = v; i += 1
        }
        while digits.count > 1 && digits.last == 0 { digits.removeLast() }
        return digits.reversed().map(String.init).joined()
    }

    /// A prefix length from a dotted netmask, or nil if the mask has holes.
    static func maskToPrefix(_ mask: String) -> Int? {
        guard isV4(mask) else { return nil }
        let b = v4Bytes(mask)
        var len = 0
        while len < 32 && (b[len / 8] >> (7 - UInt8(len % 8))) & 1 == 1 { len += 1 }
        return NTAddr.mask(len, 4) == b ? len : nil
    }
}

enum NTDecode {
    static func cidr(_ input: String, check: String? = nil) throws -> CIDRResult {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: " \t\n\r,")).filter { !$0.isEmpty }
        guard let p0 = parts.first else { throw AppError("Give a subnet, such as 10.0.0.0/16.") }
        let split = p0.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let addr = split[0]
        var len: String? = split.count > 1 ? split[1] : nil
        var rest = Array(parts.dropFirst())
        if len == nil, let r0 = rest.first, let m = NTAddr.maskToPrefix(r0), NTAddr.isV4(addr) {
            len = String(m)
            rest.removeFirst()
        }
        guard let a = NTAddr.parse(addr) else { throw AppError("\"\(addr)\" is not an IPv4 or IPv6 address.") }
        let prefix: Int
        if let l = len {
            guard let d = ntNumber(l), d == d.rounded(), d >= 0, d <= Double(a.bits) else {
                throw AppError("The prefix must be 0–\(a.bits) for IPv\(a.family).")
            }
            prefix = Int(d)
        } else { prefix = a.bits }
        let bytes = a.bits / 8
        let netMask = NTAddr.mask(prefix, bytes)
        let hostMask = NTAddr.not(netMask)
        let network = NTAddr.and(a.b, netMask)
        let last = NTAddr.or(network, hostMask)
        var first = network, lastUsable = last
        var usable = NTAddr.pow2(a.bits - prefix)
        // IPv4 keeps its network and broadcast out of the usable range, except
        // for the point-to-point /31 and the single-host /32 (RFC 3021).
        if a.family == 4 && prefix <= 30 {
            first = NTAddr.add(network, 1); lastUsable = NTAddr.add(last, -1)
            usable = NTAddr.pow2(a.bits - prefix, minus: 2)
        }
        var out = CIDRResult(
            family: a.family, input: p0, cidr: "\(NTAddr.format(a.family, network))/\(prefix)", prefix: prefix,
            network: NTAddr.format(a.family, network), hostBitsSet: a.b != network,
            first: NTAddr.format(a.family, first), last: NTAddr.format(a.family, lastUsable),
            total: NTAddr.pow2(a.bits - prefix), usable: usable)
        if a.family == 4 {
            out.netmask = NTAddr.v4String(netMask)
            out.wildcard = NTAddr.v4String(hostMask)
            out.broadcast = prefix <= 30 ? NTAddr.v4String(last) : nil
            out.kind = v4Kind(network, prefix)
        } else {
            out.lastAddress = NTAddr.v6String(last)
        }
        if let probe = (check?.isEmpty == false ? check : nil) ?? rest.first {
            guard let p = NTAddr.parse(probe) else { throw AppError("\"\(probe)\" is not an address to check.") }
            out.check = .init(address: probe,
                              inside: p.family == a.family && NTAddr.and(p.b, netMask) == network)
        }
        return out
    }

    static func v4Kind(_ n: [UInt8], _ prefix: Int) -> String {
        func inside(_ base: String, _ len: Int) -> Bool {
            prefix >= len && NTAddr.and(n, NTAddr.mask(len, 4)) == NTAddr.and(NTAddr.v4Bytes(base), NTAddr.mask(len, 4))
        }
        if inside("10.0.0.0", 8) || inside("172.16.0.0", 12) || inside("192.168.0.0", 16) { return "private (RFC 1918)" }
        if inside("100.64.0.0", 10) { return "carrier-grade NAT (RFC 6598)" }
        if inside("127.0.0.0", 8) { return "loopback" }
        if inside("169.254.0.0", 16) { return "link-local" }
        if inside("224.0.0.0", 4) { return "multicast" }
        return prefix >= 8 ? "public" : ""
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
