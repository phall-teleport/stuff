import SwiftUI

/// State for one Services window: the beam's beam-init services and the logs
/// of the selected one (followed live by default).
@MainActor
final class ServicesState: ObservableObject {
    @Published var services: [BeamService] = []
    @Published var selected: String?
    @Published var lines: [String] = []
    @Published var following = true
    @Published var loading = false
    @Published var note = ""
    @Published var noBeamctl = false

    static let maxLines = 10_000
    private var logProc: RunningProcess?
    private var logGen = 0

    func refresh(_ model: AppModel, beamID: String) async {
        guard model.sshAllowed() else { note = model.sshBlockedReason ?? "Can't reach the beam."; return }
        loading = true
        defer { loading = false }
        do {
            let res = try await model.client.run(id: beamID, script: Beamctl.listScript)
            if String(decoding: res.stdout, as: UTF8.self).contains(Beamctl.missingMarker) {
                noBeamctl = true; services = []; return
            }
            noBeamctl = false
            services = Beamctl.parseList(res.stdout) ?? []
            note = services.isEmpty ? "No services yet. Start one in the beam with `beamctl start --name <name> -- <command>`." : ""
            if selected == nil || !services.contains(where: { $0.name == selected }) {
                select(services.first(where: \.isLive)?.name ?? services.first?.name, model, beamID: beamID)
            }
        } catch {
            model.noteSSHFailure(error.localizedDescription)
            note = error.localizedDescription
        }
    }

    func select(_ name: String?, _ model: AppModel, beamID: String) {
        selected = name
        startLogs(model, beamID: beamID)
    }

    /// (Re)loads the selected service's logs; with `following`, keeps streaming.
    func startLogs(_ model: AppModel, beamID: String) {
        stopLogs()
        lines = []
        guard let name = selected else { return }
        logGen += 1
        let gen = logGen, follow = following
        Task { [weak self] in
            do {
                try await model.client.run(id: beamID, script: Beamctl.logsScript(name, follow: follow), stdin: nil, interactiveStdin: false,
                    onStdoutLine: { line in Task { @MainActor in self?.append(Shell.stripANSI(line), gen) } },
                    onStderrLine: { line in Task { @MainActor in self?.append("[stderr] " + Shell.stripANSI(line), gen) } },
                    register: { p in Task { @MainActor in if self?.logGen == gen { self?.logProc = p } else { p.terminate() } } })
            } catch {
                await MainActor.run { if self?.logGen == gen, self?.logProc != nil { self?.append("[logs ended: \(error.localizedDescription)]", gen) } }
            }
        }
    }

    private func append(_ line: String, _ gen: Int) {
        guard gen == logGen else { return }
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    func stopLogs() {
        logGen += 1
        logProc?.terminate()
        logProc = nil
    }

    func act(_ action: String, _ model: AppModel, beamID: String) async {
        guard let name = selected, let script = Beamctl.actionScript(action, name), model.sshAllowed() else { return }
        do {
            try await model.client.run(id: beamID, script: script)
            model.toast("\(action.capitalized) \(name)", .ok)
        } catch {
            model.fail(error)
        }
        await refresh(model, beamID: beamID)
        if action == "restart" { startLogs(model, beamID: beamID) }
    }
}

/// Window listing a beam's beam-init services with live logs. Opened from a
/// sandbox's context menu ("Services and logs…").
struct ServicesWindow: View {
    @Environment(AppModel.self) private var model
    let beamID: String
    @StateObject private var st = ServicesState()

    private var beamName: String { model.beams.first { $0.id == beamID }?.name ?? beamID }

    var body: some View {
        HStack(spacing: 0) {
            serviceList.frame(width: 230)
            Divider()
            logPane
        }
        .frame(minWidth: 760, minHeight: 420)
        .navigationTitle("Services · \(beamName)")
        .task { await st.refresh(model, beamID: beamID) }
        .onDisappear { st.stopLogs() }
    }

    private var serviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Services").font(.headline)
                Spacer()
                if st.loading { ProgressView().controlSize(.small) }
                Button { Task { await st.refresh(model, beamID: beamID) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            .padding(10)
            Divider()
            if st.noBeamctl {
                Text("This beam doesn't run beam-init (it was created before beam-init became the default), so it has no services to show. New beams have it.")
                    .font(.callout).foregroundStyle(.secondary).padding(10)
            } else {
                List(st.services, selection: Binding(get: { st.selected }, set: { st.select($0, model, beamID: beamID) })) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(color(s)).frame(width: 7, height: 7)
                            Text(s.name).font(.body.monospaced()).lineLimit(1)
                        }
                        Text(s.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(s.name)
                    .contextMenu {
                        Button("Restart") { st.selected = s.name; Task { await st.act("restart", model, beamID: beamID) } }
                        if s.state == "Frozen" {
                            Button("Thaw") { st.selected = s.name; Task { await st.act("thaw", model, beamID: beamID) } }
                        } else if s.state == "Running" {
                            Button("Freeze") { st.selected = s.name; Task { await st.act("freeze", model, beamID: beamID) } }
                        }
                        Divider()
                        Button("Stop", role: .destructive) { st.selected = s.name; Task { await st.act("stop", model, beamID: beamID) } }
                            .disabled(!s.isLive)
                    }
                }
                .listStyle(.sidebar)
            }
            if !st.note.isEmpty {
                Text(st.note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(10)
            }
            Spacer(minLength: 0)
        }
    }

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(st.selected.map { "Logs · \($0)" } ?? "Logs").font(.headline)
                Spacer()
                Toggle("Follow", isOn: Binding(get: { st.following }, set: { st.following = $0; st.startLogs(model, beamID: beamID) }))
                    .toggleStyle(.switch).controlSize(.small)
                Button { st.startLogs(model, beamID: beamID) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload logs").disabled(st.selected == nil)
                CopyButton(help: "Copy logs") { st.lines.joined(separator: "\n") }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(st.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.isEmpty ? " " : line).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("[stderr]") ? Color.orange : Color.primary)
                                .textSelection(.enabled).id(i)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: st.lines.count) { _, n in
                    if st.following, n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
                .overlay {
                    if st.selected != nil && st.lines.isEmpty {
                        Text(st.following ? "Waiting for output…" : "No output").foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func color(_ s: BeamService) -> Color {
        switch s.state {
        case "Running": return .green
        case "Frozen", "Restarting", "Stopping": return .orange
        case "Error": return .red
        case "Exited": return s.detail == "exit 0" ? .gray : .red
        default: return .gray
        }
    }
}
