import Foundation
import dnssd

// The checks run from this machine (src/main/nettools.js). Everything runs
// against a single named host; external commands get an argument array —
// never a shell — and every target is validated first anyway.

/// Output a command printed, for ping, traceroute and whois — and the same
/// shape for their host-side versions (`missing`, `hint`, `tool`, `from`).
struct TextRun {
    var host = ""
    var ok = false
    var text = ""
    var timedOut = false
    var command = ""
    var missing: String?
    var hint: String?
    var tool: String?
    var from: String?

    var json: JSON {
        var o: [String: JSON] = ["host": .string(host), "ok": .bool(ok), "text": .string(text),
                                 "timedOut": .bool(timedOut), "command": .string(command)]
        if let missing { o["missing"] = .string(missing) }
        if let hint { o["hint"] = .string(hint) }
        if let tool { o["tool"] = .string(tool) }
        if let from { o["from"] = .string(from) }
        return .object(o)
    }
}

struct PortResult: Equatable {
    var port: Int
    var state: String
    var ms: Int
    var detail: String?
    // Host-side only.
    var open: Bool?
    var how: String?
    var banner: String?
    var error: String?

    var json: JSON {
        var o: [String: JSON] = ["port": .number(Double(port)), "state": .string(state), "ms": .number(Double(ms))]
        if let detail { o["detail"] = .string(detail) } else if how == nil { o["detail"] = .null }
        if how != nil || open != nil {
            o["open"] = JSON(open); o["how"] = JSON(how); o["banner"] = JSON(banner); o["error"] = JSON(error)
        }
        return .object(o)
    }
}

struct PortsResult {
    var host: String
    var results: [PortResult]
    /// Host-side: who asked, and how.
    var from: String?
    var how: String?
    /// The hand-run form, one `nc -zv` per port (local runs only).
    var command = ""

    var json: JSON {
        var o: [String: JSON] = ["host": .string(host), "results": .array(results.map(\.json))]
        if from == nil { o["command"] = .string(command) }
        if let from { o["from"] = .string(from) }
        if from != nil { o["how"] = JSON(how) }
        return .object(o)
    }
}

struct TelnetResult {
    var host: String
    var port: Int
    var address: String?
    var state: String
    var connectMs: Int?
    var listenedMs: Int
    var text: String
    var telnet: Bool
    var closedByPeer: Bool
    var guess: String?
    var command: String
    var error: String?

    var json: JSON {
        ["host": .string(host), "port": .number(Double(port)), "address": JSON(address), "state": .string(state),
         "connectMs": JSON(connectMs), "listenedMs": .number(Double(listenedMs)), "text": .string(text),
         "telnet": .bool(telnet), "closedByPeer": .bool(closedByPeer), "guess": JSON(guess),
         "command": .string(command), "commandNote": .null, "error": JSON(error)]
    }
}

struct DNSResult {
    var host: String
    /// Type → records, in DNS_TYPES order. A record is a string, an object
    /// (MX, SRV) or an array of strings (TXT), as Node's resolver returned them.
    var records: [(type: String, values: [JSON])]
    var reverse: [String]?
    var servers: [String]
    /// Lowest TTL per type, for A and AAAA only.
    var ttls: [String: Int] = [:]
    var usingCustomServer = false
    var command = ""

    var json: JSON {
        ["host": .string(host),
         "records": .object(Dictionary(records.map { ($0.type, JSON.array($0.values)) }, uniquingKeysWith: { a, _ in a })),
         "ttls": .object(ttls.mapValues { .number(Double($0)) }),
         "reverse": reverse.map { JSON($0) } ?? .null, "servers": JSON(servers),
         "usingCustomServer": .bool(usingCustomServer), "command": .string(command)]
    }

    static func format(_ v: JSON) -> String {
        switch v {
        case .string(let s): return s
        case .array(let a): return a.map { $0.stringish ?? "" }.joined()
        case .object(let o):
            let order = ["exchange", "priority", "name", "port", "weight", "critical", "issue", "issuewild", "iodef",
                         "nsname", "hostmaster", "serial", "refresh", "retry", "expire", "minttl",
                         "flags", "service", "regexp", "replacement", "order", "preference"]
            return o.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
                .map { "\($0)=\(o[$0]!.stringish ?? "")" }.joined(separator: " ")
        default: return v.stringish ?? ""
        }
    }
}

/// One certificate of the chain a server presented.
struct TLSChainCert {
    var subject: [(String, String)]
    var issuer: [(String, String)]
    var validFrom: String?
    var validTo: String?
    var fingerprint256: String?
    var serialNumber: String?

    var json: JSON {
        ["subject": TLSResult.dnJSON(subject), "issuer": TLSResult.dnJSON(issuer), "validFrom": JSON(validFrom),
         "validTo": JSON(validTo), "fingerprint256": JSON(fingerprint256), "serialNumber": JSON(serialNumber)]
    }
}

struct TLSResult {
    var ok: Bool
    var host: String
    var port: Int
    var error: String?
    var authorized = false
    var authorizationError: String?
    var proto: String?
    var cipherName: String?
    var cipherVersion: String?
    var alpn: String?
    /// Distinguished-name parts in certificate order (CN, O, …).
    var subject: [(String, String)] = []
    var issuer: [(String, String)] = []
    var validFrom: String?
    var validTo: String?
    var daysLeft: Int?
    var san: String?
    var fingerprint256: String?
    var serialNumber: String?
    /// Every certificate presented, leaf first — intermediates then root.
    var chain: [TLSChainCert] = []
    /// Whether the last one in the chain is self-signed (subject == issuer):
    /// a guess at "did it send the whole chain".
    var chainComplete: Bool? {
        guard let last = chain.last else { return nil }
        return last.subject.map { "\($0.0)=\($0.1)" } == last.issuer.map { "\($0.0)=\($0.1)" }
    }
    /// The hand-run form (`openssl s_client …`); `commandNote` is a platform
    /// caveat, never set on macOS.
    var command = ""
    var commandNote: String?

    static func dnJSON(_ p: [(String, String)]) -> JSON {
        p.isEmpty ? .null : .object(Dictionary(p.map { ($0.0, JSON.string($0.1)) }, uniquingKeysWith: { a, _ in a }))
    }

    var json: JSON {
        let dn = TLSResult.dnJSON
        if !ok {
            return ["ok": false, "host": .string(host), "port": .number(Double(port)), "command": .string(command),
                    "commandNote": JSON(commandNote), "error": JSON(error)]
        }
        return ["ok": true, "host": .string(host), "port": .number(Double(port)), "command": .string(command),
                "commandNote": JSON(commandNote), "authorized": .bool(authorized),
                "authorizationError": JSON(authorizationError), "protocol": JSON(proto),
                "cipher": cipherName.map { ["name": .string($0), "version": JSON(cipherVersion)] } ?? .null,
                "alpn": JSON(alpn), "subject": dn(subject), "issuer": dn(issuer), "validFrom": JSON(validFrom),
                "validTo": JSON(validTo), "daysLeft": JSON(daysLeft), "san": JSON(san),
                "fingerprint256": JSON(fingerprint256), "serialNumber": JSON(serialNumber),
                "chain": .array(chain.map(\.json)), "chainComplete": JSON(chainComplete)]
    }

    static func dn(_ parts: [(String, String)]) -> String? {
        if parts.isEmpty { return nil }
        if let cn = parts.first(where: { $0.0 == "CN" })?.1 { return cn }
        return parts.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }
}

struct HTTPHop {
    var url: String
    var status: Int
    var statusMessage: String
    var headers: [(String, String)]
    var ms: Int
    var bytes: Int
    var preview: String

    var json: JSON {
        ["url": .string(url), "status": .number(Double(status)), "statusMessage": .string(statusMessage),
         "headers": .object(Dictionary(headers.map { ($0.0, JSON.string($0.1)) }, uniquingKeysWith: { a, _ in a })),
         "ms": .number(Double(ms)), "bytes": .number(Double(bytes)), "preview": .string(preview)]
    }
}

struct HTTPResult {
    var chain: [HTTPHop]
    var command = ""
    var final: HTTPHop? { chain.last }
    var redirects: Int { max(0, chain.count - 1) }
    var json: JSON {
        ["chain": .array(chain.map(\.json)), "final": final?.json ?? .null, "redirects": .number(Double(redirects)), "command": .string(command)]
    }
}

struct LocalInfo {
    struct Address { var name, family, address, mac: String; var cidr: String? }
    var hostname: String
    var platform: String
    var addresses: [Address]
    var dnsServers: [String]

    var json: JSON {
        ["hostname": .string(hostname), "platform": .string(platform),
         "addresses": .array(addresses.map { ["name": .string($0.name), "family": .string($0.family),
                                              "address": .string($0.address), "mac": .string($0.mac), "cidr": JSON($0.cidr)] }),
         "dnsServers": JSON(dnsServers)]
    }
}

enum NetLocal {
    /// Run a command; the text is stdout then stderr, because a non-zero
    /// exit still carries the useful part (ping prints its summary before
    /// failing), so the text matters more than the status.
    static func run(_ cmd: String, _ args: [String], timeout: TimeInterval) async -> (ok: Bool, text: String, timedOut: Bool, missing: Bool) {
        // 4 MB, as the original's execFile maxBuffer.
        let r = await NetProc.run(cmd, args, timeout: timeout, maxBuffer: 4 * 1024 * 1024)
        let text = (r.out + r.err).ntTrimmed
        return (r.ok, text, r.timedOut, r.spawnError != nil)
    }

    // MARK: ICMP and path

    /// Which binary and args ping this host with, optionally forced onto
    /// one IP family. Shared between the real run and the preview/copy, so
    /// the two cannot drift apart. macOS's `ping` has no `-6` of its own —
    /// `ping6` is the IPv6-only sibling it ships instead.
    static func pingSpec(_ host: String, _ count: String?, _ ipVersion: String?) -> (cmd: String, args: [String]) {
        let n = Int(ntClamp(count, 5, 1, 20))
        if ipVersion == "6" { return ("ping6", ["-c", String(n), host]) }
        return ("ping", ["-c", String(n), "-W", "2000", host])
    }

    /// The ping invocation for a host, with no I/O.
    static func pingCommand(_ host: String, _ count: String?, _ ipVersion: String?) -> String {
        let s = pingSpec(host, count, ipVersion)
        return ([s.cmd] + s.args).joined(separator: " ")
    }

    static func ping(host: String, count: String?, ipVersion: String? = nil) async throws -> TextRun {
        // The target field takes "host:port"; ICMP has no ports, so drop it.
        let h = try NetCheck.checkHost(NetCheck.splitHostPort(host).host)
        let n = Int(ntClamp(count, 5, 1, 20))
        let s = pingSpec(h, count, ipVersion)
        let r = await run(s.cmd, s.args, timeout: TimeInterval((n + 5) * 2))
        return TextRun(host: h, ok: r.ok, text: r.text, timedOut: r.timedOut, command: pingCommand(h, count, ipVersion))
    }

    /// Same idea as pingSpec(), for traceroute's own IPv6-only sibling.
    static func tracerouteSpec(_ host: String, _ maxHops: String?, _ ipVersion: String?) -> (cmd: String, args: [String]) {
        let hops = String(Int(ntClamp(maxHops, 20, 1, 40)))
        if ipVersion == "6" { return ("traceroute6", ["-m", hops, "-w", "2", host]) }
        return ("traceroute", ["-m", hops, "-w", "2"] + (ipVersion == "4" ? ["-4"] : []) + [host])
    }

    static func tracerouteCommand(_ host: String, _ maxHops: String?, _ ipVersion: String?) -> String {
        let s = tracerouteSpec(host, maxHops, ipVersion)
        return ([s.cmd] + s.args).joined(separator: " ")
    }

    static func traceroute(host: String, maxHops: String? = nil, ipVersion: String? = nil) async throws -> TextRun {
        let h = try NetCheck.checkHost(NetCheck.splitHostPort(host).host)
        let hops = Int(ntClamp(maxHops, 20, 1, 40))
        let s = tracerouteSpec(h, maxHops, ipVersion)
        let command = tracerouteCommand(h, maxHops, ipVersion)
        let r = await run(s.cmd, s.args, timeout: TimeInterval(hops * 4))
        if r.text.isEmpty && !r.ok {
            return TextRun(host: h, ok: false, text: "\(s.cmd) is not installed or not on PATH.", command: command)
        }
        return TextRun(host: h, ok: r.ok, text: r.text, timedOut: r.timedOut, command: command)
    }

    static func whoisCommand(_ host: String) -> String { "whois \(host)" }

    static func whois(host: String) async throws -> TextRun {
        let h = try NetCheck.checkHost(NetCheck.splitHostPort(host).host)
        let r = await run("whois", [h], timeout: 25)
        if r.text.isEmpty { return TextRun(host: h, ok: false, text: "whois is not installed or returned nothing.", command: whoisCommand(h)) }
        return TextRun(host: h, ok: r.ok, text: r.text, timedOut: r.timedOut, command: whoisCommand(h))
    }

    // MARK: DNS

    /// The resolvers in use (`dns.getServers()`): what /etc/resolv.conf names.
    static func resolvers() -> [String] {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "nameserver" else { return nil }
            return String(parts[1])
        }
    }

    // MARK: TCP reachability

    /// `-z` (connect and immediately close) is what makes this a check rather
    /// than a conversation; dropping it is `telnetCommand`'s job.
    static func portCommand(_ host: String, _ port: Int, _ ipVersion: String?) -> String {
        let flag = ipVersion == "6" ? "-6 " : ipVersion == "4" ? "-4 " : ""
        return "nc -zv \(flag)\(host) \(port)"
    }

    /// The hand-run form of the telnet probe: stay connected and show what
    /// the far end says. `nc` without `-z` does that.
    static func telnetCommand(_ host: String, _ port: Int) -> String { "nc -v \(host) \(port)" }

    static func portCheck(host: String, ports: String?, timeout: String? = nil, ipVersion: String? = nil) async throws -> PortsResult {
        let parsed = NetCheck.splitHostPort(host)
        let h = try NetCheck.checkHost(parsed.host)
        // A target written as "host:port" has already named the port to check.
        let list = (ports?.isEmpty == false) ? try NetCheck.parsePorts(ports) : (parsed.port.map { [$0] } ?? NetCheck.defaultPorts)
        if list.contains(where: { $0 < 1 || $0 > 65535 }) { throw AppError("Ports run from 1 to 65535.") }
        let t = Int(ntClamp(timeout, 3000, 500, 10000))
        var results = await withTaskGroup(of: PortResult.self) { g in
            let family = ipVersion == "6" ? 6 : ipVersion == "4" ? 4 : 0
            for p in list { g.addTask { await NetSocket.probe(h, p, timeoutMs: t, family: family) } }
            var out: [PortResult] = []
            for await r in g { out.append(r) }
            return out
        }
        results.sort { $0.port < $1.port }
        var out = PortsResult(host: h, results: results)
        out.command = list.map { portCommand(h, $0, ipVersion) }.joined(separator: "\n")
        return out
    }

    // MARK: Telnet

    /// `telnet host port`, minus the part where you have to type `^]` and
    /// `quit`: connects, answers the negotiation (a switch will not show its
    /// prompt until it has been answered), listens for a few seconds, and
    /// reports what was said. Nothing is ever *sent* beyond the negotiation.
    static func telnetProbe(host: String, port: String?, wait: String? = nil, timeout: String? = nil) async throws -> TelnetResult {
        let parsed = NetCheck.splitHostPort(host)
        let h = try NetCheck.checkHost(parsed.host)
        // An explicit port wins over one written into the target, because
        // the field beside it is the more recent thing the user touched.
        let pn = ntNumberOr(port, Double(parsed.port ?? 23))
        if pn != pn.rounded() || pn < 1 || pn > 65535 { throw AppError("Ports run from 1 to 65535.") }
        let p = Int(pn)
        let listen = Int(ntClamp(wait, 3000, 500, 10000))
        let connectWithin = Int(ntClamp(timeout, 5000, 500, 15000))
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: NetSocket.telnet(h, p, listenMs: listen, connectMs: connectWithin))
            }
        }
    }

    /// What a banner says, made fit to read: escape sequences out, line
    /// endings settled, and stray control characters removed.
    static func cleanBanner(_ s: String) -> String {
        var t = s
        func sub(_ p: String, _ w: String) {
            t = t.replacingOccurrences(of: p, with: w, options: .regularExpression)
        }
        sub("\u{1b}\\[[0-?]*[ -/]*[@-~]", "")
        sub("\u{1b}[\\]P^_][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)?", "")
        sub("\r\n?", "\n")
        sub("[\u{00}-\u{08}\u{0b}-\u{1f}\u{7f}]", "")
        sub("\n{3,}", "\n\n")
        // `.slice(0, 8192)` counts UTF-16 units.
        let trimmed = t.ntTrimmed
        let u = Array(trimmed.utf16)
        return u.count <= 8192 ? trimmed : String(decoding: u[0..<8192], as: UTF16.self)
    }

    /// A guess at what answered, from what it said first. Only the ones that
    /// announce themselves unmistakably.
    static func guessService(_ text: String, spokeTelnet: Bool) -> String? {
        func has(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> Bool {
            (try? NSRegularExpression(pattern: p, options: o))?.matches(text) ?? false
        }
        if has(#"^SSH-\d"#) { return "an SSH server" }
        if has(#"^220[ -].*(?:SMTP|ESMTP|mail)"#, [.anchorsMatchLines, .caseInsensitive]) { return "a mail server (SMTP)" }
        if has(#"^220[ -].*FTP"#, [.anchorsMatchLines, .caseInsensitive]) { return "an FTP server" }
        if has(#"^\+OK"#) { return "a POP3 server" }
        if has(#"^\* OK"#) { return "an IMAP server" }
        if has(#"^-ERR|^-NOAUTH|^\+PONG"#) { return "Redis, or something that talks like it" }
        if has(#"mysql_native_password|caching_sha2_password"#, []) { return "MySQL or MariaDB" }
        if has(#"^RFB \d{3}\.\d{3}"#) { return "a VNC server" }
        if spokeTelnet { return "a telnet server" }
        if has(#"(?:login|username|user name|password)\s*:\s*$"#, [.anchorsMatchLines, .caseInsensitive]) {
            return "something asking you to log in"
        }
        return nil
    }

    // MARK: This machine

    static func localInfo() -> LocalInfo {
        var addrs: [LocalInfo.Address] = []
        var macs: [String: String] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            // MACs first, from the link-layer entries.
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let ifa = cur.pointee
                if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) {
                    let name = String(cString: ifa.ifa_name)
                    sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                        let len = Int(dl.pointee.sdl_alen)
                        if len == 6 {
                            let base = UnsafeRawPointer(dl).advanced(by: 8 + Int(dl.pointee.sdl_nlen))
                            let bytes = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                            macs[name] = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                        }
                    }
                }
                p = ifa.ifa_next
            }
            p = first
            while let cur = p {
                let ifa = cur.pointee
                defer { p = ifa.ifa_next }
                guard let sa = ifa.ifa_addr else { continue }
                let fam = Int32(sa.pointee.sa_family)
                guard fam == AF_INET || fam == AF_INET6 else { continue }
                if (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) != 0 { continue }
                let name = String(cString: ifa.ifa_name)
                let addr = sockaddrString(sa).components(separatedBy: "%")[0]
                var prefix: Int? = nil
                if let nm = ifa.ifa_netmask { prefix = maskBits(nm, family: fam) }
                addrs.append(.init(name: name, family: fam == AF_INET ? "IPv4" : "IPv6", address: addr,
                                   mac: macs[name] ?? "00:00:00:00:00:00", cidr: prefix.map { "\(addr)/\($0)" }))
            }
            freeifaddrs(ifap)
        }
        var u = utsname()
        uname(&u)
        func field<T>(_ v: T) -> String {
            withUnsafeBytes(of: v) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        var hn = [CChar](repeating: 0, count: 256)
        gethostname(&hn, 255)
        return LocalInfo(hostname: String(cString: hn), platform: "\(field(u.sysname)) \(field(u.release))",
                         addresses: addrs, dnsServers: resolvers())
    }

    static func sockaddrString(_ sa: UnsafePointer<sockaddr>) -> String {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(sa.pointee.sa_family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        return String(cString: buf)
    }

    private static func maskBits(_ nm: UnsafePointer<sockaddr>, family: Int32) -> Int {
        if family == AF_INET {
            return nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr).nonzeroBitCount }
        }
        return nm.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
            withUnsafeBytes(of: p.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
        }
    }
}

// MARK: - dnssd

/// One DNS question through the system resolver (DNSServiceQueryRecord),
/// answered with the raw rdata of every record, or nothing.
enum DNSQuery {
    private final class Box {
        var records: [Data] = []
        var ttls: [UInt32] = []
        var done = false
    }

    static func run(_ name: String, type: UInt16, timeout: TimeInterval = 5) async -> [Data] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: runSync(name, type: type, timeout: timeout)) }
        }
    }

    static func runSync(_ name: String, type: UInt16, timeout: TimeInterval) -> [Data] {
        runSyncTTL(name, type: type, timeout: timeout).map(\.0)
    }

    /// Each record with its TTL, as the system resolver returned it.
    static func runSyncTTL(_ name: String, type: UInt16, timeout: TimeInterval) -> [(Data, UInt32)] {
        let box = Box()
        var ref: DNSServiceRef?
        let ctx = Unmanaged.passRetained(box)
        defer { ctx.release() }
        let cb: DNSServiceQueryRecordReply = { _, flags, _, err, _, _, _, rdlen, rdata, ttl, context in
            guard let context else { return }
            let b = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            if err == kDNSServiceErr_NoError, (flags & kDNSServiceFlagsAdd) != 0, let rdata {
                b.records.append(Data(bytes: rdata, count: Int(rdlen)))
                b.ttls.append(ttl)
            }
            if err != kDNSServiceErr_NoError || (flags & kDNSServiceFlagsMoreComing) == 0 { b.done = true }
        }
        let e = DNSServiceQueryRecord(&ref, DNSServiceFlags(kDNSServiceFlagsTimeout), 0, name, type,
                                      UInt16(kDNSServiceClass_IN), cb, ctx.toOpaque())
        guard e == kDNSServiceErr_NoError, let ref else { return [] }
        defer { DNSServiceRefDeallocate(ref) }
        let fd = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(timeout)
        while !box.done {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, Int32(left * 1000))
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            if DNSServiceProcessResult(ref) != kDNSServiceErr_NoError { break }
        }
        return Array(zip(box.records, box.ttls))
    }

    /// The PTR name for an address.
    static func reverseName(_ ip: String) -> String {
        var a4 = in_addr()
        if inet_pton(AF_INET, ip, &a4) == 1 {
            return ip.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa"
        }
        var a6 = in6_addr()
        _ = inet_pton(AF_INET6, ip, &a6)
        let bytes = withUnsafeBytes(of: a6) { Array($0) }
        let nibbles = bytes.flatMap { [String($0 >> 4, radix: 16), String($0 & 0xf, radix: 16)] }
        return nibbles.reversed().joined(separator: ".") + ".ip6.arpa"
    }

    /// A record as Node's resolver returned it.
    static func decode(_ d: Data, type: UInt16) -> JSON? {
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
        switch Int(type) {
        case kDNSServiceType_A:
            guard b.count == 4 else { return nil }
            return .string(b.map(String.init).joined(separator: "."))
        case kDNSServiceType_AAAA:
            guard b.count == 16 else { return nil }
            var a = in6_addr()
            withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: b) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
            return .string(String(cString: buf))
        case kDNSServiceType_CNAME, kDNSServiceType_NS, kDNSServiceType_PTR:
            return name(b, 0).map { .string($0) }
        case kDNSServiceType_MX:
            guard let n = name(b, 2) else { return nil }
            return ["exchange": .string(n), "priority": .number(Double(u16(0)))]
        case kDNSServiceType_SRV:
            guard let n = name(b, 6) else { return nil }
            return ["name": .string(n), "port": .number(Double(u16(4))), "priority": .number(Double(u16(0))),
                    "weight": .number(Double(u16(2)))]
        case kDNSServiceType_TXT:
            var parts: [JSON] = []
            var i = 0
            while i < b.count {
                let len = Int(b[i]); i += 1
                let end = min(b.count, i + len)
                parts.append(.string(String(decoding: b[i..<end], as: UTF8.self)))
                i = end
            }
            return .array(parts)
        default:
            return decodeMore(b, type: type)
        }
    }

    /// A wire-format name (uncompressed, as dnssd hands it over) without the
    /// trailing dot.
    static func name(_ b: [UInt8], _ start: Int) -> String? {
        var labels: [String] = []
        var i = start
        while i < b.count {
            let len = Int(b[i])
            if len == 0 { break }
            if len & 0xC0 != 0 { return nil }
            i += 1
            guard i + len <= b.count else { return nil }
            labels.append(String(decoding: b[i..<i + len], as: UTF8.self))
            i += len
        }
        return labels.joined(separator: ".")
    }
}
