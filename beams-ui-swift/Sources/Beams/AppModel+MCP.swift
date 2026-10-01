import Foundation

extension AppModel {
    /// Fills the Settings list from `tsh mcp ls`. Only when logged in: with an
    /// expired certificate tsh would start a (browser) login on its own.
    func loadMCPApps() async {
        guard !isMock else { mcpApps = []; mcpNote = "Mock backend: no Teleport MCP servers."; return }
        guard tsh.loggedIn else { mcpNote = "Log in to Teleport first."; return }
        mcpLoading = true
        defer { mcpLoading = false }
        do {
            mcpApps = try await tshClient.mcpList()
            mcpNote = mcpApps.isEmpty ? "No MCP servers in \(config.proxy) for this login (tsh mcp ls is empty)." : ""
        } catch {
            mcpNote = error.localizedDescription
        }
    }

    func teleportMCPEnabled(_ name: String) -> Bool {
        config.mcpServers.contains { $0.kind == .teleport && $0.name == name && $0.enabled }
    }

    func setTeleportMCP(_ name: String, enabled: Bool) {
        if let i = config.mcpServers.firstIndex(where: { $0.kind == .teleport && $0.name == name }) {
            config.mcpServers[i].enabled = enabled
        } else if enabled {
            config.mcpServers.append(MCPServer(kind: .teleport, name: name))
        }
    }

    func removeMCP(_ id: String) {
        config.mcpServers.removeAll { $0.id == id }
        reconcileMCP()
    }

    /// tsh with its full path: supervised commands run under /bin/sh, whose
    /// PATH may lack it when the app is launched from the Dock.
    private var resolvedTsh: TshClient {
        var t = tshClient
        t.bin = Shell.which(t.bin) ?? t.bin
        return t
    }

    var mcpTunnelCount: Int { mcpStatus.keys.filter { $0.hasPrefix("tunnel:") }.count }

    // MARK: - supervised proxies and tunnels

    /// Before a turn: make sure the laptop proxies run and this beam has a
    /// tunnel for the laptop ports. Doesn't wait; the turn script waits for
    /// the ports to answer through the tunnel.
    func prepareMCP(beamID: String) {
        guard !isMock else { return }
        reconcileMCP()
        let ports = MCPConfig.laptopPorts(config.mcpServers)
        guard !ports.isEmpty else { return }
        let key = "tunnel:\(beamID)"
        if mcpSupervisors[key] != nil, mcpTunnelPorts[key] == ports { mcpSupervisors[key]?.start(); return }
        stopSupervisor(key)
        guard let uuid = beams.first(where: { $0.id == beamID })?.raw["uuid"], !uuid.isEmpty else {
            toast("Can't tunnel laptop MCP servers: no node id for this beam yet. Refresh sandboxes and try again.", .err, seconds: 7)
            return
        }
        let cmd = resolvedTsh.tunnelArgs(nodeUUID: uuid, login: beamLogin, ports: ports)
        let host = hostOnly(config.proxy)
        mcpTunnelPorts[key] = ports
        startSupervisor(key, label: "MCP tunnel", healthPort: nil) { [weak self] in
            if let why = self?.loginWait(host) { return .failure(why) }
            return .success(cmd)
        }
    }

    /// Brings proxies in line with Settings (start enabled, stop removed or
    /// disabled) and rebuilds tunnels whose port set changed.
    func reconcileMCP() {
        guard !isMock else { return }
        let wanted = MCPConfig.active(config.mcpServers).filter { $0.kind == .laptop && !MCPServer.safeAppName($0.proxyApp).isEmpty }
        let wantedKeys = Set(wanted.map { "proxy:\($0.id)" })
        for key in mcpSupervisors.keys where key.hasPrefix("proxy:") && !wantedKeys.contains(key) { stopSupervisor(key) }
        for s in wanted where mcpSupervisors["proxy:\(s.id)"] == nil {
            let cmd = resolvedTsh.proxyAppCommand(s)
            let host = resolvedTsh.proxyHost(s)
            mcpProxyHosts["proxy:\(s.id)"] = host
            startSupervisor("proxy:\(s.id)", label: "tsh proxy app \(s.proxyApp)", healthPort: s.port) { [weak self] in
                if let why = self?.loginWait(host) { return .failure(why) }
                return .success(cmd)
            }
        }
        let ports = MCPConfig.laptopPorts(config.mcpServers)
        for key in Array(mcpSupervisors.keys) where key.hasPrefix("tunnel:") && mcpTunnelPorts[key] != ports {
            stopSupervisor(key)
            if !ports.isEmpty { prepareMCP(beamID: String(key.dropFirst("tunnel:".count))) }
        }
    }

    /// Stops tunnels into beams that no longer exist.
    func pruneMCPTunnels() {
        for key in Array(mcpSupervisors.keys) where key.hasPrefix("tunnel:") {
            let id = String(key.dropFirst("tunnel:".count))
            if !beams.contains(where: { $0.id == id }) { stopSupervisor(key) }
        }
    }

    func stopTunnel(_ beamID: String) { stopSupervisor("tunnel:\(beamID)") }

    func stopAllMCP() {
        for key in Array(mcpSupervisors.keys) { stopSupervisor(key) }
        mcpLoginWatch?.cancel(); mcpLoginWatch = nil
    }

    /// Why a supervised tsh command shouldn't start now: its cluster's login
    /// is missing or (nearly) expired. Starting it anyway would make tsh begin
    /// a login by itself.
    func loginWait(_ host: String) -> Supervisor.WaitReason? {
        guard tsh.tshFound || !tshChecked else { return .init(text: "tsh not found") }
        guard let exp = tsh.profileExpiry[host] else { return .init(text: "waiting for a tsh login to \(host)") }
        if exp.timeIntervalSinceNow < 30 { return .init(text: "waiting for tsh login to \(host) (expired)") }
        return nil
    }

    /// After `checkTsh` sees certificates change: wake waiting supervisors and
    /// restart running ones whose cluster got a new certificate.
    func mcpLoginsChanged(from old: [String: Date]) {
        for (key, sup) in mcpSupervisors {
            let host = key.hasPrefix("tunnel:") ? hostOnly(config.proxy) : (mcpProxyHosts[key] ?? "")
            let now = tsh.profileExpiry[host]
            guard now != old[host], let now, now > Date() else { continue }
            if sup.isRunning { sup.restart() } else { sup.resume() }
        }
    }

    private func startSupervisor(_ key: String, label: String, healthPort: Int?,
                                 command: @escaping () -> Result<[String], Supervisor.WaitReason>) {
        let sup = Supervisor(key: key, healthPort: healthPort, command: command,
            onState: { [weak self] st in
                guard let self else { return }
                if st == .stopped { self.mcpStatus[key] = nil } else { self.mcpStatus[key] = st.label }
                if case .waiting = st { self.watchForLogin() }
            },
            onStderr: { [weak self] line in
                NSLog("[beams] %@: %@", label, line)
                let l = line.lowercased()
                guard l.contains("forwarding failed") || l.contains("access denied") || l.contains("error") else { return }
                self?.toast("\(label): \(line)", .err, seconds: 8)
            })
        mcpSupervisors[key] = sup
        sup.start()
    }

    private func stopSupervisor(_ key: String) {
        mcpSupervisors.removeValue(forKey: key)?.stop()
        mcpStatus[key] = nil
        mcpTunnelPorts[key] = nil
        mcpProxyHosts[key] = nil
    }

    /// While something waits for a login, re-read `tsh status` every 30s so a
    /// `tsh login` done outside the app is noticed (one tsh call, not a flood).
    private func watchForLogin() {
        guard mcpLoginWatch == nil else { return }
        mcpLoginWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let waiting = self.mcpStatus.values.contains { $0.hasPrefix("waiting") }
                if !waiting { break }
                _ = await self.checkTsh()
            }
            self?.mcpLoginWatch = nil
        }
    }
}
