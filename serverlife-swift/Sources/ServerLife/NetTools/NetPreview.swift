import Foundation

// nettools.js previewCommand(): the command a tool would run, with no I/O at
// all — for a live preview and the "Copy command" button, both answerable
// before the target is even dialled. Every branch mirrors the real
// function's own host/port parsing exactly, so what is copied here is never a
// command the real run would not have made. A target that is not valid yet —
// empty, or mid-keystroke — is not an error, just nothing to preview.

struct NetPreviewInput {
    var tool = ""
    var host = ""
    var ports = ""
    var count = ""
    var method = "GET"
    var insecure = false
    var telnetPort = ""
    var server = ""
    var ipVersion = ""
    var starttls = ""
    var headers = ""
}

enum NetPreview {
    /// The tools whose command is known before they run.
    static let tools = ["ping", "traceroute", "dns", "ports", "telnet", "tls", "http", "whois", "teleport"]

    /// The proxy ping URL — shared by the real call and the preview.
    static func webapiPingUrl(_ host: String, _ port: Int) -> String {
        "https://\(host.contains(":") ? "[\(host)]" : host):\(port)/webapi/ping"
    }

    static func teleportPingCommand(_ url: String, _ insecure: Bool) -> String {
        "curl -s\(insecure ? "k" : "") -- '\(url)'"
    }

    /// (command, note, error) — command nil when there is nothing to show.
    static func command(_ i: NetPreviewInput) -> (command: String?, note: String?, error: String?) {
        let raw = i.host.ntTrimmed
        if raw.isEmpty { return (nil, nil, nil) }
        do {
            let host = { try NetCheck.checkHost(NetCheck.splitHostPort(raw).host) }
            let ipv: String? = i.ipVersion.isEmpty ? nil : i.ipVersion
            switch i.tool {
            case "ping": return (NetLocal.pingCommand(try host(), i.count, ipv), nil, nil)
            case "traceroute": return (NetLocal.tracerouteCommand(try host(), nil, ipv), nil, nil)
            case "dns":
                let s = i.server.ntTrimmed
                return (NetLocal.dnsCommand(try host(), s.isEmpty ? nil : try NetCheck.checkHost(NetCheck.splitHostPort(s).host)), nil, nil)
            case "ports":
                let parsed = NetCheck.splitHostPort(raw)
                let h = try NetCheck.checkHost(parsed.host)
                let p = i.ports.ntTrimmed
                let list = !p.isEmpty ? try NetCheck.parsePorts(p) : (parsed.port.map { [$0] } ?? NetCheck.defaultPorts)
                return (list.map { NetLocal.portCommand(h, $0, ipv) }.joined(separator: "\n"), nil, nil)
            case "telnet":
                let parsed = NetCheck.splitHostPort(raw)
                let h = try NetCheck.checkHost(parsed.host)
                let tp = ntNumber(i.telnetPort).flatMap { $0 != 0 ? Int($0) : nil }
                return (NetLocal.telnetCommand(h, tp ?? parsed.port ?? 23), nil, nil)
            case "tls":
                let parsed = NetCheck.splitHostPort(raw)
                let h = try NetCheck.checkHost(parsed.host)
                let proto = NetTLS.startTLSPorts[i.starttls] != nil ? i.starttls : nil
                let p = parsed.port ?? (proto.flatMap { NetTLS.startTLSPorts[$0] } ?? 443)
                return (NetTLS.tlsCommand(h, p, proto), nil, nil)
            case "http":
                var u = raw
                if u.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil { u = "https://" + u }
                guard let url = URL(string: u), let hn = url.host else { throw AppError("Invalid URL") }
                _ = try NetCheck.checkHost(hn)
                return (NetTLS.httpCommand(NetTLS.normalised(url), i.method, i.insecure, i.headers), nil, nil)
            case "whois": return (NetLocal.whoisCommand(try host()), nil, nil)
            case "teleport":
                let parsed = NetCheck.splitHostPort(raw)
                let h = try NetCheck.checkHost(parsed.host)
                return (teleportPingCommand(webapiPingUrl(h, parsed.port ?? 443), i.insecure), nil, nil)
            default: return (nil, nil, nil)
            }
        } catch {
            return (nil, nil, error.localizedDescription)
        }
    }

    // MARK: Commands a result brings with it (decoders, This machine)

    /// `ssh-keygen -L`, when the certificate is a file on disk.
    static func sshCertCommand(_ file: String?) -> String? {
        guard let file, !file.isEmpty else { return nil }
        return "ssh-keygen -L -f '\(file)'"
    }

    static func jwtCommand(_ r: JWTResult) -> (command: String, note: String) {
        ("python3 -c \"import base64,json; p='\(r.raw.payload)'; p+='='*(-len(p)%4); "
            + "print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2))\"",
         "Needs python3 on PATH — on by default on macOS and most Linux, not guaranteed on Windows.")
    }

    static func svidCommand(_ r: SVIDResult) -> String { "openssl x509 -noout -text <<'EOF'\n\(r.pem)\nEOF" }

    static let macLocalCommand = "ifconfig\nnetstat -rn\nscutil --dns"
}
