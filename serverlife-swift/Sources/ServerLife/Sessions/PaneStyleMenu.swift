import AppKit

/// panestyle.js `paneStyleMenu` / `hostStyleMenu`: the "Pane style" entry on
/// a pane's right-click menu, and "Saved pane style" on a host's.
@MainActor
extension PaneStyle {
    private static func item(_ m: NSMenu, _ title: String, on: Bool, tooltip: String? = nil, enabled: Bool = true,
                             _ run: @escaping () -> Void) {
        let i = m.sessAdd(title, enabled: enabled, tooltip: tooltip, run)
        if on { i.state = .on }
    }

    private static func sub(_ m: NSMenu, _ title: String, key: String = "", tooltip: String? = nil,
                            _ fill: (NSMenu) -> Void) {
        let sm = NSMenu()
        fill(sm)
        let i = NSMenuItem(title: key.isEmpty ? title : "\(title)  \(key)", action: nil, keyEquivalent: "")
        i.toolTip = tooltip
        i.submenu = sm
        m.addItem(i)
    }

    /// The themes, palettes and fonts, shared by both menus.
    private static func themeAndFont(_ m: NSMenu, theme: String?, font: String?, plainLightDark: Bool,
                                     setTheme: @escaping (String?) -> Void, setFont: @escaping (String?) -> Void,
                                     separators: Bool) {
        item(m, "Light", on: theme == "light") { setTheme("light") }
        item(m, "Dark", on: theme == "dark") { setTheme("dark") }
        let dark = MiscThemes.appThemes.filter { $0.tone == "dark" }
        let light = MiscThemes.appThemes.filter { $0.tone == "light" }
        sub(m, "Dark themes") { sm in for t in dark { item(sm, t.label, on: theme == t.id) { setTheme(t.id) } } }
        sub(m, "Light themes") { sm in for t in light { item(sm, t.label, on: theme == t.id) { setTheme(t.id) } } }
        let palettes = MiscThemes.terminalPalettes.filter { $0.theme != nil }
        if !palettes.isEmpty {
            sub(m, "Terminal palettes") { sm in for p in palettes { item(sm, p.label, on: theme == p.value) { setTheme(p.value) } } }
        }
        if separators { m.addItem(.separator()) }
        sub(m, "Font", key: font ?? "") { sm in
            item(sm, "As the app", on: font == nil) { setFont(nil) }
            // A submenu per group: fifty-odd fonts in one panel is a wall.
            for g in MiscFonts.choices() {
                sub(sm, g.group, key: String(g.fonts.count)) { gm in
                    for f in g.fonts { item(gm, f, on: font == f) { setFont(f) } }
                }
            }
        }
    }

    /// The "Pane style" entry for a pane's right-click menu.
    static func addPaneMenu(_ m: NSMenu, _ pane: SessionPane, window: WindowModel?) {
        guard pane.term != nil else { return }
        let st = styleOf(pane) ?? [:]
        let k = key(pane)
        let remembered = savedStyle(k) != nil
        let custom = st["theme"] != nil || st["font"] != nil
        sub(m, "\u{25D0} Pane style", key: custom ? "custom" : "", tooltip: "Colours and font for this pane alone") { sm in
            item(sm, "As the app", on: st["theme"] == nil) { setStyle(pane, ["theme": nil], window: window) }
            themeAndFont(sm, theme: st["theme"], font: st["font"], plainLightDark: true,
                         setTheme: { setStyle(pane, ["theme": $0], window: window) },
                         setFont: { setStyle(pane, ["font": $0], window: window) }, separators: true)
            sm.addItem(.separator())
            if !k.isEmpty {
                let title = remembered ? "Stop using this look for this host"
                    : (k == "local" ? "Use this look for every local shell" : "Use this look for this host")
                item(sm, title, on: false, tooltip: "New panes on it start this way", enabled: remembered || custom) {
                    pane.styleForHost = !remembered
                    remember(pane, !remembered)
                }
            }
            item(sm, "Reset this pane", on: false, enabled: custom) {
                setStyle(pane, ["theme": nil, "font": nil], window: window)
            }
        }
    }

    /// The saved look for a host, on its right-click menu in the host list —
    /// there only when one has been saved: change its colours or font, or
    /// clear it. Open panes on the host that follow it change with it.
    static func addHostMenu(_ m: NSMenu, key k: String) {
        guard let saved = savedStyle(k) else { return }
        func save(_ next: [String: String]?) {
            var all = PaneStyle.saved
            let v = (next ?? [:]).filter { !$0.value.isEmpty }
            if !v.isEmpty { all[k] = .object(["theme": JSON(v["theme"]), "font": JSON(v["font"])]) } else { all.removeValue(forKey: k) }
            Store.shared.setSettingJSON("paneStyles", .object(all))
            for w in SessionsCore.allWindows() {
                for p in w.panes.values where key(p) == k {
                    // Panes that follow the host: those never given a look of
                    // their own, and those whose look was the one saved.
                    if p.style == nil || p.styleForHost == true { p.style = nil; apply(p) }
                }
            }
            StatusBus.shared.show(!v.isEmpty ? "Saved look updated" : "Saved look cleared")
        }
        let parts = [saved["theme"].map(themeLabel) ?? "", saved["font"] ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        sub(m, "\u{25D0} Saved pane style", key: parts, tooltip: "The look new panes on this host start with") { sm in
            themeAndFont(sm, theme: saved["theme"], font: saved["font"], plainLightDark: true,
                         setTheme: { t in var n = saved; n["theme"] = t; save(n) },
                         setFont: { f in var n = saved; n["font"] = f; save(n) }, separators: false)
            sm.addItem(.separator())
            sm.sessAdd("\u{2326} Clear the saved look") { save(nil) }
        }
    }
}
