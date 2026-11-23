import AppKit
import SwiftUI

/// Everything the Settings dialog edits, read from settings with the
/// original's defaults (index.js `openSettings`).
@MainActor
final class SettingsDraft: ObservableObject {
    @Published var theme: String { didSet { preview() } }
    @Published var accent: String { didSet { preview() } }
    @Published var skin: String { didSet { preview() } }
    @Published var terminalPalette: String
    @Published var fontSize: String
    @Published var sidebarFontSize: String
    @Published var scrollback: String
    /// The font list's choice: "" for the default, a family, or "__other".
    @Published var fontPick: String
    @Published var fontOther: String
    @Published var follow: Bool
    @Published var hidden: Bool
    @Published var details: Bool
    @Published var foldersFirst: Bool
    @Published var show3d: Bool
    @Published var kubeEnabled: Bool
    @Published var editor: String
    @Published var blink: Bool
    @Published var cursorStyle: String
    @Published var highlight: Bool
    @Published var shellTitle: Bool
    @Published var serverIcon: Bool
    @Published var netIcon: Bool
    @Published var liveStats: Bool
    @Published var localStats: Bool
    @Published var onePerTab: Bool
    @Published var quiet: Bool
    @Published var detectTeleport: Bool
    @Published var tabActivity: Bool
    @Published var linkAsk: Bool
    @Published var closeAsk: Bool
    @Published var loginAsk: Bool
    @Published var paneCloseAnim: Bool
    @Published var focusFollowsMouse: Bool
    @Published var quitAsk: Bool
    @Published var aiStartup: String
    @Published var aiWorkdir: String
    @Published var aiKeys: Bool
    @Published var launcherOn: Bool
    @Published var launcherTemplate: String
    /// The assistants installed (ai.js `aiClients({fresh})`), once the AI
    /// owner answers `ai-clients`; nil while unknown.
    @Published var aiClients: [SettingsDialog.Option]?
    @Published var tmuxDefault: Bool
    @Published var tmuxName: String
    @Published var reqPane: Bool
    @Published var watchMark: Bool
    @Published var expiredListMode: String
    @Published var expiredListHours: String
    @Published var agent: Bool
    @Published var autoLocal: String
    @Published var autoHost: String
    @Published var starredMode: String
    @Published var connectAnim: String { didSet { pickPreviewAnim() } }
    @Published var recentLimit: String
    @Published var refreshSeconds: String
    @Published var nodeRefreshSeconds: String
    @Published var staleNodeMinutes: String
    @Published var heartbeatStyle: String
    @Published var sidebarHostLimit: String
    @Published var mfaMode: String
    @Published var x11: String
    @Published var tshHomes: [String]
    /// Variables each home's tsh runs with, keyed by the home as written (teleport.js tshEnv).
    @Published var tshHomeEnv: [String: String]
    @Published var homesNote = ""
    @Published var automationTyping: String
    /// The automation status (`control:status`): nil while reading, `.null`
    /// when no automation is registered in this build.
    @Published var control: JSON?
    @Published var previewAnim: String?
    // The section dropdown and the search (settingsnav.js).
    @Published var query = ""
    @Published var only: Int?
    let fontSizeBefore: Double
    let savedLauncher: JSON
    let before: JSON

    init() {
        let s = Store.shared.settings
        before = s
        func num(_ k: String, _ d: Double) -> Double { let v = s[k].double ?? 0; return v == 0 || v.isNaN ? d : v }
        func nn(_ k: String, _ d: Int) -> String { s[k].isNull ? String(d) : (s[k].stringish ?? String(d)) }
        func notFalse(_ k: String) -> Bool { s[k].bool != false }
        func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        func pick(_ v: String, _ opts: [SettingsDialog.Option]) -> String {
            opts.contains { $0.value == v } ? v : (opts.first?.value ?? v)
        }
        theme = s["theme"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "dark"
        accent = pick(s["accent"].string ?? "blue", SettingsDialog.accentOptions)
        skin = pick(s["skin"].string ?? "none", SettingsDialog.skinOptions)
        terminalPalette = s["terminalPalette"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "app"
        fontSizeBefore = num("fontSize", 13)
        fontSize = fmt(num("fontSize", 13))
        sidebarFontSize = fmt(num("sidebarFontSize", 13))
        scrollback = fmt(num("scrollback", 10000))
        // The font as a list of what is installed; "Other…" keeps the box, for
        // a font the list does not know or a whole stack; a saved value that
        // is neither is shown there.
        let savedFont = (s["fontFamily"].string ?? "").trimmed
        let listed = MiscFonts.choices().flatMap(\.fonts)
        fontPick = savedFont.isEmpty ? "" : (listed.contains(savedFont) ? savedFont : "__other")
        fontOther = listed.contains(savedFont) ? "" : savedFont
        follow = notFalse("followTerminalFolder")
        hidden = s["showHiddenFiles"].truthy
        details = s["showFileDetails"].truthy
        foldersFirst = notFalse("foldersFirst")
        show3d = notFalse("show3dView")
        kubeEnabled = notFalse("kubeEnabled")
        editor = s["externalEditor"].string ?? ""
        blink = notFalse("cursorBlink")
        cursorStyle = pick(s["cursorStyle"].string ?? "bar", SettingsDialog.cursorOptions)
        highlight = s["highlight"].bool == true
        shellTitle = s["showShellInTitle"].truthy
        serverIcon = notFalse("showServerIcon")
        netIcon = notFalse("showPaneNetIcon")
        liveStats = notFalse("liveStats")
        localStats = notFalse("localStats")
        onePerTab = s["statsOncePerTab"].bool == true
        quiet = s["quietRemote"].bool == true
        detectTeleport = notFalse("detectTeleportOnSsh")
        tabActivity = notFalse("showTabActivity")
        linkAsk = notFalse("confirmLinkOpen")
        closeAsk = notFalse("confirmCloseWithSessions")
        loginAsk = notFalse("confirmLoginToConnect")
        paneCloseAnim = notFalse("paneCloseAnimations")
        focusFollowsMouse = s["focusFollowsMouse"].truthy
        quitAsk = notFalse("confirmQuitWithSessions")
        aiStartup = s["aiStartup"].string ?? ""
        aiWorkdir = s["aiWorkdir"].string ?? ""
        aiKeys = notFalse("aiKeys")
        savedLauncher = s["aiLauncher"]
        launcherOn = s["aiLauncher"]["on"].truthy
        launcherTemplate = s["aiLauncher"]["template"].string ?? ""
        tmuxDefault = s["tmuxDefault"].bool == true
        tmuxName = s["tmuxSessionName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "serverlife"
        reqPane = s["requestMonitorAutoOpen"].bool == true
        watchMark = notFalse("showWatchMark")
        expiredListMode = pick(s["expiredListMode"].string ?? "off", SettingsDialog.expiredListOptions)
        expiredListHours = fmt(num("expiredListHours", 1))
        agent = s["agentForward"].truthy
        autoLocal = s["autoFlagLocal"].stringArray.joined(separator: "\n")
        autoHost = s["autoFlagHost"].stringArray.joined(separator: "\n")
        starredMode = s["starredMode"].string == "group" ? "group" : "inline"
        connectAnim = pick(s["connectAnim"].string ?? "rotate", SettingsDialog.animOptions)
        recentLimit = pick(nn("recentLimit", 20), SettingsDialog.recentOptions)
        refreshSeconds = pick(nn("refreshSeconds", 5), SettingsDialog.refreshOptions)
        nodeRefreshSeconds = pick(nn("nodeRefreshSeconds", 10), SettingsDialog.nodeRefreshOptions)
        staleNodeMinutes = pick(nn("staleNodeMinutes", 2), SettingsDialog.staleOptions)
        heartbeatStyle = s["heartbeatStyle"].string == "exact" ? "exact" : "relative"
        sidebarHostLimit = pick(nn("sidebarHostLimit", 20), SettingsDialog.hostLimitOptions)
        mfaMode = pick(s["mfaMode"].string ?? "platform", SettingsDialog.mfaOptions)
        x11 = pick(s["x11"].string ?? "off", SettingsDialog.x11Options)
        tshHomes = s["tshHomes"].stringArray
        tshHomeEnv = s["tshHomeEnv"].entries.compactMapValues { $0.string }
        automationTyping = pick(s["automationTyping"].string ?? "ask", SettingsDialog.typingOptions)
        pickPreviewAnim()
        readControl()
        readAiClients()
    }

    private func preview() {
        MiscThemes.preview = (theme, accent, skin)
        Theme.shared.refresh()
    }

    func pickPreviewAnim() {
        switch connectAnim {
        case "off": previewAnim = nil
        case "rotate": previewAnim = SettingsDialog.connectAnims.randomElement()?.id
        default: previewAnim = connectAnim
        }
    }

    /// What the font setting will be.
    var fontValue: String { fontPick == "__other" ? fontOther.trimmed : fontPick }

    // MARK: AI (owned by ai; reached through `ai-clients`)

    func readAiClients() {
        guard Actions.shared.isRegistered("ai-clients") else { return }
        let reply: (Any?) -> Void = { v in
            let list: [JSON] = (v as? JSON)?.items ?? (v as? [JSON]) ?? []
            let clients = list.filter { $0["available"].truthy }
                .compactMap { c -> SettingsDialog.Option? in
                    guard let id = c["id"].string, !id.isEmpty else { return nil }
                    return .init(value: id, label: c["name"].string ?? id)
                }
            MainActor.assumeIsolated { self.aiClients = clients }
        }
        Actions.shared.perform("ai-clients", args: ["fresh": true, "reply": reply])
    }

    /// "None" and the assistants installed. While the AI owner has not said
    /// (a build without it), a saved choice is kept rather than lost.
    var aiStartOptions: [SettingsDialog.Option] {
        var o = [SettingsDialog.Option(value: "", label: "None")]
        if let c = aiClients {
            o += c
        } else if !aiStartup.isEmpty {
            o.append(.init(value: aiStartup, label: aiStartup))
        }
        return o
    }

    // MARK: Automation (owned by automation; reached through actions)

    func readControl() {
        guard Actions.shared.isRegistered("automation-status") else { control = .null; return }
        control = nil
        Actions.shared.perform("automation-status", args: ["reply": { (j: JSON) in
            MainActor.assumeIsolated { self.control = j }
        } as (JSON) -> Void])
    }

    func setControl(_ on: Bool) {
        guard Actions.shared.isRegistered("automation-toggle") else {
            StatusBus.shared.toast("Local automation is not available in this build", kind: .error); return
        }
        Actions.shared.perform("automation-toggle", args: ["enabled": on, "reply": { (j: JSON) in
            MainActor.assumeIsolated {
                if let e = j["error"].string { StatusBus.shared.toast(e, kind: .error); return }
                var c = self.control ?? .object([:])
                c.merge(j)
                self.control = c
            }
        } as (JSON) -> Void])
    }

    func rotateToken() {
        guard Actions.shared.isRegistered("automation-rotate") else {
            StatusBus.shared.toast("Local automation is not available in this build", kind: .error); return
        }
        Actions.shared.perform("automation-rotate", args: ["reply": { (j: JSON) in
            MainActor.assumeIsolated {
                if let e = j["error"].string { StatusBus.shared.toast(e, kind: .error); return }
                self.readControl()
                StatusBus.shared.toast("Token replaced — re-register any client", kind: .ok)
            }
        } as (JSON) -> Void])
    }

    func copy(_ what: String) {
        if Actions.shared.isRegistered("automation-copy-command") {
            Actions.shared.perform("automation-copy-command", args: ["what": what])
        } else {
            Clipboard.write(control?[what == "bridge" ? "bridge" : "mcpCommand"].string ?? "")
        }
        StatusBus.shared.show("Copied")
    }

    /// Whether an assistant may type into a session — saved as it changes,
    /// like the automation switch beside it.
    func setTyping(_ v: String) {
        automationTyping = v
        SettingsDialog.apply(["automationTyping": .string(v)])
        let label = SettingsDialog.typingOptions.first { $0.value == v }?.label ?? v
        StatusBus.shared.show("Assistants typing into sessions: \(label)")
    }

    // MARK: tsh homes

    var defaultHome: String { MiscAppInfo.shared.defaultTshHome }

    func moveHome(_ i: Int, by d: Int) {
        let j = i + d
        guard tshHomes.indices.contains(i), tshHomes.indices.contains(j) else { return }
        tshHomes.swapAt(i, j)
    }

    func addHome(_ window: WindowModel?) async {
        guard let r = await MiscHomeDialog.run(window) else { return }
        // The list replaces the default rather than adding to it, so the first
        // directory added brings the default along — otherwise the clusters
        // already on screen would quietly disappear.
        if tshHomes.isEmpty { tshHomes.append(defaultHome) }
        if !tshHomes.contains(r.path) { tshHomes.append(r.path) }
        if !r.env.isEmpty { tshHomeEnv[r.path] = r.env }
    }

    func changeHome(_ i: Int, _ window: WindowModel?) async {
        guard tshHomes.indices.contains(i) else { return }
        let home = tshHomes[i]
        guard let r = await MiscHomeDialog.run(window, path: home, env: tshHomeEnv[home] ?? "") else { return }
        tshHomeEnv[home] = nil
        if !r.env.isEmpty { tshHomeEnv[r.path] = r.env }
        if tshHomes.indices.contains(i) { tshHomes[i] = r.path }
    }

    func addDefaultHome() {
        if !tshHomes.contains(defaultHome) { tshHomes.append(defaultHome) }
    }

    func checkHomes() async {
        homesNote = "Reading profiles…"
        // Applied first: what the check reports has to be what will be used.
        SettingsDialog.apply(["tshHomes": JSON(tshHomes)])
        guard let read = MiscHooks.teleportHomes else {
            homesNote = "Reading Teleport homes is not available in this build."
            return
        }
        let r = await read()
        if r["tsh"]["found"].bool == false {
            homesNote = "tsh was not found, so no home can be read. Looked in:\n"
                + r["tsh"]["searched"].stringArray.joined(separator: "\n")
            return
        }
        if let e = r["error"].string { homesNote = e; return }
        homesNote = r["homes"].items.map { h -> String in
            let name = h["name"].string ?? ""
            let whereText = h["default"].truthy ? "default" : (name.isEmpty ? (h["path"].string ?? "") : name)
            if h["exists"].bool == false { return "\(whereText): directory not found" }
            if let e = h["error"].string, !e.isEmpty { return "\(whereText): \(e)" }
            let profiles = h["profiles"].items
            if profiles.isEmpty { return "\(whereText): no profiles" }
            return "\(whereText): " + profiles.map { ($0["cluster"].string ?? "") + ($0["expired"].truthy ? " (expired)" : "") }
                .joined(separator: ", ")
        }.joined(separator: "\n")
    }

    // MARK: Watch (settings.watchedHosts, watch.js)

    var watchCount: Int { Store.shared.settings["watchedHosts"].entries.count }
    var watchMissing: Int { Store.shared.settings["watchedHosts"].entries.values.filter { $0["missingSince"].truthy }.count }

    // MARK: Save

    var patch: [String: JSON] {
        func int(_ s: String) -> Int? { Int(s.trimmed) ?? Double(s.trimmed).flatMap { $0.isFinite ? Int($0) : nil } }
        func lines(_ s: String) -> JSON { JSON(s.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }) }
        let tpl = launcherTemplate.trimmed
        let savedTpl = savedLauncher["template"].string ?? ""
        let hours = Double(expiredListHours.trimmed).flatMap { $0.isNaN || $0 == 0 ? nil : $0 } ?? 1
        // Only the homes still listed keep their variables.
        var homeEnv: [String: JSON] = [:]
        for (h, v) in tshHomeEnv where !v.isEmpty && tshHomes.contains(h) { homeEnv[h] = .string(v) }
        var p: [String: JSON] = [
            "theme": .string(theme), "accent": .string(accent), "skin": .string(skin),
            "terminalPalette": .string(terminalPalette), "x11": .string(x11), "mfaMode": .string(mfaMode),
            "connectAnim": .string(connectAnim), "recentLimit": JSON(int(recentLimit) ?? 20),
            "tshHomes": JSON(tshHomes), "tshHomeEnv": .object(homeEnv),
            "refreshSeconds": JSON(int(refreshSeconds) ?? 5),
            "nodeRefreshSeconds": JSON(int(nodeRefreshSeconds) ?? 10),
            "staleNodeMinutes": JSON(int(staleNodeMinutes) ?? 2),
            "sidebarHostLimit": JSON(int(sidebarHostLimit) ?? 20),
            "heartbeatStyle": .string(heartbeatStyle),
            "sidebarFontSize": JSON(max(10, min(22, int(sidebarFontSize).flatMap { $0 == 0 ? nil : $0 } ?? 13))),
            "fontFamily": .string(fontValue),
            "scrollback": JSON(int(scrollback).flatMap { $0 == 0 ? nil : $0 } ?? 10000),
            "cursorBlink": .bool(blink), "cursorStyle": .string(cursorStyle),
            "followTerminalFolder": .bool(follow),
            "showHiddenFiles": .bool(hidden), "showFileDetails": .bool(details),
            "foldersFirst": .bool(foldersFirst), "show3dView": .bool(show3d),
            "kubeEnabled": .bool(kubeEnabled),
            "externalEditor": .string(editor.trimmed), "highlight": .bool(highlight),
            "showShellInTitle": .bool(shellTitle), "showPaneNetIcon": .bool(netIcon),
            "showServerIcon": .bool(serverIcon), "liveStats": .bool(liveStats),
            "localStats": .bool(localStats), "statsOncePerTab": .bool(onePerTab),
            "quietRemote": .bool(quiet), "detectTeleportOnSsh": .bool(detectTeleport),
            "showTabActivity": .bool(tabActivity), "confirmLinkOpen": .bool(linkAsk),
            "confirmQuitWithSessions": .bool(quitAsk), "confirmCloseWithSessions": .bool(closeAsk),
            "confirmLoginToConnect": .bool(loginAsk), "paneCloseAnimations": .bool(paneCloseAnim),
            "focusFollowsMouse": .bool(focusFollowsMouse),
            "aiStartup": .string(aiStartup), "aiWorkdir": .string(aiWorkdir.trimmed), "aiKeys": .bool(aiKeys),
            "aiLauncher": .object([
                "on": .bool(launcherOn && !tpl.isEmpty), "template": .string(tpl),
                // The assistants it was made for stay only while the line is the same.
                "clients": tpl == savedTpl ? (savedLauncher["clients"].array.map { .array($0) } ?? .array([])) : .array([]),
            ]),
            "tmuxDefault": .bool(tmuxDefault),
            "tmuxSessionName": .string(tmuxName.trimmed.isEmpty ? "serverlife" : tmuxName.trimmed),
            "requestMonitorAutoOpen": .bool(reqPane), "showWatchMark": .bool(watchMark),
            "expiredListMode": .string(expiredListMode), "expiredListHours": JSON(max(1, hours)),
            "agentForward": .bool(agent), "starredMode": .string(starredMode),
            "autoFlagLocal": lines(autoLocal), "autoFlagHost": lines(autoHost),
        ]
        // Saved always; the panes change only if the size itself changed
        // (compare with `fontSizeBefore`), so each pane's own ⌘± size survives.
        p["fontSize"] = JSON(int(fontSize).flatMap { $0 == 0 ? nil : $0 } ?? 13)
        return p
    }

    func save(_ window: WindowModel?) {
        let p = patch
        let homesChanged = before["tshHomes"].stringArray != tshHomes
        MiscThemes.preview = nil
        SettingsDialog.apply(p)
        let after = Store.shared.settings
        for hook in MiscHooks.settingsSaved { hook(before, after) }
        // A changed home list is a changed inventory: the clusters on screen
        // came from the old set of directories.
        if homesChanged { Actions.shared.perform("refresh", window: window) }
        StatusBus.shared.show("Settings saved")
    }
}
