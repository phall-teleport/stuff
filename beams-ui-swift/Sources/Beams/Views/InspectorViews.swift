import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            Picker("", selection: $m.inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch model.inspectorTab {
            case .memory: MemoryPanel()
            case .github: GitHubPanel()
            }
        }
        .task { if model.inspectorTab == .github, model.gh.loggedIn { await model.loadRepos() } }
    }
}

// MARK: - Memory

struct MemoryPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { Task { await model.pullMemory() } } label: { Label("Pull from beam", systemImage: "arrow.down") }
                Button { Task { await model.restoreMemory() } } label: { Label("Restore from GitHub", systemImage: "arrow.up") }
            }
            .disabled(model.current == nil)
            Text("Snapshot of ~/.claude/projects/*/memory and CLAUDE.md inside the beam. Pull after a turn, or turn on auto-sync.")
                .font(.caption).foregroundStyle(.secondary)
            if model.current == nil {
                Text("Open a session to see its memory.").font(.callout).foregroundStyle(.tertiary)
            } else if model.memory.isEmpty {
                Text("No memory pulled yet.").font(.callout).foregroundStyle(.tertiary)
            } else {
                List(model.memory, selection: Binding(get: { model.memorySelected?.id }, set: { id in
                    if let f = model.memory.first(where: { $0.id == id }) { model.selectMemory(f) }
                })) { f in
                    HStack {
                        Text(f.path).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Text("\(f.size) B").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .tag(f.id)
                }
                .frame(minHeight: 120, maxHeight: 220)
                if model.memorySelected != nil {
                    ScrollView {
                        Text(model.memoryContent).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }
            }
            Spacer()
        }
        .padding(12)
    }
}

// MARK: - GitHub

struct GitHubPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                authRow
                if let code = model.ghDeviceCode { deviceBox(code) }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Repository").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await model.loadRepos(force: true) }
                        } label: {
                            Label(model.loadingRepos ? "loading…" : "\(model.repos.count) repos accessible", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless).disabled(model.loadingRepos)
                    }
                    RepoPicker(selection: $m.config.github.repo, repos: model.repos) {
                        model.branchesFor = ""; model.saveConfig(); Task { await model.loadBranches(force: true) }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Branch").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { model.newBranch ? "__new__" : model.config.github.branch },
                                                      set: { v in
                                                          if v == "__new__" { model.newBranch = true; if model.newBranchName.isEmpty { model.newBranchName = "" } }
                                                          else { model.newBranch = false; model.config.github.branch = v; model.saveConfig() }
                                                      })) {
                            ForEach(model.branches, id: \.self) { Text($0).tag($0) }
                            if !model.branches.contains(model.config.github.branch), !model.config.github.branch.isEmpty, !model.newBranch {
                                Text(model.config.github.branch).tag(model.config.github.branch)
                            }
                            Text("＋ New branch…").tag("__new__")
                        }
                        .labelsHidden()
                        if model.newBranch {
                            TextField("new-branch-name", text: $m.newBranchName)
                                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                                .onSubmit { model.commitBranchChoice() }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Path prefix").font(.caption).foregroundStyle(.secondary)
                        TextField("beams", text: $m.config.github.prefix).textFieldStyle(.roundedBorder)
                            .onSubmit { model.saveConfig() }
                    }
                }

                Toggle("Sync after every turn", isOn: $m.config.github.autoSync)
                    .onChange(of: model.config.github.autoSync) { _, _ in model.saveConfig() }

                HStack {
                    Button("Save") { model.commitBranchChoice(); model.toast("GitHub settings saved", .ok) }
                    Button("Create private repo") { model.createRepo() }
                    Spacer()
                    Button { Task { await model.syncNow() } } label: {
                        if model.syncing { ProgressView().controlSize(.small) } else { Text("Sync beam session") }
                    }
                    .buttonStyle(.borderedProminent).disabled(model.syncing)
                    .help(model.current == nil ? "Open a session first" : "Commit this session's transcript and memory")
                }

                if let s = model.current, !s.lastSync.isEmpty {
                    HStack(spacing: 4) {
                        Text("Last sync:").font(.caption).foregroundStyle(.secondary)
                        Button("Last commit ↗") { model.open(s.lastSync) }.buttonStyle(.link).font(.caption)
                    }
                } else {
                    Text("Not synced yet.").font(.caption).foregroundStyle(.secondary)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.syncLog.enumerated()), id: \.offset) { _, l in
                                Text(l).font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 140)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .onChange(of: model.syncLog.count) { _, _ in proxy.scrollTo("end") }
                }
            }
            .padding(12)
        }
        .task { await model.loadBranches() }
    }

    private var authRow: some View {
        HStack(spacing: 8) {
            Circle().fill(model.gh.loggedIn ? .green : .red).frame(width: 7, height: 7)
            Text(!model.ghChecked ? "Checking GitHub sign-in…"
                 : !model.gh.installed ? "GitHub CLI (gh) not installed — brew install gh"
                 : model.gh.loggedIn ? "Signed in to GitHub as \(model.gh.user) (private repos OK)"
                 : "Not signed in to GitHub")
                .font(.callout).lineLimit(1).truncationMode(.tail).help(model.gh.detail)
            Spacer()
            if model.gh.installed && !model.gh.loggedIn {
                Button("Sign in") { model.githubLogin() }.disabled(model.ghLoggingIn)
            }
            if model.gh.loggedIn {
                Button("Sign out") { model.githubLogout() }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private func deviceBox(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(code).font(.system(size: 24, design: .monospaced)).foregroundStyle(Color.accentColor).textSelection(.enabled)
            Text("Enter this code on github.com/login/device. The browser should have opened automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open github.com/login/device") { model.open("https://github.com/login/device") }.buttonStyle(.link).font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

/// A searchable owner/name field with suggestions from the accessible repos.
struct RepoPicker: View {
    @Binding var selection: String
    let repos: [GitHubRepo]
    let onCommit: () -> Void
    @StateObject private var open = LocalFlag()
    @FocusState private var focused: Bool

    private var matches: [GitHubRepo] {
        let q = selection.lowercased()
        let list = q.isEmpty ? repos : repos.filter { $0.fullName.lowercased().contains(q) }
        return Array(list.prefix(40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("type to search your repos…", text: $selection)
                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                .focused($focused)
                .onChange(of: focused) { _, f in open.on = f }
                .onSubmit { open.on = false; onCommit() }
            if open.on && !matches.isEmpty && selection != matches.first?.fullName {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { r in
                            Button {
                                selection = r.fullName; open.on = false; focused = false; onCommit()
                            } label: {
                                HStack {
                                    Text(r.fullName).font(.callout.monospaced()).lineLimit(1)
                                    Spacer()
                                    Text(r.isPrivate ? "private" : "public").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
        }
    }
}
