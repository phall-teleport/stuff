import AppKit

/// A menu item as ai.js builds them for `contextMenu`: a label, a key hint on
/// the right, an icon, a tooltip, a submenu — or a heading or separator.
struct AIMenuItem {
    var label = ""
    var key = ""
    var icon = ""
    var title: String?
    var enabled = true
    var heading = false
    var sep = false
    var submenu: [AIMenuItem]?
    var action: (@MainActor () -> Void)?

    static func heading(_ label: String) -> AIMenuItem { AIMenuItem(label: label, heading: true) }
    static var separator: AIMenuItem { AIMenuItem(sep: true) }
    static func item(_ label: String, key: String = "", icon: String = "", title: String? = nil, enabled: Bool = true,
                     _ action: @escaping @MainActor () -> Void) -> AIMenuItem {
        AIMenuItem(label: label, key: key, icon: icon, title: title, enabled: enabled, action: action)
    }
    static func sub(_ label: String, icon: String = "", title: String? = nil, _ items: [AIMenuItem]) -> AIMenuItem {
        AIMenuItem(label: label, icon: icon, title: title, submenu: items)
    }
}

/// Builds NSMenus from `AIMenuItem`s.
@MainActor
enum AIMenu {
    private final class Target: NSObject {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
        @objc func fire(_ sender: Any?) { MainActor.assumeIsolated { run() } }
    }

    /// Append to an existing menu (the sidebar's and hosts' context menus).
    static func append(_ items: [AIMenuItem], to menu: NSMenu) {
        menu.autoenablesItems = false
        for it in items {
            if it.sep {
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
                continue
            }
            if it.heading {
                let h = NSMenuItem(title: it.label.uppercased(), action: nil, keyEquivalent: "")
                h.isEnabled = false
                h.attributedTitle = NSAttributedString(string: it.label.uppercased(), attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
                menu.addItem(h)
                continue
            }
            let text = (it.icon.isEmpty ? "" : it.icon + "  ") + it.label
            let m = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            if !it.key.isEmpty {
                let s = NSMutableAttributedString(string: text + "    ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
                s.append(NSAttributedString(string: it.key, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                         .font: NSFont.menuFont(ofSize: 0)]))
                m.attributedTitle = s
            }
            m.toolTip = it.title
            m.isEnabled = it.enabled
            if let sub = it.submenu {
                let sm = NSMenu(title: it.label)
                append(sub, to: sm)
                m.submenu = sm
                m.isEnabled = it.enabled && !sub.isEmpty
            } else if let run = it.action {
                let t = Target(run)
                m.target = t
                m.action = #selector(Target.fire(_:))
                m.representedObject = t   // keeps the target alive with the item
            }
            menu.addItem(m)
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    static func build(_ items: [AIMenuItem]) -> NSMenu {
        let menu = NSMenu()
        append(items, to: menu)
        return menu
    }

    /// At the mouse pointer.
    static func show(_ items: [AIMenuItem]) {
        build(items).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
