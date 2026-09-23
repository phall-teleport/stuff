import SwiftUI

/// Sheet listing sessions synced to the configured repo/branch/prefix, so an
/// earlier session (from this Mac or another one) can be picked up again.
struct OpenFromGitHubView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open a previous session").font(.title3.weight(.semibold))
                    Text(sourceLabel).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { Task { await model.loadRemoteSessions() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload from GitHub").disabled(model.loadingRemote)
            }

            TextField("Search by title, beam or id", text: $m.remoteQuery)
                .textFieldStyle(.roundedBorder)

            Group {
                if model.loadingRemote && model.remoteSessions.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Reading sessions from GitHub…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.remoteError.isEmpty {
                    VStack(spacing: 8) {
                        Text(model.remoteError).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if !model.config.github.repo.contains("/") {
                            Button("Open the GitHub panel") {
                                model.showOpenFromGitHub = false
                                model.showInspector = true; model.inspectorTab = .github
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.filteredRemoteSessions.isEmpty {
                    Text(model.remoteSessions.isEmpty
                         ? "No sessions synced to \(GitHubSync.prefix(model.config.github))/sessions on this branch yet."
                         : "No sessions match “\(model.remoteQuery)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.filteredRemoteSessions) { r in
                        RemoteSessionRow(session: r)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.importRemoteSession(r) }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 280)

            HStack {
                Text("Double-click a session, or use Open. It's copied into your sessions; continue it in any beam.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.showOpenFromGitHub = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 640, height: 480)
    }

    private var sourceLabel: String {
        let g = model.config.github
        guard g.repo.contains("/") else { return "No repository configured" }
        return "\(g.repo) · \(g.branch.isEmpty ? "main" : g.branch) · \(GitHubSync.prefix(g))/sessions"
    }
}

struct RemoteSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: RemoteSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "Untitled session" : session.title).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if session.isCodex { badge("Codex", .purple) }
                    if session.hasWorkspace { badge("files", .blue) }
                    if session.hasMemory { badge("memory", .teal) }
                    if session.resumable { badge("resumable", .green) }
                    else if session.turns > 0 { badge("transcript only", .orange) }
                    if model.isLocal(session.id) { badge("already here", .gray) }
                }
            }
            Spacer()
            Button(model.isLocal(session.id) ? "Show" : "Open") { model.importRemoteSession(session) }
        }
        .padding(.vertical, 3)
        .help(session.resumable
              ? "The agent's conversation was saved, so continuing picks up exactly where it left off."
              : "Synced before conversations were saved: continuing starts a new conversation with the old transcript, files and memory restored.")
    }

    private var details: String {
        var parts: [String] = []
        if !session.beamName.isEmpty { parts.append(session.beamName) }
        parts.append("\(session.turns) turn\(session.turns == 1 ? "" : "s")")
        if let u = session.updated { parts.append(u.formatted(date: .abbreviated, time: .shortened)) }
        parts.append(String(session.id.prefix(8)))
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

/// Shown above the transcript when the current session's beam no longer
/// exists: pick a beam (or a new one) and move the session into it.
struct ContinueBanner: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        @Bindable var m = model
        let plan = model.restorePlan(session)
        let busy = model.restoring.contains(session.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.blue).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.beamName.isEmpty ? "This session isn't in a beam yet"
                                                  : "The beam \(session.beamName) for this session is gone")
                        .font(.headline)
                    Text(summary(plan)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Continue in").foregroundStyle(.secondary)
                Picker("", selection: $m.continueBeamID) {
                    ForEach(model.beams) { b in Text(b.name).tag(b.id) }
                    Text("New beam").tag("")
                }
                .labelsHidden().frame(maxWidth: 220)
                Button {
                    Task { await model.continueSession(session.id) }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Continue here") }
                }
                .buttonStyle(.borderedProminent).disabled(busy)
                Spacer()
            }
            if !model.continueBeamID.isEmpty, plan.files > 0 {
                Text("Files go into \(model.config.workDir) on that beam; files with the same names are replaced.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.35)))
        .padding(.horizontal, 28).padding(.top, 14)
    }

    private func summary(_ p: AppModel.RestorePlan) -> String {
        var bring: [String] = []
        if p.files > 0 { bring.append("\(p.files) file\(p.files == 1 ? "" : "s")") }
        if p.memory { bring.append("memory") }
        if session.turns > 0 { bring.append(p.resumable ? "the conversation" : "the previous transcript") }
        let head = bring.isEmpty ? "Pick a beam to keep going." : "Continuing brings \(joined(bring))."
        guard session.turns > 0, !p.resumable else { return head }
        return head + " The agent's conversation wasn't saved, so it starts fresh with the old transcript to read."
    }

    private func joined(_ xs: [String]) -> String {
        xs.count <= 1 ? xs.joined() : xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }
}
