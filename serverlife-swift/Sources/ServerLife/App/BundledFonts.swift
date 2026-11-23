import AppKit
import CoreText

/// The fonts bundled with ServerLife, in Resources/fonts (see its README for
/// licences and sources) — bundledfonts.js. `fixed` is whether every
/// character is the same width — what a terminal needs; the rest are display
/// faces, offered separately and labelled as such.
///
/// `registerAll()` runs at launch (process scope: nothing is installed on the
/// Mac). The family names are the ones the original's fonts.css gives each
/// file, which is what settings store (`fontFamily`, a pane's font); a file
/// whose own family name differs is still found under that name through
/// `font(family:size:)`.
@MainActor
enum BundledFonts {
    struct Entry: Equatable {
        let family: String
        let fixed: Bool
        /// The .ttf in Resources/fonts — the family without spaces.
        var file: String { family.replacingOccurrences(of: " ", with: "") + ".ttf" }
    }

    static let list: [Entry] = [
        .init(family: "Anonymous Pro", fixed: true),
        .init(family: "Atkinson Hyperlegible Mono", fixed: true),
        .init(family: "Azeret Mono", fixed: true),
        .init(family: "B612 Mono", fixed: true),
        .init(family: "Bungee", fixed: false),
        .init(family: "Chivo Mono", fixed: true),
        .init(family: "Courier Prime", fixed: true),
        .init(family: "Cousine", fixed: true),
        .init(family: "Creepster", fixed: false),
        .init(family: "Cutive Mono", fixed: true),
        .init(family: "DM Mono", fixed: true),
        .init(family: "Fira Code", fixed: true),
        .init(family: "Fira Mono", fixed: true),
        .init(family: "Fragment Mono", fixed: true),
        .init(family: "Geist Mono", fixed: true),
        .init(family: "IBM Plex Mono", fixed: true),
        .init(family: "Inconsolata", fixed: true),
        .init(family: "Intel One Mono", fixed: true),
        .init(family: "JetBrains Mono", fixed: true),
        .init(family: "Kode Mono", fixed: true),
        .init(family: "Lekton", fixed: true),
        .init(family: "Major Mono Display", fixed: true),
        .init(family: "Martian Mono", fixed: true),
        .init(family: "Monofett", fixed: true),
        .init(family: "Monoton", fixed: false),
        .init(family: "Noto Sans Mono", fixed: true),
        .init(family: "Nova Mono", fixed: true),
        .init(family: "Overpass Mono", fixed: true),
        .init(family: "Oxygen Mono", fixed: true),
        .init(family: "Permanent Marker", fixed: false),
        .init(family: "Pirata One", fixed: false),
        .init(family: "Press Start 2P", fixed: true),
        .init(family: "Red Hat Mono", fixed: true),
        .init(family: "Reddit Mono", fixed: true),
        .init(family: "Roboto Mono", fixed: true),
        .init(family: "Share Tech Mono", fixed: true),
        .init(family: "Silkscreen", fixed: false),
        .init(family: "Sometype Mono", fixed: true),
        .init(family: "Sono", fixed: true),
        .init(family: "Source Code Pro", fixed: true),
        .init(family: "Space Mono", fixed: true),
        .init(family: "Special Elite", fixed: false),
        .init(family: "Spline Sans Mono", fixed: true),
        .init(family: "Syne Mono", fixed: true),
        .init(family: "Ubuntu Mono", fixed: true),
        .init(family: "Ubuntu Sans Mono", fixed: true),
        .init(family: "UnifrakturCook", fixed: false),
        .init(family: "UnifrakturMaguntia", fixed: false),
        .init(family: "Victor Mono", fixed: true),
        .init(family: "VT323", fixed: true),
        .init(family: "Xanh Mono", fixed: true),
    ]

    /// fonts.css family → the family name inside the registered file.
    private(set) static var registeredFamily: [String: String] = [:]
    private static var done = false

    /// Register every bundled face for this process. Safe to call twice.
    static func registerAll() {
        guard !done else { return }
        done = true
        guard let dir = AppResources.url("fonts") else { return }
        for e in list {
            let url = dir.appendingPathComponent(e.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var err: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
            // Already registered (a second launch path) is fine too.
            if ok || err != nil,
               let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let first = descs.first,
               let fam = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String {
                registeredFamily[e.family] = fam
            }
        }
    }

    static func isBundled(_ family: String) -> Bool { list.contains { $0.family == family } }

    /// A bundled face by its fonts.css name, or nil when it is not one of
    /// these (or failed to register).
    static func font(family: String, size: CGFloat) -> NSFont? {
        guard let fam = registeredFamily[family] else { return nil }
        return NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: size)
            ?? NSFont(name: fam, size: size)
    }

    /// The first family in a CSS-style list (`"Fira Code", Menlo, monospace`)
    /// that resolves — bundled, installed, or the generic monospace — as the
    /// original's font stacks fall through.
    static func resolve(stack: String, size: CGFloat) -> NSFont {
        for raw in stack.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if name.isEmpty { continue }
            if let f = font(family: name, size: size) { return f }
            switch name.lowercased() {
            case "monospace", "ui-monospace", "sfmono-regular", "sf mono":
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            default: break
            }
            if let f = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return f }
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
