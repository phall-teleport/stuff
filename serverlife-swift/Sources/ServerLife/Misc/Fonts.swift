import AppKit
import CoreText

/// Terminal fonts: the ones worth offering, which of them this machine has,
/// and the stack a choice becomes — the port of fonts.js and bundledfonts.js.
///
/// The setting used to be a free-text box, which only helped someone who
/// already knew the exact family name of a font they had installed. A list of
/// what is actually here is what people expect from a terminal's settings. In
/// the original the presence of each family was found by measuring it; here
/// the font manager simply says which families it has.
enum MiscFonts {
    /// Fallbacks for every platform, after whatever was chosen.
    static let defaultStack = "SFMono-Regular, Menlo, Consolas, \"Cascadia Mono\", \"DejaVu Sans Mono\", "
        + "\"Liberation Mono\", \"Noto Sans Mono\", monospace"

    /// Monospaced families worth offering, roughly by how often they are used.
    static let monoFonts = [
        "SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Fira Mono", "Cascadia Code",
        "Cascadia Mono", "Consolas", "Source Code Pro", "Hack", "IBM Plex Mono", "Roboto Mono",
        "Ubuntu Mono", "DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Inconsolata",
        "Iosevka", "Iosevka Term", "Victor Mono", "Geist Mono", "Monaspace Neon", "Monaspace Argon",
        "Monaspace Xenon", "Monaspace Radon", "Monaspace Krypton", "Berkeley Mono", "Input Mono",
        "Anonymous Pro", "Space Mono", "Red Hat Mono", "Commit Mono", "Intel One Mono", "Maple Mono",
        "Hasklig", "Operator Mono", "Comic Mono", "Droid Sans Mono", "PT Mono", "Andale Mono",
        "Lucida Console", "Courier New", "Courier",
        // Nerd Font builds, which carry the icons prompt themes draw with.
        "MesloLGS NF", "MesloLGS Nerd Font", "JetBrainsMono Nerd Font", "FiraCode Nerd Font",
        "Hack Nerd Font", "CaskaydiaCove Nerd Font",
    ]

    /// The fonts that ship with the app (Resources/fonts, see its README for
    /// licences and sources). `fixed` is whether every character is the same
    /// width — what a terminal needs; the rest are display faces, offered
    /// separately and labelled as such.
    static let bundled: [(family: String, fixed: Bool)] = [
        ("Anonymous Pro", true), ("Atkinson Hyperlegible Mono", true), ("Azeret Mono", true),
        ("B612 Mono", true), ("Bungee", false), ("Chivo Mono", true), ("Courier Prime", true),
        ("Cousine", true), ("Creepster", false), ("Cutive Mono", true), ("DM Mono", true),
        ("Fira Code", true), ("Fira Mono", true), ("Fragment Mono", true), ("Geist Mono", true),
        ("IBM Plex Mono", true), ("Inconsolata", true), ("Intel One Mono", true), ("JetBrains Mono", true),
        ("Kode Mono", true), ("Lekton", true), ("Major Mono Display", true), ("Martian Mono", true),
        ("Monofett", true), ("Monoton", false), ("Noto Sans Mono", true), ("Nova Mono", true),
        ("Overpass Mono", true), ("Oxygen Mono", true), ("Permanent Marker", false), ("Pirata One", false),
        ("Press Start 2P", true), ("Red Hat Mono", true), ("Reddit Mono", true), ("Roboto Mono", true),
        ("Share Tech Mono", true), ("Silkscreen", false), ("Sometype Mono", true), ("Sono", true),
        ("Source Code Pro", true), ("Space Mono", true), ("Special Elite", false), ("Spline Sans Mono", true),
        ("Syne Mono", true), ("Ubuntu Mono", true), ("Ubuntu Sans Mono", true), ("UnifrakturCook", false),
        ("UnifrakturMaguntia", false), ("Victor Mono", true), ("VT323", true), ("Xanh Mono", true),
    ]
    static let bundledSet = Set(bundled.map(\.family))

    /// What a stored setting becomes. A setting is either one family name,
    /// from the list, or whatever someone typed — which may already be a
    /// stack. A single name is quoted and given the fallbacks; anything with a
    /// comma is taken as the stack it already is; nothing is the default.
    static func stack(_ setting: String?) -> String {
        let v = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return defaultStack }
        if v.contains(",") { return v }
        var name = v
        if name.hasPrefix("\"") || name.hasPrefix("'") { name.removeFirst() }
        if name.hasSuffix("\"") || name.hasSuffix("'") { name.removeLast() }
        return "\"\(name.replacingOccurrences(of: "\"", with: ""))\", \(defaultStack)"
    }

    /// The first family of a stack this machine can draw, as an NSFont — by
    /// family name (what the setting holds) and then by PostScript name.
    static func font(_ setting: String?, size: CGFloat) -> NSFont {
        registerBundled()
        for raw in stack(setting).split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if name.isEmpty { continue }
            if name == "monospace" || name == "ui-monospace" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
            if let f = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return f }
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: Bundled fonts

    nonisolated(unsafe) private static var registered = false
    nonisolated(unsafe) private static var registeredFamilies: Set<String> = []

    /// Make the bundled fonts drawable in this process (once). Each file is
    /// named after its family without spaces: `JetBrainsMono.ttf`.
    static func registerBundled() {
        if registered { return }
        registered = true
        guard let dir = AppResources.url("fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let byFile = Dictionary(uniqueKeysWithValues: bundled.map { ($0.family.replacingOccurrences(of: " ", with: ""), $0.family) })
        for u in files where ["ttf", "otf"].contains(u.pathExtension.lowercased()) {
            var err: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(u as CFURL, .process, &err)
            // Already registered (by the shell, say) is as good as done.
            if ok || err != nil, let fam = byFile[u.deletingPathExtension().lastPathComponent] {
                registeredFamilies.insert(fam)
            }
        }
    }

    /// The bundled fonts that can actually be drawn: fixed-width ones for a
    /// terminal, or the display faces, which draw a terminal with its
    /// columns out of line.
    static func bundledFonts(fixed: Bool) -> [String] {
        registerBundled()
        let have = Set(NSFontManager.shared.availableFontFamilies)
        return bundled.filter { $0.fixed == fixed && (registeredFamilies.contains($0.family) || have.contains($0.family)) }.map(\.family)
    }

    /// Which of the coding fonts this machine has. A bundled family is left
    /// out: it is listed among the bundled ones already.
    static func installedFonts() -> [String] {
        let have = Set(NSFontManager.shared.availableFontFamilies)
        return monoFonts.filter { !bundledSet.contains($0) && have.contains($0) }
    }

    /// The font-picker choices, grouped: installed, then bundled fixed-width,
    /// then bundled display faces.
    static func choices() -> [(group: String, fonts: [String])] {
        [("Installed on this machine", installedFonts()),
         ("Bundled with ServerLife", bundledFonts(fixed: true)),
         ("Bundled display fonts (not fixed-width)", bundledFonts(fixed: false))]
            .filter { !$0.fonts.isEmpty }
    }
}
