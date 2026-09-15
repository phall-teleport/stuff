import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    static let claudeModels = ["claude-sonnet-5", "claude-opus-5[1m]", "claude-opus-4-6[1m]"]
    static let codexModels = ["gpt-5-codex", "gpt-5", "o4-mini"]

    var body: some View {
        @Bindable var m = model
        Form {
            Section("Teleport") {
                TextField("Proxy", text: $m.config.proxy, prompt: Text("super-grass.beams.sh"))
                TextField("Teleport user (for tsh login)", text: $m.config.teleportUser, prompt: Text(model.osUser))
                TextField("tsh binary", text: $m.config.tshBin, prompt: Text("tsh"))
                Picker("Terminal for password logins", selection: $m.config.terminalApp) {
                    Text("Auto (iTerm2 if installed, else Terminal)").tag("")
                    Text("iTerm2").tag("iterm")
                    Text("Terminal.app").tag("terminal")
                }
            }
            Section("Inside the beam") {
                TextField("Beam login", text: $m.config.login, prompt: Text("(cluster default)"))
                TextField("Working directory", text: $m.config.workDir, prompt: Text("/home/beams/work"))
                Picker("Permissions", selection: $m.config.permissionMode) {
                    Text("Bypass — never asks (sandbox default)").tag("bypass")
                    Text("Default — asks before each tool").tag("default")
                    Text("Accept edits — asks only for commands").tag("acceptEdits")
                    Text("Plan only — read-only").tag("plan")
                }
                Text("When Claude asks, an Allow / Deny card appears in the transcript (Y / N).")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Agent", selection: $m.config.agent) {
                    Text("Claude Code (Anthropic)").tag("claude")
                    Text("Codex (OpenAI)").tag("codex")
                }
                .onChange(of: model.config.agent) { _, _ in model.config.model = "" }
                Picker("Model", selection: $m.config.model) {
                    Text(model.config.agent == "codex" ? "Codex default" : "Beam default").tag("")
                    ForEach(model.config.agent == "codex" ? Self.codexModels : Self.claudeModels, id: \.self) { Text($0).tag($0) }
                }
                if model.config.agent == "codex" {
                    Text("Codex runs with approvals bypassed (beams are sandboxed). Permission prompts don't apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Experimental") {
                Toggle("Persistent session — keep one agent process alive per session (faster turns)", isOn: $m.config.persistentSession)
            }
            Section("Published apps") {
                Toggle("Open apps Claude publishes from a beam in my browser automatically",
                       isOn: Binding(get: { !model.config.disableAutoOpenApps }, set: { model.config.disableAutoOpenApps = !$0 }))
            }
            Section {
                Text("Backend: \(model.isMock ? "mock" : "tsh"). Data: \(model.store.root.path)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onChange(of: model.config) { _, _ in
            model.saveConfig()
            model.tshUser = model.config.teleportUser.isEmpty ? model.osUser : model.config.teleportUser
            Task { if await model.checkTsh() { await model.loadBeams() } }
        }
    }
}

// MARK: - Teleport login banner

struct AuthBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        let pending = model.tshPending
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(pending == nil ? Color.red : Color.orange).frame(width: 8, height: 8).padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if model.tsh.tshFound {
                    HStack(spacing: 6) {
                        Text("as").font(.caption).foregroundStyle(.secondary)
                        TextField("username", text: $m.tshUser).textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 150)
                            .onSubmit { model.tshLogin() }
                    }
                }
            }
            HStack(spacing: 8) {
                if model.tsh.tshFound {
                    Button("Log in with tsh") { model.tshLogin() }.buttonStyle(.borderedProminent).disabled(model.tshLoggingIn)
                    Button("Open in \(model.terminalAppName)") { model.openTerminalAndWait() }
                }
                Button { Task { await model.recheckTsh() } } label: { Image(systemName: "arrow.clockwise") }.help("Re-check login state")
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill((pending == nil ? Color.red : Color.orange).opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke((pending == nil ? Color.red : Color.orange).opacity(0.4)))
        .padding(.horizontal, 28).padding(.top, 14)
    }

    private var title: String {
        if model.tshPending != nil { return "Waiting for Teleport login…" }
        if !model.tsh.tshFound { return "tsh not found" }
        return "Not logged in to \(model.tsh.proxy.isEmpty ? model.config.proxy : model.tsh.proxy)"
    }

    private var subtitle: String {
        if let p = model.tshPending { return p }
        return model.tsh.message
    }
}

// MARK: - Toasts

struct ToastStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts) { t in
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.text).font(.callout)
                    if let u = t.url {
                        Button(u) { model.open(u) }.buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 12, y: 4))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10).fill(color(t.kind)).frame(width: 3).padding(.vertical, 6)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(.easeOut(duration: 0.2), value: model.toasts.count)
    }

    private func color(_ k: Toast.Kind) -> Color {
        switch k { case .info: return .blue; case .ok: return .green; case .err: return .red }
    }
}
