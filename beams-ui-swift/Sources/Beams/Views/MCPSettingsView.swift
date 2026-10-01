import SwiftUI

/// Fields for a new laptop MCP server (no @State here; see LocalState.swift).
final class MCPDraft: ObservableObject {
    @Published var name = ""
    @Published var port = ""
    @Published var path = "/mcp"
    @Published var proxyApp = ""
    @Published var proxyCluster = ""

    func server() -> MCPServer? {
        guard let p = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return nil }
        let app = MCPServer.safeAppName(proxyApp)
        let label = name.trimmingCharacters(in: .whitespaces)
        return MCPServer(kind: .laptop, name: label.isEmpty ? (app.isEmpty ? "laptop-\(p)" : app) : label,
                         port: p, path: path, proxyApp: app, proxyCluster: proxyCluster.trimmingCharacters(in: .whitespaces))
    }

    func reset() { name = ""; port = ""; path = "/mcp"; proxyApp = ""; proxyCluster = "" }
}

/// Settings → MCP servers: Teleport MCP apps the beam connects to itself, and
/// HTTP servers on this Mac tunneled into the beam.
struct MCPSettingsSection: View {
    @Environment(AppModel.self) private var model
    @StateObject private var draft = MCPDraft()

    var body: some View {
        Section("MCP servers") {
            Text("Servers you turn on here are given to the agent in every turn (claude --mcp-config; Codex via -c, untested). Changes apply from the next turn; in persistent mode, from the next session process.")
                .font(.caption).foregroundStyle(.secondary)

            teleportServers
            laptopServers
            addLaptopServer
        }
    }

    // MARK: Teleport

    @ViewBuilder private var teleportServers: some View {
        HStack {
            Text("In \(model.config.proxy.isEmpty ? "the Beams cluster" : model.config.proxy)").font(.headline)
            Spacer()
            Button { Task { await model.loadMCPApps() } } label: {
                if model.mcpLoading { ProgressView().controlSize(.small) } else { Text("List with tsh mcp ls") }
            }
            .disabled(model.mcpLoading)
        }
        Text("The beam connects to these itself with `tsh mcp connect <name>`, using its own Teleport identity. They work without this Mac, and access follows your roles.")
            .font(.caption).foregroundStyle(.secondary)
        let saved = model.config.mcpServers.filter { $0.kind == .teleport }.map(\.name)
        let names = Array(Set(model.mcpApps.map(\.name) + saved)).sorted()
        if !model.mcpNote.isEmpty { Text(model.mcpNote).font(.caption).foregroundStyle(.secondary) }
        ForEach(names, id: \.self) { name in
            let app = model.mcpApps.first { $0.name == name }
            Toggle(isOn: Binding(get: { model.teleportMCPEnabled(name) }, set: { model.setTeleportMCP(name, enabled: $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.monospaced())
                    let detail = [app?.description, app?.uri, app == nil && !model.mcpApps.isEmpty ? "not listed for this login" : nil]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    // MARK: Laptop

    @ViewBuilder private var laptopServers: some View {
        Text("From this Mac").font(.headline).padding(.top, 4)
        Text("An HTTP MCP server listening on 127.0.0.1:<port> here. While the app is open it keeps `tsh ssh -N -R <port>:127.0.0.1:<port>` into the beam, so the agent uses http://127.0.0.1:<port><path> there. Name a Teleport app (for example one in another cluster) and the app runs `tsh apps login <app>` and `tsh proxy app --port <port> <app>` for you. Proxies and tunnels restart on their own if they die, and pause while your tsh login is expired. The beam loses access when you quit. Stdio-only servers need an HTTP bridge on this Mac.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(model.config.mcpServers.filter { $0.kind == .laptop }) { s in
            HStack {
                Toggle(isOn: Binding(get: { s.enabled }, set: { on in
                    if let i = model.config.mcpServers.firstIndex(where: { $0.id == s.id }) { model.config.mcpServers[i].enabled = on }
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.configName).font(.body.monospaced())
                        Text(laptopDetail(s)).font(.caption).foregroundStyle(.secondary)
                        if let st = model.mcpStatus["proxy:\(s.id)"] {
                            Text("proxy: \(st)").font(.caption).foregroundStyle(st == "running" ? .green : .orange)
                        }
                    }
                }
                Button { model.removeMCP(s.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove")
            }
        }
        let tunnels = model.mcpStatus.filter { $0.key.hasPrefix("tunnel:") }.sorted { $0.key < $1.key }
        ForEach(tunnels, id: \.key) { key, st in
            let id = String(key.dropFirst("tunnel:".count))
            Text("Tunnel into \(model.beams.first { $0.id == id }?.name ?? id): \(st)")
                .font(.caption).foregroundStyle(st == "running" ? .green : .orange)
        }
    }

    private func laptopDetail(_ s: MCPServer) -> String {
        var d = s.beamURL
        if !s.proxyApp.isEmpty {
            d += " ← tsh proxy app \(s.proxyApp)" + (s.proxyCluster.isEmpty ? "" : " (\(s.proxyCluster))")
        }
        return d
    }

    @ViewBuilder private var addLaptopServer: some View {
        TextField("Name", text: $draft.name, prompt: Text("e.g. grafana"))
        TextField("Port on this Mac", text: $draft.port, prompt: Text("e.g. 8931"))
        TextField("Path", text: $draft.path, prompt: Text("/mcp"))
        TextField("Teleport app to proxy (optional)", text: $draft.proxyApp, prompt: Text("leave empty if already listening"))
        if !draft.proxyApp.isEmpty {
            TextField("App's Teleport proxy", text: $draft.proxyCluster, prompt: Text(model.config.proxy))
        }
        HStack {
            Spacer()
            Button("Add server") {
                guard let s = draft.server() else { model.toast("Enter a port between 1 and 65535.", .err); return }
                if model.config.mcpServers.contains(where: { $0.kind == .laptop && $0.port == s.port }) {
                    model.toast("Port \(s.port) is already used by another server.", .err); return
                }
                model.config.mcpServers.append(s)
                draft.reset()
            }
            .disabled(draft.port.isEmpty)
        }
    }
}
