import Foundation

/// An MCP server the agent in the beam can use. Two ways to reach one:
///
/// - `.teleport`: an MCP app registered in the beam's Teleport cluster (see
///   `tsh mcp ls`). The beam connects to it itself with `tsh mcp connect
///   <app>` (a stdio bridge), using the beam's own delegated identity.
///   Nothing runs on the laptop.
/// - `.laptop`: an HTTP MCP endpoint on this Mac at 127.0.0.1:<port>, e.g.
///   one `tsh proxy app --port <port> <app>` serves for an app in another
///   cluster, or any local MCP server. The app keeps a reverse SSH tunnel
///   (`tsh ssh -N -R <port>:127.0.0.1:<port> beams@<beam uuid>`) open while it
///   runs, so the agent sees the same URL on the beam's loopback. When
///   `proxyApp` is set the app also runs that `tsh proxy app` for you.
struct MCPServer: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case teleport, laptop }

    var id: String = UUID().uuidString.lowercased()
    var kind: Kind
    /// Teleport app name (`.teleport`), or a label (`.laptop`).
    var name: String
    var enabled: Bool = true
    /// `.laptop`: port on this Mac, and the same port on the beam's loopback.
    var port: Int = 0
    /// `.laptop`: URL path of the MCP endpoint.
    var path: String = "/mcp"
    /// `.laptop`: Teleport app to serve on `port` with `tsh proxy app`; empty
    /// when something else already listens there.
    var proxyApp: String = ""
    /// `.laptop`: proxy of the cluster `proxyApp` lives in; empty = the Beams proxy.
    var proxyCluster: String = ""

    /// Key in the agent's MCP config (also the tool prefix it shows).
    var configName: String {
        let s = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" })
        return s.isEmpty ? "mcp" : s
    }

    /// Teleport resource names: letters, digits, `-_.:/` (scoped apps use "/scope::name").
    static func safeAppName(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/".contains($0)) })
    }

    var normalizedPath: String {
        let p = path.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return "" }
        return p.hasPrefix("/") ? p : "/" + p
    }

    var beamURL: String { "http://127.0.0.1:\(port)\(normalizedPath)" }

    var isUsable: Bool {
        switch kind {
        case .teleport: return !Self.safeAppName(name).isEmpty
        case .laptop: return (1...65535).contains(port)
        }
    }
}

/// An MCP server app listed by `tsh mcp ls -f json`.
struct MCPApp: Identifiable, Hashable {
    var name: String
    var description: String
    var uri: String
    var id: String { name }

    /// Rows are Teleport app resources (`metadata.name`, `spec.uri`); a flat
    /// `name` is accepted too. `null` (no servers) parses to [].
    static func parse(_ json: Any) -> [MCPApp] {
        guard let rows = json as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let meta = row["metadata"] as? [String: Any] ?? [:]
            let spec = row["spec"] as? [String: Any] ?? [:]
            let name = meta["name"] as? String ?? row["name"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            return MCPApp(name: name,
                          description: meta["description"] as? String ?? row["description"] as? String ?? "",
                          uri: spec["uri"] as? String ?? row["uri"] as? String ?? "")
        }
    }
}

enum MCPConfig {
    static func active(_ servers: [MCPServer]) -> [MCPServer] {
        var seen = Set<String>()
        return servers.filter { $0.enabled && $0.isUsable && seen.insert($0.configName).inserted }
    }

    /// Ports that must answer through the tunnel before the agent starts.
    static func laptopPorts(_ servers: [MCPServer]) -> [Int] {
        Array(Set(active(servers).filter { $0.kind == .laptop }.map(\.port))).sorted()
    }

    /// `claude --mcp-config` JSON; nil when there's nothing to add.
    static func claudeJSON(_ servers: [MCPServer]) -> String? {
        let list = active(servers)
        guard !list.isEmpty else { return nil }
        var map: [String: Any] = [:]
        for s in list {
            switch s.kind {
            case .teleport:
                map[s.configName] = ["type": "stdio", "command": "tsh", "args": ["mcp", "connect", MCPServer.safeAppName(s.name)]]
            case .laptop:
                map[s.configName] = ["type": "http", "url": s.beamURL]
            }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: ["mcpServers": map], options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// `codex -c` overrides (TOML values). Unverified against a live Codex.
    static func codexOverrides(_ servers: [MCPServer]) -> [String] {
        active(servers).flatMap { s -> [String] in
            let key = "mcp_servers.\(s.configName)"
            switch s.kind {
            case .teleport:
                return ["\(key).command=\"tsh\"", "\(key).args=[\"mcp\",\"connect\",\"\(MCPServer.safeAppName(s.name))\"]"]
            case .laptop:
                return ["\(key).url=\"\(s.beamURL)\""]
            }
        }
    }

    /// Shell lines that wait (up to ~10s each) for tunneled ports to answer,
    /// so the agent doesn't start before the reverse tunnel is up.
    static func waitScript(_ servers: [MCPServer]) -> String {
        let ports = laptopPorts(servers)
        guard !ports.isEmpty else { return "" }
        return "for p in \(ports.map(String.init).joined(separator: " ")); do i=0; "
            + "until curl -s -o /dev/null -m 1 \"http://127.0.0.1:$p/\"; do i=$((i+1)); "
            + "if [ $i -ge 20 ]; then echo \"beams: MCP port $p on the laptop is not reachable from the beam\" >&2; break; fi; "
            + "sleep 0.5; done; done\n"
    }
}

extension TshClient {
    /// `tsh mcp ls -f json`. Note: an expired certificate makes tsh start a
    /// login (it opens the browser for SSO), so callers check status first.
    func mcpList() async throws -> [MCPApp] {
        let res = try await Shell.run(mcpArgs(["mcp", "ls", "-f", "json"]), extraEnv: Self.env, timeout: 45)
        var data = res.stdout
        guard let i = data.firstIndex(where: { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "{") }) else { return [] }
        data = data[i...]
        return MCPApp.parse((try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? [])
    }

    /// Reverse tunnel for `.laptop` servers: the beam's 127.0.0.1:<port> →
    /// this Mac's 127.0.0.1:<port>. `tsh beams ssh` has no -R, but beams are
    /// OpenSSH nodes named by their uuid, so plain `tsh ssh` reaches them.
    /// Verified 2026-09-30: curl in the beam fetched a laptop-only server.
    func tunnelArgs(nodeUUID: String, login: String, ports: [Int]) -> [String] {
        var a = mcpArgs(["ssh", "-N"])
        for p in ports { a += ["-R", "\(p):127.0.0.1:\(p)"] }
        return a + ["\(login)@\(nodeUUID)"]
    }

    /// `tsh proxy app` for a `.laptop` server backed by a Teleport app.
    func proxyAppArgs(_ s: MCPServer) -> [String] {
        var a = [bin]
        let cluster = s.proxyCluster.trimmingCharacters(in: .whitespaces)
        a.append("--proxy=\(cluster.isEmpty ? proxy : cluster)")
        // --browser=none: if the login has expired, print the link rather than
        // open a browser (the Supervisor sees it and waits for a login).
        return a + ["proxy", "app", "--browser=none", "--port", String(s.port), MCPServer.safeAppName(s.proxyApp)]
    }

    /// Runs `tsh apps login <app>` (as prism does), then execs the proxy.
    func proxyAppCommand(_ s: MCPServer) -> [String] {
        let px = proxyAppArgs(s)
        let login = [px[0], px[1], "apps", "login", MCPServer.safeAppName(s.proxyApp)]
        let script = login.map(Shell.quote).joined(separator: " ") + " >&2 && exec " + px.map(Shell.quote).joined(separator: " ")
        return ["/bin/sh", "-c", script]
    }

    /// The proxy host a laptop server's `tsh proxy app` talks to.
    func proxyHost(_ s: MCPServer) -> String {
        let c = s.proxyCluster.trimmingCharacters(in: .whitespaces)
        return hostOnly(c.isEmpty ? proxy : c)
    }

    private func mcpArgs(_ sub: [String]) -> [String] {
        var a = [bin]
        if !proxy.isEmpty { a.append("--proxy=\(proxy)") }
        return a + sub
    }
}

/// Runs a long-lived command so it dies with the app: the wrapper kills it
/// when its stdin (a pipe held by the app) closes, which also happens if the
/// app crashes. Without this, a quit leaves `tsh ssh -N` tunnels running.
/// (Background jobs get /dev/null as stdin, hence the fd 3 copy.) Stop it with
/// `closeStdin()`; terminating only the wrapper would orphan the command.
enum Supervised {
    static func argv(_ cmd: [String]) -> [String] {
        ["/bin/sh", "-c", "exec 3<&0; \"$@\" & c=$!; (read -r _ <&3; kill $c) >/dev/null 2>&1 & wait $c", "sh"] + cmd
    }
}
