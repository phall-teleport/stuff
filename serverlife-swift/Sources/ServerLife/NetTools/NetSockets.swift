import Foundation

// sockets.js — what is listening, and what is connected: `lsof -i -n -P` on
// this machine, `ss -tulpn` (else `netstat -tulpn`) on a host over its session.
// Three tools, three layouts, one shape out. `line` is the row exactly as the
// tool printed it — the honest fallback when a column comes back empty.

struct SocketRow: Equatable {
    var proto: String
    var state: String
    var localAddr: String?
    var localPort: Int?
    var remoteAddr: String?
    var remotePort: Int?
    var pid: Int?
    var process: String?
    var line: String
}

struct SocketsResult {
    var ok: Bool
    var rows: [SocketRow]
    var text: String
    var tool: String?
    var missing: String?
    var command: String
    var from: String?
    var hint: String?
}

enum NetSockets {
    private static func ws(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    private static func jsNumber(_ s: String) -> Int? { ntInt(ntNumber(s)).flatMap { $0 == 0 ? nil : $0 } }

    /// `*` or empty means "not applicable" (a listening socket has no peer).
    static func splitAddrPort(_ s: String?) -> (addr: String?, port: Int?) {
        let v = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty || v == "*" || v == "*:*" { return (nil, nil) }
        // [::1]:443 — bracketed, unambiguous.
        if let m = NetCheck.firstMatch(#"^\[([^\]]*)\]:(\*|\d+)$"#, v) {
            let a = m[1] ?? ""
            return (a.isEmpty ? nil : a, m[2] == "*" ? nil : Int(m[2] ?? ""))
        }
        // Everything else splits on the *last* colon.
        guard let i = v.lastIndex(of: ":") else { return (v, nil) }
        let addr = String(v[..<i])
        let portStr = String(v[v.index(after: i)...])
        return (addr.isEmpty ? nil : addr, portStr == "*" ? nil : jsNumber(portStr))
    }

    /// `ss -tulpn`:
    ///   tcp  LISTEN 0 128  0.0.0.0:22  0.0.0.0:*  users:(("sshd",pid=123,fd=3))
    static func parseSs(_ text: String) -> [SocketRow] {
        lines(text).compactMap { line in
            if line.isEmpty || line.range(of: #"^netid\s"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
            let parts = ws(line)
            guard parts.count >= 5, parts[0].range(of: "^(tcp|tcp6|udp|udp6)$", options: [.regularExpression, .caseInsensitive]) != nil
            else { return nil }
            let proto = parts[0], state = parts[1]
            let rest = parts.count > 6 ? parts[6...].joined(separator: " ") : ""
            let pm = NetCheck.firstMatch(#"\(\("([^"]+)",pid=(\d+)"#, rest)
            let l = splitAddrPort(parts[4])
            let p = splitAddrPort(parts.count > 5 ? parts[5] : nil)
            return SocketRow(proto: proto.lowercased(), state: proto.lowercased().hasPrefix("udp") ? "" : state,
                             localAddr: l.addr, localPort: l.port,
                             remoteAddr: p.port != nil ? p.addr : nil, remotePort: p.port,
                             pid: pm.flatMap { Int($0[2] ?? "") }, process: pm?[1], line: line)
        }
    }

    /// `netstat -tulpn`: UDP lines carry one column fewer (no State).
    static func parseNetstatLinux(_ text: String) -> [SocketRow] {
        lines(text).compactMap { line in
            guard line.range(of: #"^(tcp|tcp6|udp|udp6)\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
            let parts = ws(line)
            guard parts.count >= 6 else { return nil }
            let proto = parts[0]
            let udp = proto.lowercased().hasPrefix("udp")
            let state = udp ? "" : parts[5]
            let idx = udp ? 5 : 6
            let pidProg = idx < parts.count ? parts[idx] : ""
            var pid: Int? = nil, process: String? = nil
            if !pidProg.isEmpty, pidProg != "-", let slash = pidProg.firstIndex(of: "/"), slash != pidProg.startIndex {
                pid = jsNumber(String(pidProg[..<slash]))
                let p = String(pidProg[pidProg.index(after: slash)...])
                process = p.isEmpty ? nil : p
            }
            let l = splitAddrPort(parts[3]), f = splitAddrPort(parts[4])
            return SocketRow(proto: proto.lowercased(), state: state, localAddr: l.addr, localPort: l.port,
                             remoteAddr: f.port != nil ? f.addr : nil, remotePort: f.port,
                             pid: pid, process: process, line: line)
        }
    }

    /// `lsof -i -n -P`:
    ///   sshd 456 root 10u IPv4 0x… 0t0 TCP 10.0.0.5:22->10.0.0.8:51515 (ESTABLISHED)
    static func parseLsof(_ text: String) -> [SocketRow] {
        lines(text).compactMap { line in
            guard let m = NetCheck.firstMatch(#"^(\S+)\s+(\d+)\s+\S+\s+\S+\s+IPv[46]\s+\S+\s+\S+\s+(TCP|UDP)\s+(.+)$"#,
                                              line, options: .caseInsensitive),
                  let process = m[1], let pidStr = m[2], let proto = m[3], let tail = m[4] else { return nil }
            let sm = NetCheck.firstMatch(#"^(.+?)(?:\s+\(([A-Za-z_]+)\))?$"#, tail)
            let addrPart = sm?[1] ?? tail
            let state = sm?[2] ?? ""
            let halves = addrPart.components(separatedBy: "->")
            let l = splitAddrPort(halves[0])
            let r: (addr: String?, port: Int?) = halves.count > 1 ? splitAddrPort(halves[1]) : (nil, nil)
            return SocketRow(proto: proto.lowercased(), state: proto.lowercased() == "udp" ? "" : state,
                             localAddr: l.addr, localPort: l.port,
                             remoteAddr: r.port != nil ? r.addr : nil, remotePort: r.port,
                             pid: jsNumber(pidStr), process: process, line: line)
        }
    }

    /// Local listening sockets and connections (`lsof -i -n -P` on macOS).
    static func listSockets() async -> SocketsResult {
        let command = "lsof -i -n -P"
        let r = await NetProc.run("/usr/sbin/lsof", ["-i", "-n", "-P"], timeout: 15, maxBuffer: 8 * 1024 * 1024)
        if r.spawnError != nil { return SocketsResult(ok: false, rows: [], text: "", missing: "lsof", command: command) }
        let text = (r.stdout.isEmpty ? r.err : r.out).trimmingCharacters(in: .whitespacesAndNewlines)
        return SocketsResult(ok: true, rows: parseLsof(text), text: text, tool: "lsof", command: command)
    }

    /// The remote half (connections.js hostSockets): whichever of ss/netstat
    /// the host's capability probe found, over the session's exec.
    @MainActor
    static func hostSockets(_ connId: String) async throws -> SocketsResult {
        let conn = try NTConnections.require(connId)
        let caps = try? await NetRemote.hostTools(connId)
        let from: String? = conn.label
        let pick: (tool: String, cmd: String)? = caps?.tools.contains("ss") == true ? ("ss", "ss -tulpn 2>&1")
            : caps?.tools.contains("netstat") == true ? ("netstat", "netstat -tulpn 2>&1") : nil
        guard let pick else {
            return SocketsResult(ok: false, rows: [], text: "", missing: "ss", command: "ss -tulpn",
                                 from: from, hint: await NetRemote.hintFor(conn, "ss"))
        }
        let text: String
        do { text = try await NTConnections.exec(connId, "LC_ALL=C; \(pick.cmd)", timeout: 15, keepOutput: true) }
        catch { text = (error as? AppError)?.message ?? error.localizedDescription }
        return SocketsResult(ok: true, rows: pick.tool == "ss" ? parseSs(text) : parseNetstatLinux(text),
                             text: text.trimmingCharacters(in: .whitespacesAndNewlines), tool: pick.tool,
                             command: pick.tool == "ss" ? "ss -tulpn" : "netstat -tulpn", from: from)
    }
}
