import AppKit
import SwiftUI

/// One thing in the Settings dialog, with the words it is found by.
private struct SRow {
    let item: SettingsNav.Item
    let view: AnyView
}

private func row<V: View>(_ label: String, _ more: [String] = [], hint: Bool = false, @ViewBuilder _ v: () -> V) -> SRow {
    SRow(item: .init(label: label, text: ([label] + more).joined(separator: " "), isHint: hint), view: AnyView(v()))
}

private func labels(_ o: [SettingsDialog.Option]) -> [String] { o.map(\.label) }

/// The dialog: sections (settingsnav.js) over the rows of `openSettings`,
/// in the original's order.
struct SettingsView: View {
    @ObservedObject var d: SettingsDraft
    let handle: ModalHandle
    @FocusState private var searchFocused: Bool

    private var window: WindowModel? { WindowManager.shared.model(for: handle.window) }

    var body: some View {
        let p = Theme.shared.p
        let org = SettingsNav.organize(buildGroups().map { $0.map(\.item) })
        let rows = buildGroups().flatMap { $0 }
        let vis = SettingsNav.visible(org.sections, org.items, query: d.query, only: d.only)
        DialogScaffold(title: "Settings", scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                // The dropdown and the search, kept in view while the rest scrolls.
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { d.only ?? -1 }, set: { d.only = $0 < 0 ? nil : $0 })) {
                        Text("All settings").tag(-1)
                        ForEach(Array(org.sections.enumerated()), id: \.offset) { i, s in Text(s.title).tag(i) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .frame(maxWidth: 280)
                    .help("Show one section")
                    SearchField(placeholder: "Search settings…", text: $d.query)
                        .focused($searchFocused)
                }
                .padding(.bottom, 8)
                p.borderSoft.frame(height: 1).padding(.horizontal, -16)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id("settings-top")
                            if vis.sections.isEmpty {
                                MiscHint(text: "No setting matches.", size: 12).padding(.vertical, 20)
                            }
                            let shown = org.sections.indices.filter { vis.sections.contains($0) }
                            ForEach(shown, id: \.self) { si in
                                VStack(alignment: .leading, spacing: 0) {
                                    if si != shown.first {
                                        p.borderSoft.frame(height: 1).padding(.top, 14).padding(.bottom, 12)
                                    }
                                    Text(org.sections[si].title.uppercased())
                                        .font(.system(size: 11, weight: .semibold))
                                        .tracking(0.66)
                                        .foregroundStyle(p.muted)
                                        .padding(.bottom, 8)
                                    ForEach(org.sections[si].items.filter { vis.items.contains($0) }, id: \.self) { i in
                                        rows[i].view
                                    }
                                }
                            }
                        }
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: d.only) { _, _ in proxy.scrollTo("settings-top", anchor: .top) }
                    .onChange(of: d.query) { _, _ in proxy.scrollTo("settings-top", anchor: .top) }
                }
            }
            .onAppear { searchFocused = true }
        } footer: {
            Button("Cancel") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") {
                d.save(window)
                handle.close()
            }
            .buttonStyle(.primary)
        }
    }

    // MARK: Groups (split where the original draws a divider)

    private func buildGroups() -> [[SRow]] {
        [homes, appearance, text, automation, recent, connecting, refreshing, mfa, x11, files, kube,
         sessions, assistants, highlight, starred, starredHosts, agent, sshConfig, editor, about]
    }

    private var homes: [SRow] {
        [
            row("Teleport homes (TELEPORT_HOME)",
                ["Every directory listed is read for clusters, and every tsh command for a cluster runs with the home it came from. Order is precedence.",
                 "Locate tsh / ssh…", "Add a directory…", "Check what they hold"] + d.tshHomes) {
                MiscField(label: "Teleport homes (TELEPORT_HOME)",
                          hint: "Every directory listed is read for clusters, and every tsh command for a cluster runs with the home it came from. Order is precedence.") {
                    HomesList(d: d, window: window)
                }
                .padding(.bottom, 10)
            },
            row("", hint: true) {
                if !d.homesNote.isEmpty { MiscHint(text: d.homesNote).padding(.top, -4).padding(.bottom, 8) }
            },
        ]
    }

    private var appearance: [SRow] {
        [
            row("Theme", ["Accent colour"] + MiscThemes.appThemes.map(\.label) + labels(SettingsDialog.accentOptions)) {
                HStack(alignment: .top, spacing: 10) {
                    MiscField(label: "Theme") { ThemePicker(selection: $d.theme) }
                    MiscField(label: "Accent colour") { OptionPicker(options: SettingsDialog.accentOptions, selection: $d.accent) }
                }
                .padding(.bottom, 10)
            },
            row("Skin", ["A skin repaints everything, terminals included, and ignores the two above."] + labels(SettingsDialog.skinOptions)) {
                MiscField(label: "Skin", hint: "A skin repaints everything, terminals included, and ignores the two above.") {
                    OptionPicker(options: SettingsDialog.skinOptions, selection: $d.skin)
                }
                .padding(.bottom, 10)
            },
            row("Terminal colours", ["The palette programs\u{2019} output is drawn in."] + MiscThemes.terminalPalettes.map(\.label)) {
                MiscField(label: "Terminal colours",
                          hint: "The palette programs\u{2019} output is drawn in. \"Follow the app theme\" keeps the old behaviour, "
                            + "including skins; a named palette wins over both.") {
                    OptionPicker(options: MiscThemes.terminalPalettes.map { .init(value: $0.value, label: $0.label) },
                                 selection: $d.terminalPalette)
                }
                .padding(.bottom, 10)
            },
        ]
    }

    private var text: [SRow] {
        [
            row("Terminal font size", ["Host list text size", "Scrollback lines"]) {
                HStack(alignment: .top, spacing: 10) {
                    MiscField(label: "Terminal font size") { NumberField(text: $d.fontSize) }
                    MiscField(label: "Host list text size") { NumberField(text: $d.sidebarFontSize) }
                    MiscField(label: "Scrollback lines") { NumberField(text: $d.scrollback) }
                }
                .padding(.bottom, 10)
            },
            row("", ["\u{2318} + and \u{2212} change the pane you are in"], hint: true) {
                MiscHint(text: "\u{2318} + and \u{2212} change the pane you are in, or the host list when that is where you "
                         + "clicked last; 0 puts it back.")
                    .padding(.top, -4).padding(.bottom, 10)
            },
            row("Font family", [d.fontValue]) {
                MiscField(label: "Font family") { FontPicker(d: d) }.padding(.bottom, 10)
            },
        ]
    }

    private var automation: [SRow] {
        [row("Local automation", ["MCP", "Assistants typing into sessions", "token", "socket"]) {
            MiscField(label: "Local automation") { AutomationBox(d: d) }.padding(.bottom, 10)
        }]
    }

    private var recent: [SRow] {
        [row("Remember recent connections", ["Offered at the top of New session"] + labels(SettingsDialog.recentOptions)) {
            MiscField(label: "Remember recent connections",
                      hint: "Offered at the top of New session, newest first, one row per destination. The full session history (⌘Y) is kept either way.") {
                OptionPicker(options: SettingsDialog.recentOptions, selection: $d.recentLimit)
            }
            .padding(.bottom, 10)
        }]
    }

    private var connecting: [SRow] {
        [row("While a session connects", ["A small scene plays over the connection log.", "animation"] + labels(SettingsDialog.animOptions)) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "While a session connects",
                          hint: "A small scene plays over the connection log. Thirty of them, rotating.") {
                    OptionPicker(options: SettingsDialog.animOptions, selection: $d.connectAnim)
                }
                .padding(.bottom, 10)
                if let a = d.previewAnim, let make = MiscHooks.connectAnimPreview {
                    make(a).frame(maxWidth: .infinity).padding(.bottom, 10)
                }
            }
        }]
    }

    private var refreshing: [SRow] {
        [
            row("Refresh the file list", ["Also how often the browser follows the terminal\u{2019}s directory."] + labels(SettingsDialog.refreshOptions)) {
                MiscField(label: "Refresh the file list",
                          hint: "Also how often the browser follows the terminal\u{2019}s directory. Each tick is one SFTP round trip per visible pane.") {
                    OptionPicker(options: SettingsDialog.refreshOptions, selection: $d.refreshSeconds)
                }
                .padding(.bottom, 10)
            },
            row("Refresh the Teleport clusters", ["Whether each certificate is still valid, and one `tsh ls` per live cluster."]
                + labels(SettingsDialog.nodeRefreshOptions)) {
                MiscField(label: "Refresh the Teleport clusters",
                          hint: "Whether each certificate is still valid, and one `tsh ls` per live cluster. "
                            + "Paused while the window is hidden, and only redrawn when a node, an address, "
                            + "a label or a cluster’s expiry has actually changed.") {
                    OptionPicker(options: SettingsDialog.nodeRefreshOptions, selection: $d.nodeRefreshSeconds)
                }
                .padding(.bottom, 10)
            },
            row("Hosts listed per group in the sidebar", ["Past this many the list stops"] + labels(SettingsDialog.hostLimitOptions)) {
                MiscField(label: "Hosts listed per group in the sidebar",
                          hint: "Past this many the list stops and says how many it is holding back — and that row "
                            + "opens the same hosts in a pane, which has the room for them. A filter is exempt: "
                            + "you asked a specific question, so you get the whole answer.") {
                    OptionPicker(options: SettingsDialog.hostLimitOptions, selection: $d.sidebarHostLimit)
                }
                .padding(.bottom, 10)
            },
            row("Heartbeat times", ["How a heartbeat reads on a row"] + labels(SettingsDialog.heartbeatOptions)) {
                MiscField(label: "Heartbeat times",
                          hint: "How a heartbeat reads on a row, SSH and Kubernetes alike — how long ago, or the clock time it was heard. The tooltip always has the exact time.") {
                    OptionPicker(options: SettingsDialog.heartbeatOptions, selection: $d.heartbeatStyle)
                }
                .padding(.bottom, 10)
            },
            row("Warn about nodes that have gone quiet", ["heartbeating"] + labels(SettingsDialog.staleOptions)) {
                MiscField(label: "Warn about nodes that have gone quiet",
                          hint: "A node stays in the inventory for ten or fifteen minutes after its agent stops "
                            + "heartbeating, offering to connect the whole time. Past this much silence its row "
                            + "is marked, and the tooltip says how long it has left before the cluster drops it.") {
                    OptionPicker(options: SettingsDialog.staleOptions, selection: $d.staleNodeMinutes)
                }
                .padding(.bottom, 10)
            },
        ]
    }

    private var mfa: [SRow] {
        [row("MFA method for per-session-MFA nodes", labels(SettingsDialog.mfaOptions)) {
            MiscField(label: "MFA method for per-session-MFA nodes",
                      hint: "Automatic can pick a method that fails in a spawned process and consumes the challenge; naming one avoids that.") {
                OptionPicker(options: SettingsDialog.mfaOptions, selection: $d.mfaMode)
            }
            .padding(.bottom, 10)
        }]
    }

    private var x11: [SRow] {
        let p = Theme.shared.p
        let x = SettingsDialog.x11Status()
        return [
            row("X11 forwarding (default for new sessions)", labels(SettingsDialog.x11Options)) {
                MiscField(label: "X11 forwarding (default for new sessions)") {
                    OptionPicker(options: SettingsDialog.x11Options, selection: $d.x11)
                }
                .padding(.bottom, 10)
            },
            row("", hint: true) {
                MiscHint(text: x.available ? "X server detected (DISPLAY=\(x.display ?? ""))." : x.hint,
                         color: x.available ? p.muted : p.amber)
                    .padding(.top, -6).padding(.bottom, 4)
            },
        ]
    }

    private var files: [SRow] {
        [
            row("Follow the terminal’s working directory in the file browser") {
                MiscCheck(label: "Follow the terminal’s working directory in the file browser", isOn: $d.follow)
            },
            row("Show hidden files") { MiscCheck(label: "Show hidden files", isOn: $d.hidden) },
            row("Show permissions and owner in file lists") {
                MiscCheck(label: "Show permissions and owner in file lists", isOn: $d.details)
            },
            row("Folders before files in file lists") { MiscCheck(label: "Folders before files in file lists", isOn: $d.foldersFirst) },
            row("3D view button in the file browser") { MiscCheck(label: "3D view button in the file browser", isOn: $d.show3d) },
            row("Blinking cursor") { MiscCheck(label: "Blinking cursor", isOn: $d.blink) },
        ]
    }

    private var kube: [SRow] {
        let note = "Kubernetes clusters in the Resources tab beside your SSH hosts (filterable to All/SSH/K8s), the "
            + "default kubeconfig read automatically, Teleport-registered clusters, exec sessions with a file "
            + "browser, a 3D cluster view, and Kubernetes clusters as a kind in access requests. Off leaves no "
            + "trace of any of it — a pure-SSH setup, exactly as before KubeLife existed."
        return [
            row("KubeLife") {
                Text("KubeLife").font(.system(size: 12, weight: .semibold)).padding(.top, 2).padding(.bottom, 6)
            },
            row("Enable Kubernetes support (KubeLife)", [note]) {
                MiscCheck(label: "Enable Kubernetes support (KubeLife)", isOn: $d.kubeEnabled, note: note)
            },
        ]
    }

    private var sessions: [SRow] {
        let quiet = "Turns off live stats, following the shell\u{2019}s folder, the file browser\u{2019}s free space and "
            + "its re-listing every few seconds on remote hosts. Refresh still works when you ask; local folders are unaffected."
        let detect = "A badge on a connected, non-Teleport SSH host’s row when it already runs a Teleport agent. "
            + "Off skips the probe entirely — nothing is checked or shown."
        let tabs = "Three bars ripple beside the tab while output is arriving, and the tab turns amber "
            + "when the session is waiting on something — a password, a yes/no, or a coding agent "
            + "asking permission. Never on the tab you are looking at: you can already see it."
        let link = "The question shows the whole address and names the host it would open, so a link "
            + "that reads one way and goes another is visible before the browser starts. "
            + "Right-click a link for Open link and Copy link — copying works even when the "
            + "URL wrapped over several rows."
        let quit = "Servers, consoles, VNC and tmux count, across every window; local shells do not. "
            + "The question lists what would be disconnected."
        let login = "Opening a host on a cluster that has logged out or expired means logging back in "
            + "first — a browser tab, a terminal, a Touch ID prompt. On by default, since that "
            + "can be more than a click to undo; the \"Do not ask again\" box on the prompt itself "
            + "turns this off the same as unchecking it here."
        let ffm = "Hovering a pane or the AI panel focuses it — no click needed first. Off by default: a stray pass of the mouse stealing keystrokes meant for somewhere else is worse than the extra click."
        func check(_ label: String, _ b: Binding<Bool>, _ note: String? = nil) -> SRow {
            row(label, note.map { [$0] } ?? []) { MiscCheck(label: label, isOn: b, note: note) }
        }
        return [
            row("Cursor style", labels(SettingsDialog.cursorOptions)) {
                MiscField(label: "Cursor style") { OptionPicker(options: SettingsDialog.cursorOptions, selection: $d.cursorStyle) }
                    .padding(.bottom, 10)
            },
            check("Name the shell in a local tab\u{2019}s title", $d.shellTitle),
            check("Server icon on SSH hosts, beside the ☸ on Kubernetes clusters", $d.serverIcon),
            check("Network and certificate tools icon on every session header", $d.netIcon),
            row("Live stats under each server session (CPU, memory, disk, network)") {
                MiscCheck(label: "Live stats under each server session (CPU, memory, disk, network)", isOn: $d.liveStats)
                    .disabled(d.quiet).opacity(d.quiet ? 0.5 : 1)
            },
            row("Live stats under local shells too, for this computer") {
                MiscCheck(label: "Live stats under local shells too, for this computer", isOn: $d.localStats).padding(.leading, 22)
            },
            row("One live stats bar per machine in a tab — split panes on the same host share it") {
                MiscCheck(label: "One live stats bar per machine in a tab — split panes on the same host share it",
                          isOn: $d.onePerTab).padding(.leading, 22)
            },
            check("No background commands on servers — keeps the Teleport audit log to what you do", $d.quiet, quiet),
            check("Detect an already-running Teleport agent on direct SSH hosts", $d.detectTeleport, detect),
            check("Show what each tab is doing (output, and waiting for an answer)", $d.tabActivity, tabs),
            check("Ask before opening a link clicked in a terminal", $d.linkAsk, link),
            check("Ask before quitting with remote sessions open", $d.quitAsk, quit),
            check("Ask before closing a tab or pane with a live session", $d.closeAsk),
            check("Ask before logging back in to connect", $d.loginAsk, login),
            check("Pane close animations", $d.paneCloseAnim),
            check("Focus follows the mouse, into panes and the AI panel", $d.focusFollowsMouse, ffm),
        ]
    }

    private var assistants: [SRow] {
        let tmux = "What runs inside tmux keeps running when the window goes away — a dropped "
            + "connection, a closed laptop, a restarted app — and reattaching brings back the "
            + "scrollback with it. The host needs tmux installed; nothing is needed here. "
            + "Individual hosts and clusters can say otherwise from their own menu."
        let req = "Off by default: the pane floats above the app, and it has nothing urgent to say most "
            + "mornings. The monitoring itself runs either way, and the count appears on the Teleport "
            + "tab and on a cluster\u{2019}s heading — Teleport \u{2192} Monitor Requestable Resources\u{2026} opens it."
        return [
            row("AI assistant to open when ServerLife starts", ["Opens in the panel on the right."] + labels(d.aiStartOptions)) {
                MiscField(label: "AI assistant to open when ServerLife starts",
                          hint: "Opens in the panel on the right. Any assistant can be opened from the + menu or the ✦ button.") {
                    OptionPicker(options: d.aiStartOptions, selection: $d.aiStartup)
                }
                .padding(.bottom, 10)
            },
            row("Folder assistants start in", ["Trusted once and remembered"]) {
                MiscField(label: "Folder assistants start in",
                          hint: "Trusted once and remembered — Claude asks about a home folder every time. Empty means ~/ServerLife AI.") {
                    TextField("~/ServerLife AI", text: $d.aiWorkdir).textFieldStyle(.roundedBorder)
                }
                .padding(.bottom, 10)
            },
            row("Esc, ↑, ↓ and Enter buttons under the assistant") {
                MiscCheck(label: "Esc, ↑, ↓ and Enter buttons under the assistant", isOn: $d.aiKeys)
            },
            row("Default launcher, for tools set to use it", ["{client}", "{command}"]) {
                VStack(alignment: .leading, spacing: 0) {
                    MiscCheck(label: "Default launcher, for tools set to use it", isOn: $d.launcherOn).padding(.bottom, -5)
                    TextField("mytool {client}   or   mytool exec -- {command}", text: $d.launcherTemplate)
                        .textFieldStyle(.roundedBorder).padding(.leading, 22).padding(.top, 4)
                    MiscHint(text: "{client} becomes the assistant’s name (claude, codex, …) followed by its arguments; {command} its whole command line; with neither, the command goes after the launcher.")
                        .padding(.leading, 22).padding(.top, 2).padding(.bottom, 9)
                }
            },
            row("Open every new session in tmux", [tmux, "tmux session name"]) {
                VStack(alignment: .leading, spacing: 0) {
                    MiscCheck(label: "Open every new session in tmux", isOn: $d.tmuxDefault, note: tmux)
                    MiscField(label: "tmux session name") {
                        TextField("serverlife", text: $d.tmuxName).textFieldStyle(.roundedBorder)
                    }
                    .frame(maxWidth: 280).padding(.leading, 22).padding(.top, -3).padding(.bottom, 10)
                }
            },
            row("Open the requestable-resource monitor when the app starts", [req]) {
                MiscCheck(label: "Open the requestable-resource monitor when the app starts", isOn: $d.reqPane, note: req)
            },
            row("Bell on hosts watched for disappearance") { WatchRow(d: d) },
            row("When a cluster logs out or expires, show", ["Hours to keep showing them"] + labels(SettingsDialog.expiredListOptions)) {
                VStack(alignment: .leading, spacing: 0) {
                    MiscField(label: "When a cluster logs out or expires, show",
                              hint: "Beyond the hosts you watched, which this still shows either way — a lapsed certificate "
                                + "says nothing about whether the rest of the cluster is still there.") {
                        OptionPicker(options: SettingsDialog.expiredListOptions, selection: $d.expiredListMode)
                    }
                    .padding(.bottom, 10)
                    if d.expiredListMode == "timed" {
                        MiscField(label: "Hours to keep showing them") {
                            TextField("", text: $d.expiredListHours).textFieldStyle(.roundedBorder).frame(width: 60)
                        }
                        .padding(.bottom, 10)
                    }
                }
            },
        ]
    }

    private var highlight: [SRow] {
        let hint = "Off unless you ask for it: colour in a terminal belongs to the program. Switched on, the "
            + "built-in rules cover errors, warnings and good news; more can be added here or for one "
            + "host, and each session has its own toggle beside its search box."
        return [row("Highlight keywords in terminal output", ["Edit the highlights…", hint]) {
            VStack(alignment: .leading, spacing: 0) {
                MiscCheck(label: "Highlight keywords in terminal output", isOn: $d.highlight)
                Button("Edit the highlights…") { Actions.shared.perform("highlights") }
                    .buttonStyle(.ghostSmall).padding(.top, -2)
                MiscHint(text: hint).padding(.top, 6)
            }
        }]
    }

    private var starred: [SRow] {
        [
            row("Automatically starred here", ["One folder per line, `~` for your home directory."]) {
                MiscField(label: "Automatically starred here",
                          hint: "One folder per line, `~` for your home directory. They appear in the starred list of every "
                            + "local file pane. Anything that is not there is skipped, and any one of them can be hidden "
                            + "from its own menu.") {
                    MiscTextArea(text: $d.autoLocal, rows: 4, placeholder: "~\n~/Documents")
                }
                .padding(.bottom, 10)
            },
            row("Automatically starred on servers", ["The same for a server."]) {
                MiscField(label: "Automatically starred on servers",
                          hint: "The same for a server. A `~/name` entry only appears on hosts that actually have that "
                            + "folder — checked once per connection — so a cloud instance is not offered a Desktop.") {
                    MiscTextArea(text: $d.autoHost, rows: 5, placeholder: "~\n/var/log")
                }
                .padding(.bottom, 10)
            },
        ]
    }

    private var starredHosts: [SRow] {
        [row("Starred hosts", ["A star keeps a host where you can find it."] + labels(SettingsDialog.starredOptions)) {
            MiscField(label: "Starred hosts",
                      hint: "A star keeps a host where you can find it. Either it sorts to the top of its own cluster, "
                        + "or every starred host is gathered into one group. Hosts can also be dragged into the "
                        + "order you want within a group.") {
                OptionPicker(options: SettingsDialog.starredOptions, selection: $d.starredMode)
            }
            .padding(.bottom, 10)
        }]
    }

    private var agent: [SRow] {
        let hint = "Agent forwarding lets processes on the far host use the keys in your agent while the session "
            + "is open \u{2014} what a jump host needs, and what a shared box should not have. A cluster or a "
            + "single host can override this from its menu in the host list."
        return [row("Forward the ssh agent by default (-A)", [hint]) {
            VStack(alignment: .leading, spacing: 0) {
                MiscCheck(label: "Forward the ssh agent by default (-A)", isOn: $d.agent)
                MiscHint(text: hint).padding(.top, -3)
            }
        }]
    }

    private var sshConfig: [SRow] {
        let hint = "Read hosts from more than one OpenSSH config file. Each extra file gets its own group in the "
            + "host list, and its hosts are opened with ssh -F so that file\u{2019}s own settings apply."
        return [row("SSH config files…", [hint]) {
            VStack(alignment: .leading, spacing: 0) {
                Button("SSH config files…") { Actions.shared.perform("ssh-config-files", window: window) }.buttonStyle(.ghostSmall)
                MiscHint(text: hint).padding(.top, 6)
            }
        }]
    }

    private var editor: [SRow] {
        [row("Editor for remote files", ["code -w, subl -w, mate"]) {
            MiscField(label: "Editor for remote files",
                      hint: "Left blank, a remote file opens in whatever this machine opens that file type with. "
                        + "Name a command — code -w, subl -w, mate — to use one editor for all of them. "
                        + "Every save goes back to the server until you stop the edit.") {
                TextField("code -w", text: $d.editor).textFieldStyle(.roundedBorder)
            }
            .padding(.bottom, 10)
        }]
    }

    private var about: [SRow] {
        let tsh = Tools.tshStatus
        let path = (tsh["found"].bool == true ? tsh["path"].string : nil) ?? "not found"
        let ver = MiscAppInfo.shared.tshVersion.map { " (v\($0))" } ?? ""
        let line = "tsh: \(path)\(ver)"
        return [row(line) { MiscHint(text: line) }]
    }
}

// MARK: - Pieces

/// Theme, with the named themes grouped by tone.
private struct ThemePicker: View {
    @Binding var selection: String
    var body: some View {
        Picker("", selection: $selection) {
            Text("Automatic (follow system)").tag("auto")
            Text("Dark").tag("dark")
            Text("Light").tag("light")
            Section("Dark themes") {
                ForEach(MiscThemes.appThemes.filter { $0.tone == "dark" }, id: \.id) { Text($0.label).tag($0.id) }
            }
            Section("Light themes") {
                ForEach(MiscThemes.appThemes.filter { $0.tone == "light" }, id: \.id) { Text($0.label).tag($0.id) }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }
}

/// ui.js `select(options, value)`.
struct OptionPicker: View {
    let options: [SettingsDialog.Option]
    @Binding var selection: String
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }
}

private struct NumberField: View {
    @Binding var text: String
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
    }
}

/// The font as a list of what is installed, then the bundled fonts; "Other…"
/// keeps a box for a family the list does not know, or a whole stack.
private struct FontPicker: View {
    @ObservedObject var d: SettingsDraft
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $d.fontPick) {
                Text("Default (the system\u{2019}s monospace)").tag("")
                ForEach(MiscFonts.choices(), id: \.group) { g in
                    Section(g.group) { ForEach(g.fonts, id: \.self) { Text($0).tag($0) } }
                }
                Text("Other\u{2026}").tag("__other")
            }
            .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity)
            if d.fontPick == "__other" {
                TextField("A family name, or a stack: \"My Font\", monospace", text: $d.fontOther)
                    .textFieldStyle(.roundedBorder)
            }
            Text("ubuntu@web-1:~$ ls -la /var/log  0O 1lI {}[] => != ->")
                .font(Font(MiscFonts.font(d.fontValue, size: 13)))
                .foregroundStyle(p.text)
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
                .clipped()
        }
    }
}

private struct WatchRow: View {
    @ObservedObject var d: SettingsDraft
    var body: some View {
        let n = d.watchCount
        let gone = d.watchMissing
        VStack(alignment: .leading, spacing: 0) {
            MiscCheck(label: "Bell on hosts watched for disappearance", isOn: $d.watchMark,
                      note: n > 0
                        ? "\(n) host\(n == 1 ? "" : "s") watched\(gone > 0 ? ", \(gone) currently missing" : "")."
                        : "Nothing is being watched yet — the mark is on a host’s right-click menu.")
            if n > 0 {
                Button("Stop watching all \(n)") {
                    Task { @MainActor in
                        let go = await MiscUI.confirm(title: "Stop watching \(n) host\(n == 1 ? "" : "s")?",
                                                      message: "The records kept of them go too.",
                                                      detail: "Any that are currently shown as gone disappear from the list with them.",
                                                      confirmLabel: "Stop watching")
                        if go {
                            SettingsDialog.apply(["watchedHosts": .object([:])])
                            d.objectWillChange.send()
                        }
                    }
                }
                .buttonStyle(.ghostSmall)
                .padding(.leading, 22).padding(.top, -3).padding(.bottom, 8)
            }
        }
    }
}

private struct AutomationBox: View {
    @ObservedObject var d: SettingsDraft
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            if d.control == nil {
                MiscHint(text: "Reading…", size: 11.5)
            } else if d.control?.isNull == true {
                MiscHint(text: "Local automation is not available in this build.", color: p.textDim, size: 11.5)
            } else if let c = d.control {
                Toggle(isOn: Binding(get: { c["enabled"].truthy }, set: { d.setControl($0) })) {
                    Text("Allow local automation (MCP)").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                // Whether an assistant may type into a session — the one thing
                // here that can run anything. Asked each time unless told otherwise.
                MiscField(label: "Assistants typing into sessions",
                          hint: "Lets an assistant paste a command into a terminal and, if you agree, run it.") {
                    OptionPicker(options: SettingsDialog.typingOptions,
                                 selection: Binding(get: { d.automationTyping }, set: { d.setTyping($0) }))
                }
                .padding(.top, 8)
                MiscHint(text: "A program on this machine can then list hosts, open sessions, load layouts and run your saved macros. "
                         + "It cannot run arbitrary commands. Every call is shown in the status bar.",
                         color: p.textDim, size: 11.5)
                    .padding(.top, 6)
                if c["enabled"].truthy {
                    codeBox(Text("socket  ").foregroundColor(p.textDim) + Text(c["socketPath"].string ?? "")
                            + Text("\n") + Text("token   ").foregroundColor(p.textDim) + Text(c["tokenFile"].string ?? ""))
                    HStack(spacing: 6) {
                        Button("Copy claude mcp add") { d.copy("mcp") }.buttonStyle(.ghostSmall)
                            .help("Register this app with Claude Code")
                        Button("Copy bridge path") { d.copy("bridge") }.buttonStyle(.ghostSmall)
                        Button("New token") { d.rotateToken() }
                            .buttonStyle(GhostButtonStyle(small: true, destructive: true))
                            .help("Anything currently authorised loses access")
                    }
                    .padding(.top, 8)
                    codeBox(Text(c["mcpCommand"].string ?? ""))
                }
            }
        }
    }

    private func codeBox(_ t: Text) -> some View {
        let p = Theme.shared.p
        return t.font(.system(size: 11.5, design: .monospaced))
            .foregroundColor(p.text)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            .padding(.top, 8)
    }
}

private struct HomesList: View {
    @ObservedObject var d: SettingsDraft
    let window: WindowModel?
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 4) {
            if d.tshHomes.isEmpty {
                MiscHint(text: "Just the default — \(d.defaultHome). Add a directory to read more than one.")
                    .padding(.vertical, 2)
            }
            ForEach(Array(d.tshHomes.enumerated()), id: \.offset) { i, home in
                let n = MiscTshEnv.countVars(d.tshHomeEnv[home])
                HStack(spacing: 4) {
                    Text(home).font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                        .help(home)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(n > 0 ? "\(n) var\(n == 1 ? "" : "s")" : "vars") { Task { await d.changeHome(i, window) } }
                        .buttonStyle(.ghostSmall)
                        .help("Change the path or the variables tsh runs with for this home")
                    Button("▲") { d.moveHome(i, by: -1) }.buttonStyle(.icon).disabled(i == 0)
                        .help("Earlier — owns a cluster both homes hold")
                    Button("▼") { d.moveHome(i, by: 1) }.buttonStyle(.icon).disabled(i == d.tshHomes.count - 1)
                        .help("Later")
                    Button("×") { d.tshHomes.remove(at: i) }.buttonStyle(.icon).help("Remove")
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.borderSoft))
            }
            HStack(spacing: 6) {
                Button("Add a directory…") { Task { await d.addHome(window) } }.buttonStyle(.ghostSmall)
                Button("Add the default (~/.tsh)") { d.addDefaultHome() }.buttonStyle(.ghostSmall)
                    .help("Name the default explicitly, so its place in the order is yours to set")
                Button("Locate tsh / ssh…") { Task { await SettingsDialog.locateTools(window) } }.buttonStyle(.ghostSmall)
                    .help("Point the app at the tsh and ssh binaries, if they are somewhere unusual")
                Button("Check what they hold") { Task { await d.checkHomes() } }.buttonStyle(.ghostSmall)
            }
            .padding(.top, 4)
        }
    }
}
