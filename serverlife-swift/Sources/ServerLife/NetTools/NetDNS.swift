import Foundation
import dnssd

// nettools.js lookup(): every record type, TTLs for A/AAAA, and — new in
// 0.2x — a chosen nameserver instead of this machine's own ("is this
// propagation, or is my resolver just stale?"). The system resolver is
// dnssd; a chosen server is asked directly over UDP (TCP when truncated),
// as Node's dns.Resolver did.

extension NetLocal {
    static let dnsTypes: [(String, UInt16)] = [
        ("A", 1), ("AAAA", 28), ("CNAME", 5), ("MX", 15), ("TXT", 16), ("NS", 2), ("SRV", 33),
        ("CAA", 257), ("SOA", 6), ("NAPTR", 35),
    ]

    /// `nslookup -type=X [host] [server]` — spelled identically everywhere,
    /// one line per type, the same ones `lookup` asks about, rather than
    /// `dig … ANY`, which plenty of resolvers now silently refuse. The server,
    /// when one was given, keeps the copy-and-paste honest.
    static func dnsCommand(_ host: String, _ server: String?) -> String {
        dnsTypes.map { "nslookup -type=\($0.0) \(host)\(server.map { " " + $0 } ?? "")" }.joined(separator: "\n")
    }

    static func lookup(host: String, server: String? = nil) async throws -> DNSResult {
        let h = try NetCheck.checkHost(NetCheck.splitHostPort(host).host)
        let custom = (server?.ntTrimmed.isEmpty == false) ? try NetCheck.checkHost(NetCheck.splitHostPort(server!).host) : nil
        let ipv = NetCheck.ipVersion(h)
        let ask: @Sendable (String, UInt16) async -> [(Data, UInt32)] = { name, type in
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: custom.map { DNSWire.query($0, name, type: type) }
                                ?? DNSQuery.runSyncTTL(name, type: type, timeout: 5))
                }
            }
        }
        let found: [(Int, String, [JSON], UInt32?)] = await withTaskGroup(of: (Int, String, [JSON], UInt32?).self) { g in
            for (i, (name, type)) in dnsTypes.enumerated() {
                g.addTask {
                    // NODATA, NXDOMAIN and SERVFAIL are all just "nothing of this type" here.
                    let rd = await ask(h, type)
                    let values = rd.compactMap { DNSQuery.decode($0.0, type: type) }
                    // TTL is shown for the two types people ask about it the most.
                    let ttl = (type == 1 || type == 28) && !values.isEmpty ? rd.map(\.1).min() : nil
                    return (i, name, values, ttl)
                }
            }
            var out: [(Int, String, [JSON], UInt32?)] = []
            for await r in g where !r.2.isEmpty { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }
        var reverse: [String]? = nil
        if ipv != 0 {
            let names = await ask(DNSQuery.reverseName(h), 12).compactMap { DNSQuery.decode($0.0, type: 12)?.string }
            reverse = names.isEmpty ? nil : names
        }
        var ttls: [String: Int] = [:]
        for f in found { if let t = f.3 { ttls[f.1] = Int(t) } }
        return DNSResult(host: h, records: found.map { (type: $0.1, values: $0.2) }, reverse: reverse,
                         servers: custom.map { [$0] } ?? resolvers(), ttls: ttls,
                         usingCustomServer: custom != nil, command: dnsCommand(h, custom))
    }
}

extension DNSQuery {
    /// CAA, SOA and NAPTR, shaped as Node's resolver returned them.
    static func decodeMore(_ b: [UInt8], type: UInt16) -> JSON? {
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
        func u32(_ i: Int) -> Double { i + 3 < b.count ? Double(b[i..<i + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) : 0 }
        switch type {
        case 257:
            guard b.count >= 2 else { return nil }
            let tl = Int(b[1])
            guard 2 + tl <= b.count else { return nil }
            let tag = String(decoding: b[2..<2 + tl], as: UTF8.self)
            return ["critical": .number(Double(b[0])), tag: .string(String(decoding: b[(2 + tl)...], as: UTF8.self))]
        case 6:
            guard let ns = name(b, 0) else { return nil }
            let i1 = nameEnd(b, 0)
            guard let hm = name(b, i1) else { return nil }
            let i = nameEnd(b, i1)
            return ["nsname": .string(ns), "hostmaster": .string(hm), "serial": .number(u32(i)),
                    "refresh": .number(u32(i + 4)), "retry": .number(u32(i + 8)), "expire": .number(u32(i + 12)),
                    "minttl": .number(u32(i + 16))]
        case 35:
            var i = 4
            var strs: [String] = []
            for _ in 0..<3 {
                guard i < b.count else { return nil }
                let n = Int(b[i]); i += 1
                guard i + n <= b.count else { return nil }
                strs.append(String(decoding: b[i..<i + n], as: UTF8.self)); i += n
            }
            return ["flags": .string(strs[0]), "service": .string(strs[1]), "regexp": .string(strs[2]),
                    "replacement": .string(name(b, i) ?? ""), "order": .number(Double(u16(0))),
                    "preference": .number(Double(u16(2)))]
        default: return nil
        }
    }

    static func nameEnd(_ b: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < b.count, b[i] != 0 { i += Int(b[i]) + 1 }
        return i + 1
    }
}

/// A DNS query sent straight to one nameserver.
enum DNSWire {
    static func query(_ server: String, _ name: String, type: UInt16, timeout: TimeInterval = 5) -> [(Data, UInt32)] {
        let id = UInt16.random(in: 0...UInt16.max)
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { let u = Array(label.utf8.prefix(63)); q.append(UInt8(u.count)); q += u }
        q += [0, UInt8(type >> 8), UInt8(type & 255), 0, 1]
        guard let reply = exchange(server, q, tcp: false, timeout: timeout) else { return [] }
        if reply.count > 2, reply[2] & 0x02 != 0, let full = exchange(server, q, tcp: true, timeout: timeout) {
            return answers(full, id: id, type: type)
        }
        return answers(reply, id: id, type: type)
    }

    private static func exchange(_ server: String, _ q: [UInt8], tcp: Bool, timeout: TimeInterval) -> [UInt8]? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: tcp ? SOCK_STREAM : SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server, "53", &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { return nil }
        let msg = tcp ? [UInt8(q.count >> 8), UInt8(q.count & 255)] + q : q
        guard send(fd, msg, msg.count, 0) == msg.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 65537)
        if !tcp {
            let n = recv(fd, &buf, buf.count, 0)
            return n > 0 ? Array(buf[0..<n]) : nil
        }
        var got: [UInt8] = []
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            got += buf[0..<n]
            if got.count >= 2, got.count >= (Int(got[0]) << 8 | Int(got[1])) + 2 { break }
        }
        return got.count > 2 ? Array(got[2...]) : nil
    }

    /// The answers of the asked-for type, with names in their rdata expanded
    /// so DNSQuery.decode reads them as it reads dnssd's.
    static func answers(_ m: [UInt8], id: UInt16, type: UInt16) -> [(Data, UInt32)] {
        guard m.count >= 12, Int(m[0]) << 8 | Int(m[1]) == Int(id), m[3] & 0x0F == 0 else { return [] }
        func u16(_ i: Int) -> Int { i + 1 < m.count ? Int(m[i]) << 8 | Int(m[i + 1]) : 0 }
        let qd = u16(4), an = u16(6)
        var i = 12
        for _ in 0..<qd { i = skipName(m, i) + 4 }
        var out: [(Data, UInt32)] = []
        for _ in 0..<an {
            i = skipName(m, i)
            guard i + 10 <= m.count else { break }
            let t = UInt16(u16(i)), ttl = UInt32(u16(i + 4)) << 16 | UInt32(u16(i + 6)), len = u16(i + 8)
            let start = i + 10
            i = start + len
            guard i <= m.count, t == type else { continue }
            out.append((Data(expand(m, start, len, type: t)), ttl))
        }
        return out
    }

    static func skipName(_ m: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < m.count {
            let l = Int(m[i])
            if l == 0 { return i + 1 }
            if l & 0xC0 == 0xC0 { return i + 2 }
            i += l + 1
        }
        return i
    }

    /// A possibly compressed name at `start`, written out uncompressed.
    static func readName(_ m: [UInt8], _ start: Int) -> [UInt8] {
        var out: [UInt8] = [], i = start, hops = 0
        while i < m.count, hops < 64 {
            let l = Int(m[i])
            if l == 0 { break }
            if l & 0xC0 == 0xC0 { guard i + 1 < m.count else { break }; i = (l & 0x3F) << 8 | Int(m[i + 1]); hops += 1; continue }
            guard i + 1 + l <= m.count else { break }
            out += m[i...(i + l)]; i += l + 1
        }
        return out + [0]
    }

    static func expand(_ m: [UInt8], _ s: Int, _ len: Int, type: UInt16) -> [UInt8] {
        let raw = Array(m[s..<s + len])
        switch type {
        case 5, 2, 12: return readName(m, s)
        case 15: return Array(raw.prefix(2)) + readName(m, s + 2)
        case 33: return Array(raw.prefix(6)) + readName(m, s + 6)
        case 6:
            let a = readName(m, s), j = skipName(m, s)
            let b = readName(m, j), k = skipName(m, j)
            return a + b + Array(m[k..<min(k + 20, s + len)])
        case 35:
            var j = s + 4
            for _ in 0..<3 where j < s + len { j += Int(m[j]) + 1 }
            return Array(m[s..<min(j, s + len)]) + readName(m, j)
        default: return raw
        }
    }
}
