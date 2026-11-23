import AppKit
import SwiftUI

/// panestyle.js — a pane's own look: its colours and its font, apart from the
/// rest of the window. A light pane for the production box among dark ones, a
/// bigger, plainer font for the one being shown on a call.
///
/// `pane.style` holds what was chosen — `{ theme, font }`, either one absent
/// meaning "as the app has it". A style can also be remembered for the host
/// the pane is on (or for local shells), in `settings.paneStyles`, keyed by
/// the host's id, and a new pane on that host starts with it.
@MainActor
enum PaneStyle {
    /// The key a pane's style is remembered under: its host, or "local".
    static func key(_ pane: SessionPane?) -> String {
        guard let pane else { return "" }
        if pane.kind == .local { return "local" }
        return SessConnRecords.shared.get(pane.connId)?.hostId ?? ""
    }

    static var saved: [String: JSON] { Store.shared.settingJSON("paneStyles").object ?? [:] }

    static func savedStyle(_ key: String) -> [String: String]? {
        guard !key.isEmpty, let o = saved[key]?.object else { return nil }
        var d: [String: String] = [:]
        if let t = o["theme"]?.string, !t.isEmpty { d["theme"] = t }
        if let f = o["font"]?.string, !f.isEmpty { d["font"] = f }
        return d
    }

    /// What a pane is styled as: its own choice, else what its host remembers.
    static func styleOf(_ pane: SessionPane) -> [String: String]? {
        pane.style ?? savedStyle(key(pane))
    }

    static func isLight(_ hex: String?) -> Bool {
        var h = (hex ?? "").trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count >= 6, let n = Int(h.prefix(6), radix: 16) else { return false }
        return 0.299 * Double(n >> 16) + 0.587 * Double((n >> 8) & 255) + 0.114 * Double(n & 255) > 150
    }

    /// The terminal palette a theme choice means, or nil for "as the app has it".
    static func paletteFor(_ theme: String?) -> [String: String]? {
        guard let theme, !theme.isEmpty else { return nil }
        if theme == "light" { return TermPalette.light }
        if theme == "dark" { return TermPalette.dark }
        if let named = MiscThemes.paletteByName(theme) {
            return (isLight(named["background"]) ? TermPalette.light : TermPalette.dark).merging(named) { _, n in n }
        }
        if let t = MiscThemes.themeById(theme) {
            let base = t.tone == "light" ? TermPalette.light : TermPalette.dark
            return base.merging(MiscThemes.appThemePalette(t) ?? [:]) { _, n in n }
        }
        return nil
    }

    /// The window colours for a theme choice, as the app's own named themes
    /// have them, so the pane's header takes the look along with its
    /// terminal. A plain light or dark, or a terminal palette, is turned into
    /// the same set from its background, text and blue.
    static func uiTokensFor(_ theme: String?) -> Palette? {
        guard let theme, !theme.isEmpty else { return nil }
        if let t = MiscThemes.themeById(theme) {
            return MiscThemes.palette(from: MiscThemes.themeTokens(t, MiscThemes.appThemeAnsi(t) ?? [:]), tone: t.tone)
        }
        guard let p = paletteFor(theme), let bg = p["background"], let fg = p["foreground"],
              bg.count == 7, fg.count == 7 else { return nil }
        let tone = isLight(bg) ? "light" : "dark"
        let t = MiscThemes.AppTheme(id: "", label: "", tone: tone, bg: bg, fg: fg, accent: p["blue"] ?? "#4c8dff",
                                    term: .own(""))
        return MiscThemes.palette(from: MiscThemes.themeTokens(t, p), tone: tone)
    }

    /// Paint a pane as its style says — or as the app does, for whatever it
    /// leaves unsaid. Called when a pane is made, when its style changes, and
    /// whenever the app's theme or font does, so a styled pane keeps its look.
    static func apply(_ pane: SessionPane) {
        guard let term = pane.term else { return }
        let st = styleOf(pane)
        let palette = paletteFor(st?["theme"])
        term.styleTheme = palette
        term.styleFont = st?["font"]
        term.applyTheme()
        term.applySettings()
        pane.styleBackground = palette.flatMap { $0["background"] }.map { Color(hex: $0) }
        pane.chrome = uiTokensFor(st?["theme"])
    }

    /// Every pane, after the app's own theme or font has changed.
    static func applyAll() {
        for w in SessionsCore.allWindows() { for p in w.panes.values { apply(p) } }
    }

    static func setStyle(_ pane: SessionPane, _ patch: [String: String?], window: WindowModel?) {
        var next = styleOf(pane) ?? [:]
        for (k, v) in patch { next[k] = v }
        next = next.filter { !$0.value.isEmpty }
        // Empty rather than nil: a pane put back to the app's look must not
        // fall back to its host's.
        pane.style = next
        apply(pane)
        Task { await afterChange(pane, window: window) }
    }

    /// What the question calls the pane's host.
    static func hostName(_ pane: SessionPane) -> String {
        if key(pane) == "local" { return "local shells" }
        return SessConn.label(pane.connId) ?? SessConnRecords.shared.label(pane.connId) ?? "this host"
    }

    /// After a pane's look is changed: should the host keep it? Asked once
    /// per pane, the first time — trying a few themes in a row asks once, not
    /// each time. Once answered yes, later changes in that pane carry on to
    /// the host without asking; once answered no, the pane is left to itself.
    static func afterChange(_ pane: SessionPane, window: WindowModel?) async {
        let k = key(pane)
        guard !k.isEmpty else { return }
        let st = pane.style ?? [:]
        let has = st["theme"] != nil || st["font"] != nil
        if pane.styleForHost == true { remember(pane, has, quiet: true); return }
        if pane.styleForHost == false || !has { return }
        let had = savedStyle(k) != nil
        let name = hostName(pane)
        let answer = await Modal.choose(window, title: "Use this look for \(name) from now on?",
                                        detail: (had ? "It replaces the look saved before. " : "")
                                            + (k == "local" ? "New local shells" : "New panes on \(name)")
                                            + " will start this way. Change or clear it from Pane style on a pane, or from the right-click menu in the host list.",
                                        buttons: ["Yes, from now on", "Just this pane"])
        pane.styleForHost = answer == 0
        if answer == 0 { remember(pane, true) }
    }

    static func remember(_ pane: SessionPane, _ on: Bool, quiet: Bool = false) {
        let k = key(pane)
        guard !k.isEmpty else { return }
        var all = saved
        if on, let st = styleOf(pane), st["theme"] != nil || st["font"] != nil {
            all[k] = .object(["theme": JSON(st["theme"]), "font": JSON(st["font"])])
        } else {
            all.removeValue(forKey: k)
        }
        Store.shared.setSettingJSON("paneStyles", .object(all))
        if !quiet {
            StatusBus.shared.show(on ? "This look will be used for new panes on this host" : "New panes on this host will look like the rest")
        }
    }

    /// A theme choice by name, for menus: "Light", "Nord", "Solarized dark".
    static func themeLabel(_ id: String) -> String {
        if id == "light" { return "Light" }
        if id == "dark" { return "Dark" }
        return MiscThemes.themeById(id)?.label ?? MiscThemes.terminalPalettes.first { $0.value == id }?.label ?? id
    }
}
