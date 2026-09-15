import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            MainView()
                .inspector(isPresented: $m.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
        }
        .overlay(alignment: .bottomTrailing) { ToastStack() }
        .confirmationDialog(model.confirm?.title ?? "", isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }),
                            titleVisibility: .visible, presenting: model.confirm) { req in
            Button(req.okLabel, role: req.destructive ? .destructive : nil) { req.action(); model.confirm = nil }
            if let label = req.secondaryLabel, let act = req.secondaryAction {
                Button(label) { act(); model.confirm = nil }
            }
            Button("Cancel", role: .cancel) { model.confirm = nil }
        } message: { req in
            Text(req.message)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                if model.beams.isEmpty {
                    Text(model.beamsNote.isEmpty ? "Loading…" : model.beamsNote)
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.beams) { b in
                        BeamRow(beam: b)
                    }
                }
            } header: {
                HStack {
                    Text("Sandboxes")
                    Spacer()
                    Button { Task { await model.loadBeams() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh")
                    Button { Task { await model.createBeam() } } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New beam")
                }
            }

            Section("Sessions") {
                if model.sessions.isEmpty {
                    Text("Sessions appear here.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.sessions) { s in
                    SessionRow(session: s)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Label("Beams", systemImage: "sparkles").font(.headline).foregroundStyle(Color.accentColor)
                Spacer()
                Text(model.backendLabel)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(model.isMock ? Color.orange.opacity(0.18) : Color.green.opacity(0.15)))
                    .foregroundStyle(model.isMock ? .orange : .green)
                    .help(model.isMock ? "BEAMSUI_MOCK=1 — simulated beams" : "tsh --proxy \(model.config.proxy)")
            }
            .padding(10)
            .background(.bar)
        }
    }
}

struct BeamRow: View {
    @Environment(AppModel.self) private var model
    let beam: Beam
    @StateObject private var hover = LocalFlag()

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text(beam.name).lineLimit(1)
            Spacer()
            Text(beam.raw["region"] ?? beam.state).font(.caption).foregroundStyle(.tertiary)
            if hover.on {
                Button { model.deleteBeam(beam) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete beam")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { Task { await model.startSession(on: beam) } }
        .contextMenu {
            Button("New session on \(beam.name)") { Task { await model.startSession(on: beam) } }
            Divider()
            Button("Delete beam…", role: .destructive) { model.deleteBeam(beam) }
        }
        .listRowBackground(model.current?.beamId == beam.id ? Color.accentColor.opacity(0.12) : nil)
        .help(tooltip)
    }

    private var tooltip: String {
        var lines = [beam.name]
        if let region = beam.raw["region"], !region.isEmpty { lines.append("Region: \(region)") }
        lines.append("Expires: \(Self.expiry(beam.raw["expires"]))")
        if let owner = beam.raw["owner"], !owner.isEmpty { lines.append("Owner: \(owner)") }
        lines.append("ID: \(beam.id)")
        return lines.joined(separator: "\n")
    }

    /// "Sep 12, 4:34 PM (in 3h)" from an RFC3339 timestamp; raw value if unparseable.
    static func expiry(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "unknown" }
        guard let date = RFC3339.parse(raw) else { return raw }
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        let now = Date()
        let phrase = date < now ? "expired" : rel.localizedString(for: date, relativeTo: now)
        return "\(f.string(from: date)) (\(phrase))"
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @StateObject private var hover = LocalFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(model.busy.contains(session.id) ? .orange : .green).frame(width: 7, height: 7)
                Text(session.title.isEmpty ? "New session" : session.title).lineLimit(1)
                Spacer()
                if hover.on {
                    Button { model.deleteSession(session) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove session, optionally deleting its beam")
                }
            }
            Text(meta).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { model.openSession(session.id) }
        .contextMenu { Button("Remove session…", role: .destructive) { model.deleteSession(session) } }
        .listRowBackground(model.currentID == session.id ? Color.accentColor.opacity(0.12) : nil)
    }

    private var meta: String {
        var parts = [session.beamName, "\(session.turns) turns", String(format: "$%.4f", session.costUsd), session.updated.relativeShort]
        if !session.lastSync.isEmpty { parts.append("synced") }
        if !session.publishedUrls.isEmpty { parts.append("🌐") }
        return parts.joined(separator: " · ")
    }
}

extension Date {
    var relativeShort: String {
        let d = Date().timeIntervalSince(self)
        if d < 60 { return "now" }
        if d < 3600 { return "\(Int(d / 60))m" }
        if d < 86400 { return "\(Int(d / 3600))h" }
        return "\(Int(d / 86400))d"
    }
}

// MARK: - Main column

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.tshChecked && !model.tsh.loggedIn { AuthBanner() }
            if let s = model.current {
                TranscriptView(sessionID: s.id)
                Composer()
            } else {
                EmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.current.map { $0.title.isEmpty ? "Session on \($0.beamName)" : $0.title } ?? "Beams")
        .navigationSubtitle(model.current.map { "\($0.beamName) · \($0.id.prefix(8))" } ?? "")
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let s = model.current, let latest = s.publishedUrls.last {
                    Button { model.open(latest) } label: {
                        Label(latest.replacingOccurrences(of: "https://", with: ""), systemImage: "globe")
                            .labelStyle(.titleAndIcon)
                    }
                    .help(s.publishedUrls.joined(separator: "\n"))
                }
                if let s = model.current {
                    Text(String(format: "$%.4f", s.costUsd)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if model.currentBusy {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }.help("Stop the running turn (⌘.)")
                }
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(Color.accentColor)
            Text("Do all the things, inside a Beam").font(.title2.weight(.semibold))
            Text("Create or pick a sandbox on the left. Each session runs Claude Code (or another model choosable from Settings) in the beam, streams the conversation here, and can commit the transcript and memory to GitHub.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
