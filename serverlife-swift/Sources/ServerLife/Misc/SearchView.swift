import AppKit
import SwiftUI

/// The search box's state in one window.
@MainActor
@Observable
final class MiscSearchState: WindowFeature {
    @ObservationIgnored weak var window: WindowModel?
    var query = ""
    var open = false
    var active = 0
    var groups: [MiscSearch.Group] = []
    var focused = false
    /// Bumped to put the keyboard in the box (⌘P).
    var focusRequest = 0
    /// Where the box is, in global coordinates, so the results can hang under it.
    var boxFrame: CGRect = .zero
    @ObservationIgnored var hoveringResults = false

    init(window: WindowModel) { self.window = window }

    /// Everything a row can open, in order: the groups' items, then the settings row.
    var flat: [MiscSearch.Item] {
        var f = groups.flatMap(\.items)
        let q = query.trimmed
        f.append(MiscSearch.Item(kind: "setting", name: "Search settings for \u{201C}\(q)\u{201D}", open: { [weak self] in
            SettingsDialog.open(self?.window, query: q)
        }))
        return f
    }

    func update() {
        let q = query.trimmed
        if q.isEmpty { close(); return }
        groups = MiscSearch.rank(MiscSearch.everything(window), q)
        active = 0
        open = true
    }

    func close() { open = false; active = 0 }

    func choose(_ it: MiscSearch.Item) {
        close()
        query = ""
        focused = false
        window?.nsWindow?.makeFirstResponder(nil)
        it.open()
    }

    func move(_ by: Int) { active = max(0, min(flat.count - 1, active + by)) }

    func escape() {
        query = ""
        close()
        focused = false
        window?.nsWindow?.makeFirstResponder(nil)
        window?.feature(SessionsWindow.self).focusActivePane()
    }
}

@MainActor
enum MiscSearchUI {
    private static var monitor: Any?

    static func install() {
        // The box sits just left of the title bar's buttons.
        let actions = Slots.titlebarActions
        Slots.titlebarActions = { w in
            AnyView(HStack(spacing: 8) {
                SearchBox(state: w.feature(MiscSearchState.self))
                actions(w)
            })
        }
        Slots.overlays.append { w in AnyView(SearchResults(state: w.feature(MiscSearchState.self))) }
        Actions.shared.register("search-everything") { ctx in
            focus(ctx.window ?? WindowManager.shared.focused)
        }
        // For an agent (the MCP serverlife_search tool): args `query`, `limit`, `kinds`; reply JSON.
        Actions.shared.register("search-data") { ctx in
            let r = MiscSearch.searchData(ctx.arg("query", as: String.self) ?? "",
                                          limit: ctx.arg("limit", as: Int.self) ?? 8,
                                          kinds: ctx.arg("kinds", as: [String].self),
                                          window: ctx.window ?? WindowManager.shared.focused)
            ctx.arg("reply", as: ((Any?) -> Void).self)?(r)
        }
        installKeys()
    }

    /// ⌘P: into the box, whatever has focus.
    static func focus(_ w: WindowModel?) {
        guard let w else { return }
        let s = w.feature(MiscSearchState.self)
        s.focusRequest += 1
    }

    private static func installKeys() {
        if monitor != nil { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let code = e.keyCode
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            let num = e.windowNumber
            let chars = e.charactersIgnoringModifiers ?? ""
            let consumed: Bool = MainActor.assumeIsolated { handle(code, mods, chars, num) }
            return consumed ? nil : e
        }
    }

    private static func handle(_ code: UInt16, _ mods: NSEvent.ModifierFlags, _ chars: String, _ num: Int) -> Bool {
        guard let w = WindowManager.shared.windows.first(where: { $0.nsWindow?.windowNumber == num }) else { return false }
        // ⌘P without Shift (⌘⇧P is the explorer's position).
        if mods == [.command], chars.lowercased() == "p" {
            // Not while a sheet is up over the window: that has the keyboard.
            if w.nsWindow?.attachedSheet != nil { return false }
            focus(w); return true
        }
        let s = w.feature(MiscSearchState.self)
        guard s.focused, mods.subtracting(.shift).isEmpty || code == 125 || code == 126 else { return false }
        switch code {
        case 125: if s.open { s.move(1); return true }
        case 126: if s.open { s.move(-1); return true }
        case 36, 76:
            if s.open { let f = s.flat; if s.active < f.count { s.choose(f[s.active]) }; return true }
        case 53: s.escape(); return true
        default: break
        }
        return false
    }
}

private struct SearchBox: View {
    let state: MiscSearchState
    @FocusState private var focused: Bool

    var body: some View {
        let p = Theme.shared.p
        @Bindable var s = state
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(p.muted)
            TextField("Search ServerLife  \u{2318}P", text: $s.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .autocorrectionDisabled()
                .focused($focused)
        }
        .padding(.horizontal, 8)
        .frame(width: 210, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? p.accent : p.border))
        .help("Hosts, profiles, clusters, beams, macros, snippets, layouts, multi-exec runs, AI prompts, actions and settings")
        .background(GeometryReader { g in
            Color.clear
                .onAppear { state.boxFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in state.boxFrame = f }
        })
        .tourAnchor("global-search")
        .onChange(of: state.query) { _, _ in state.update() }
        .onChange(of: state.focusRequest) { _, _ in
            focused = true
            // Select what is there, so typing replaces it.
            DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
        }
        .onChange(of: state.focused) { _, f in if !f { focused = false } }
        .onChange(of: focused) { _, f in
            state.focused = f
            if f {
                if !state.query.trimmed.isEmpty { state.update() }
            } else {
                // A click on a result lands after the box lets go.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    if !state.hoveringResults && !state.focused { state.close() }
                }
            }
        }
    }
}

private struct SearchResults: View {
    let state: MiscSearchState

    var body: some View {
        if state.open {
            GeometryReader { g in
                let origin = g.frame(in: .global).origin
                let box = state.boxFrame
                let width: CGFloat = 380
                list
                    .frame(width: width)
                    .offset(x: max(8, box.maxX - origin.x - width), y: box.maxY - origin.y + 4)
            }
        }
    }

    private var list: some View {
        let p = Theme.shared.p
        let flat = state.flat
        let groups = state.groups
        let starts = groups.indices.map { gi in groups[..<gi].reduce(0) { $0 + $1.items.count } }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
                        head(g.title + (g.more > 0 ? "  \u{00B7}  \(g.more) more" : ""))
                        ForEach(Array(g.items.enumerated()), id: \.offset) { ii, it in
                            rowView(it, starts[gi] + ii)
                        }
                    }
                    // A setting is found by opening Settings at it.
                    head(MiscSearch.kindTitle("setting"))
                    rowView(flat[flat.count - 1], flat.count - 1)
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: state.active) { _, a in proxy.scrollTo(a, anchor: nil) }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(p.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .onHover { state.hoveringResults = $0 }
    }

    private func head(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.shared.p.muted)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private func rowView(_ it: MiscSearch.Item, _ idx: Int) -> some View {
        let p = Theme.shared.p
        let on = idx == state.active
        return HStack(spacing: 8) {
            Text(it.name).font(.system(size: 12)).foregroundStyle(p.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if !it.meta.isEmpty {
                Text(it.meta).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? p.accentDim : Color.clear)
        .contentShape(Rectangle())
        .id(idx)
        .onHover { if $0 { state.active = idx } }
        .onTapGesture { state.choose(it) }
    }
}
