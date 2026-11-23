import AppKit
import SwiftUI

/// The Settings dialog: the port of index.js `openSettings()` and
/// `locateTsh()`. Everything is edited as a draft (SettingsDraft.swift) and
/// written in one `Store.updateSettings` patch on Save, with the original's
/// keys, defaults and coercions; Cancel undoes the live theme preview. The
/// dialog is in sections with a dropdown and a search (SettingsNav.swift);
/// its rows are in SettingsView.swift.
@MainActor
enum SettingsDialog {
    struct Option: Hashable {
        let value: String
        let label: String
    }

    static let accentOptions: [Option] = [
        .init(value: "blue", label: "Default (blue, or the theme\u{2019}s own)"),
        .init(value: "violet", label: "Violet"), .init(value: "teal", label: "Teal"),
        .init(value: "green", label: "Green"), .init(value: "amber", label: "Amber"),
        .init(value: "rose", label: "Rose"), .init(value: "slate", label: "Slate"),
    ]

    static var skinOptions: [Option] {
        [.init(value: "none", label: "None — plain dark or light")]
            + MiscThemes.skins.map { .init(value: $0.id, label: $0.label) }
    }

    /// connectanim.js CONNECT_ANIMS: id, name, first of the cast.
    static let connectAnims: [(id: String, name: String, glyph: String)] = [
        ("robots", "Robots shaking hands", "🤖"), ("tubes", "Pneumatic tubes", "📦"),
        ("rocket", "Rocket post", "🚀"), ("pigeon", "Carrier pigeon", "🐦"),
        ("satellite", "Satellite relay", "🛰️"), ("train", "Freight train", "🚂"),
        ("submarine", "Undersea cable", "🚢"), ("plane", "Paper plane", "✈️"),
        ("ants", "Ants with packets", "🐜"), ("laser", "Laser link", "✨"),
        ("conveyor", "Conveyor belt", "📦"), ("hamster", "Hamster-powered", "🐹"),
        ("lightning", "Lightning link", "⚡"), ("teleport", "Teleporter", "🫠"),
        ("snail", "Snail mail", "🐌"), ("balloon", "Hot air balloon", "🎈"),
        ("bucket", "Bucket brigade", "🪣"), ("zipline", "Zip line", "🧗"),
        ("morse", "Morse code", "•"), ("tincan", "Tin can telephone", "🥫"),
        ("drone", "Drone delivery", "🛸"), ("cat", "Cat chasing a packet", "🐈"),
        ("wormhole", "Wormhole", "🌀"), ("bridge", "Bridge builder", "🔨"),
        ("bees", "Busy bees", "🐝"), ("traffic", "Rush hour", "🚚"),
        ("radio", "Radio waves", "📡"), ("dolphin", "Dolphin express", "🐬"),
        ("ghost", "Friendly packet ghost", "👻"), ("scooter", "Courier scooter", "🛵"),
    ]

    static var animOptions: [Option] {
        [.init(value: "rotate", label: "Rotate through all of them"), .init(value: "off", label: "Off — just the log")]
            + connectAnims.map { .init(value: $0.id, label: $0.glyph + "  " + $0.name) }
    }

    static let recentOptions: [Option] = [
        .init(value: "0", label: "Off — do not offer recent connections"), .init(value: "5", label: "Last 5"),
        .init(value: "10", label: "Last 10"), .init(value: "20", label: "Last 20"), .init(value: "50", label: "Last 50"),
    ]
    static let refreshOptions: [Option] = [
        .init(value: "0", label: "Off — refresh only when I ask"), .init(value: "2", label: "Every 2 seconds"),
        .init(value: "5", label: "Every 5 seconds"), .init(value: "10", label: "Every 10 seconds"),
        .init(value: "30", label: "Every 30 seconds"),
    ]
    static let nodeRefreshOptions: [Option] = [
        .init(value: "0", label: "Off — only when I press Refresh"), .init(value: "10", label: "Every 10 seconds"),
        .init(value: "30", label: "Every 30 seconds"), .init(value: "60", label: "Every minute"),
        .init(value: "300", label: "Every 5 minutes"),
    ]
    static let staleOptions: [Option] = [
        .init(value: "0", label: "Off — do not warn"), .init(value: "2", label: "Quiet for 2 minutes"),
        .init(value: "5", label: "Quiet for 5 minutes"), .init(value: "10", label: "Quiet for 10 minutes"),
    ]
    static let heartbeatOptions: [Option] = [
        .init(value: "relative", label: "How long ago — <1m, 2m (default)"),
        .init(value: "exact", label: "The exact time — 14:32:05"),
    ]
    static let hostLimitOptions: [Option] = [
        .init(value: "0", label: "No limit — list every host"), .init(value: "10", label: "Stop at 10 per group"),
        .init(value: "20", label: "Stop at 20 per group"), .init(value: "30", label: "Stop at 30 per group"),
        .init(value: "50", label: "Stop at 50 per group"), .init(value: "100", label: "Stop at 100 per group"),
    ]
    static let mfaOptions: [Option] = [
        .init(value: "platform", label: "Touch ID / platform authenticator"),
        .init(value: "cross-platform", label: "Security key (YubiKey)"),
        .init(value: "otp", label: "OTP code"), .init(value: "browser", label: "Browser"),
        .init(value: "auto", label: "Automatic (tsh decides)"),
    ]
    static let x11Options: [Option] = [
        .init(value: "off", label: "Off"), .init(value: "untrusted", label: "On - untrusted (ssh -X)"),
        .init(value: "trusted", label: "On - trusted (ssh -Y)"),
    ]
    static let starredOptions: [Option] = [
        .init(value: "inline", label: "At the top of the group they belong to"),
        .init(value: "group", label: "Gathered in a Starred group above everything"),
    ]
    static let cursorOptions: [Option] = [
        .init(value: "bar", label: "Bar (line)"), .init(value: "block", label: "Block"),
        .init(value: "underline", label: "Underline"),
    ]
    static let expiredListOptions: [Option] = [
        .init(value: "off", label: "Only watched hosts"),
        .init(value: "timed", label: "The last known hosts, for a while"),
        .init(value: "always", label: "The last known hosts, always"),
    ]
    static let typingOptions: [Option] = [
        .init(value: "ask", label: "Ask me each time, showing the text (recommended)"),
        .init(value: "allow", label: "Allow without asking"),
        .init(value: "off", label: "Never"),
    ]

    /// Open Settings; `query` starts it filtered (the title bar's search
    /// opens it at the setting it found).
    static func open(_ window: WindowModel? = nil, query: String = "") {
        let draft = SettingsDraft()
        draft.query = query
        MiscAppInfo.shared.refreshTshVersion()
        let h = Modal.sheet(window, title: "Settings", width: 660, height: 760, resizable: true, autosave: "settings") { handle in
            SettingsView(d: draft, handle: handle)
        }
        h.onClose.append {
            // Undo any live preview that was not saved.
            if MiscThemes.preview != nil { MiscThemes.preview = nil; Theme.shared.refresh() }
        }
    }

    /// Apply a settings patch the way main.js `settings:set` does: write it,
    /// and apply the tool paths and tsh homes at once.
    static func apply(_ patch: [String: JSON]) {
        Store.shared.updateSettings(patch)
        if let h = patch["tshHomes"] { Tools.homes = h.stringArray }
        if let p = patch["tshPath"] { Tools.setTshPath(p.string) }
        if let p = patch["sshPath"] { Tools.setSshPath(p.string) }
        if patch["tshPath"] != nil { MiscAppInfo.shared.refreshTshVersion() }
    }

    struct ToolsResult {
        var tshPath: String
        var sshPath: String
        var tshEnvText: String
        var tshEnvInShells: Bool
    }

    /// "Locate tsh / ssh…" — the Command-line tools dialog (`locateTsh`).
    static func locateTools(_ window: WindowModel? = nil) async {
        let s = Store.shared.settings
        let start = ToolsResult(tshPath: s["tshPath"].string ?? "", sshPath: s["sshPath"].string ?? "",
                                tshEnvText: s["tshEnvText"].string ?? "", tshEnvInShells: s["tshEnvInShells"].truthy)
        let result: ToolsResult? = await withCheckedContinuation { cont in
            var done = false
            let finish: (ToolsResult?) -> Void = { v in if !done { done = true; cont.resume(returning: v) } }
            let h = Modal.sheet(window, title: "Command-line tools", width: 640) { handle in
                LocateToolsView(start: start) { v in finish(v); handle.close() }
            }
            h.onClose.append { finish(nil) }
        }
        guard let r = result else { return }
        apply(["tshPath": .string(r.tshPath), "sshPath": .string(r.sshPath),
               "tshEnvText": .string(r.tshEnvText), "tshEnvInShells": .bool(r.tshEnvInShells)])
        Actions.shared.perform("refresh", window: window)
    }

    /// x11:status for macOS: XQuartz provides the server and sets DISPLAY
    /// for its own clients.
    static func x11Status() -> (available: Bool, hint: String, display: String?) {
        let display = ProcessInfo.processInfo.environment["DISPLAY"].flatMap { $0.isEmpty ? nil : $0 }
        let installed = ["/opt/X11/bin/Xquartz", "/Applications/Utilities/XQuartz.app", "/opt/X11"]
            .contains { FileManager.default.fileExists(atPath: $0) }
        let hint = !installed
            ? "XQuartz is not installed. Install it (brew install --cask xquartz), log out and back in."
            : display == nil
                ? "XQuartz is installed but DISPLAY is not set for this app. Launch XQuartz, then restart ServerLife from a terminal so it inherits DISPLAY."
                : "XQuartz detected."
        return (display != nil && installed, hint, display)
    }

    /// Choose a binary — into `.app` bundles too: a signed tsh has to be run
    /// from inside tsh.app.
    static func browseBinary(_ what: String) async -> String? {
        let p = NSOpenPanel()
        p.title = "Choose the \(what) binary"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.treatsFilePackagesAsDirectories = true
        p.showsHiddenFiles = true
        if let parent = NSApp.keyWindow {
            let ok = await withCheckedContinuation { cont in
                p.beginSheetModal(for: parent) { cont.resume(returning: $0 == .OK) }
            }
            return ok ? p.url?.path : nil
        }
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

private struct LocateToolsView: View {
    let done: (SettingsDialog.ToolsResult?) -> Void
    @StateObject private var tsh: Local<String>
    @StateObject private var ssh: Local<String>
    @StateObject private var env: Local<String>
    @StateObject private var shells: Local<Bool>

    init(start: SettingsDialog.ToolsResult, done: @escaping (SettingsDialog.ToolsResult?) -> Void) {
        _tsh = StateObject(wrappedValue: Local(start.tshPath))
        _ssh = StateObject(wrappedValue: Local(start.sshPath))
        _env = StateObject(wrappedValue: Local(start.tshEnvText))
        _shells = StateObject(wrappedValue: Local(start.tshEnvInShells))
        self.done = done
    }

    private func report(_ st: JSON, _ label: String) -> String {
        st["found"].bool == true
            ? "Currently using: \(st["path"].string ?? "")"
            : "\(label) not found. Looked in:\n" + st["searched"].stringArray.joined(separator: "\n")
    }

    private func browse(_ into: Local<String>, _ what: String) -> some View {
        Button("Browse…") {
            Task { @MainActor in
                if let f = await SettingsDialog.browseBinary(what) { into.value = f }
            }
        }
        .buttonStyle(.ghostSmall).padding(.bottom, 6)
    }

    var body: some View {
        let tshSt = Tools.tshStatus, sshSt = Tools.sshStatus
        DialogScaffold(title: "Command-line tools", subtitle: "Where tsh and ssh are on this machine") {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Path to tsh",
                          hint: "Everything Teleport is read through this. Leave blank to search the usual locations again.") {
                    TextField(tshSt["path"].string ?? "/usr/local/bin/tsh", text: $tsh.value).textFieldStyle(.roundedBorder)
                }
                browse(tsh, "tsh")
                MiscHint(text: report(tshSt, "tsh"))
                MiscRule().padding(.top, 10)
                MiscField(label: "Environment for tsh",
                          hint: "One NAME=value per line (a pasted export NAME=value works too). Every tsh the app runs gets "
                            + "these — background reads, sessions, Phase builds and logins. A cluster\u{2019}s own (its "
                            + "heading\u{2019}s menu → tsh environment for this cluster…) go on top.") {
                    MiscEnvBox(text: $env.value, placeholder: "TELEPORT_TOOLS_VERSION=18.11.9")
                }
                MiscCheck(label: "Also in local shell tabs, so tsh typed there matches", isOn: $shells.value)
                MiscRule().padding(.top, 10)
                MiscField(label: "Path to ssh",
                          hint: "Used for plain SSH hosts and for Teleport nodes over the shared connection.") {
                    TextField(sshSt["path"].string ?? "/usr/bin/ssh", text: $ssh.value).textFieldStyle(.roundedBorder)
                }
                browse(ssh, "ssh")
                MiscHint(text: report(sshSt, "ssh"))
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") {
                if !MiscTshEnv.parse(env.value).errors.isEmpty {
                    StatusBus.shared.toast("Some tsh environment lines are not NAME=value", kind: .error)
                    return
                }
                done(.init(tshPath: tsh.value.trimmed, sshPath: ssh.value.trimmed,
                           tshEnvText: env.value.trimmed, tshEnvInShells: shells.value))
            }
            .buttonStyle(.primary)
        }
    }
}
