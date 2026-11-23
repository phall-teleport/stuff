import AppKit
import SwiftUI

/// The panel on the right of the window (ai.js `ensurePanel`). Each
/// assistant is a chip in the panel's header, named for its client; the
/// panel hides and shows from its own header and from the ✦ button in the
/// toolbar, and hiding it leaves the assistants running.
struct AIPanelView: View {
    let window: WindowModel
    let ai: AIWindow

    var body: some View {
        if ai.shown {
            HStack(spacing: 0) {
                // Drag the left edge; the width is kept for next time.
                Resizer(axis: .vertical) { delta in
                    let cap = max(280, (window.nsWindow?.contentView?.bounds.width ?? 1500) - 300)
                    ai.width = min(cap, max(280, ai.width - delta))
                } onEnd: {
                    Store.shared.updateSettings(["aiPanelWidth": .number(Double(ai.width.rounded()))])
                }
                AIPanelBody(ai: ai)
                    .frame(width: ai.width)
            }
        }
    }
}

private struct AIPanelBody: View {
    let ai: AIWindow

    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 0) {
            header
            p.border.frame(height: 1)
            ZStack {
                p.bg
                ForEach(ai.sessions) { rec in
                    AITermHost(view: rec.view)
                        .padding(4)
                        .opacity(rec.id == ai.activeId ? 1 : 0)
                        .allowsHitTesting(rec.id == ai.activeId)
                }
            }
            if Store.shared.aiKeys { keyBar }
        }
        .background(p.panel)
        // Same opt-in as an ordinary pane: focus follows the mouse into the
        // panel — its header, its buttons, the padding round its terminal.
        .onHover { inside in
            guard inside, Store.shared.focusFollowsMouseAI, let rec = ai.active else { return }
            rec.focus()
        }
    }

    private var header: some View {
        let p = Theme.shared.p
        return HStack(spacing: 6) {
            Text("✦ AI").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(p.accentDim).cornerRadius(4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) { ForEach(ai.sessions) { AIChip(ai: ai, rec: $0) } }
            }
            Spacer(minLength: 4)
            Button("☰ Prompts") { AIMenu.show(ai.promptMenuItems()) }
                .buttonStyle(.ghostSmall).help("Saved prompts — send one to this assistant")
            Button("↓ Save") { AIMenu.show(ai.saveMenuItems(ai.active)) }
                .buttonStyle(.ghostSmall).help("Save a response — the selection, the screen or the whole conversation")
            // Enter, sent to the assistant on show. Its prompt often waits on
            // a key — a confirmation, a trust question, a pasted command —
            // and this answers it without clicking into the terminal first.
            Button("⏎ Enter") { ai.sendKey("\r", none: "No assistant running to send Enter to") }
                .buttonStyle(.ghostSmall).help("Send Enter to the assistant")
            Button("+") { AIMenu.show(AIOpen.menuItems(ai)) }
                .buttonStyle(IconButtonStyle(size: 20)).help("Another session of this assistant, or a different one")
            Button("⟩") { ai.show(false) }
                .buttonStyle(IconButtonStyle(size: 20)).help("Hide the assistant (it keeps running) — the ✦ button brings it back")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    /// Keys along the foot of the panel: Esc, ↑, ↓ and Enter. An assistant's
    /// questions are menus — pick an option with the arrows, Enter to take
    /// it, Esc to back out — and answering one meant clicking into the
    /// terminal first. These send the key straight to the assistant in front.
    private var keyBar: some View {
        let p = Theme.shared.p
        return HStack(spacing: 6) {
            ForEach(AIPanelBody.keys, id: \.label) { k in
                Button(k.label) { ai.sendKey(k.seq) }.buttonStyle(.ghostSmall).help(k.title)
                    .focusable(false)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(p.panel)
        .overlay(alignment: .top) { p.border.frame(height: 1) }
        .overlay(AIRightClick {
            AIMenu.build([.item("Hide these keys", title: "Settings → AI brings them back") {
                Store.shared.aiKeys = false
                StatusBus.shared.show("AI keys hidden — Settings brings them back")
            }])
        })
    }

    static let keys: [(label: String, seq: String, title: String)] = [
        ("Esc", "\u{1b}", "Send Escape — back out, or interrupt"),
        ("↑", "\u{1b}[A", "Send the up arrow"),
        ("↓", "\u{1b}[B", "Send the down arrow"),
        ("⏎ Enter", "\r", "Send Enter"),
    ]
}

/// One assistant's chip: its name (click to show, double-click to rename)
/// and ×. Yellow while a question waits.
private struct AIChip: View {
    let ai: AIWindow
    let rec: AISession
    var body: some View {
        let p = Theme.shared.p
        let active = rec.id == ai.activeId
        HStack(spacing: 3) {
            Text(rec.title).font(.system(size: 11.5)).lineLimit(1)
                .foregroundStyle(rec.waiting ? Color.black : (active ? p.text : p.textDim))
                .help("Double-click to rename")
                .onTapGesture(count: 2) { Task { await ai.rename(rec) } }
                .onTapGesture { ai.select(rec) }
            Button("×") { ai.close(rec) }.buttonStyle(.plain)
                .foregroundStyle(rec.waiting ? Color.black : p.muted)
                .help("Close \(rec.client.name) (ends its session)")
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(rec.waiting ? p.amber : (active ? p.panel3 : p.panel2))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? p.accent : p.border))
        .cornerRadius(4)
        .help(rec.chipTitle)
        .overlay(AIRightClick { AIMenu.build(ai.chipMenu(rec)) })
    }
}

/// Holds an assistant's terminal view, moving it in when the panel is drawn.
struct AITermHost: NSViewRepresentable {
    let view: SessionTermView
    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        attach(box)
        return box
    }
    func updateNSView(_ box: NSView, context: Context) {
        if view.superview !== box { attach(box) }
    }
    private func attach(_ box: NSView) {
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
    }
}

/// A right-click catcher laid over a SwiftUI view: takes only right-clicks,
/// so left clicks reach what is under it.
struct AIRightClick: NSViewRepresentable {
    let menu: @MainActor () -> NSMenu?
    final class V: NSView {
        var menuFor: (@MainActor () -> NSMenu?)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent, e.type == .rightMouseDown
                    || (e.type == .leftMouseDown && e.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }
        override func rightMouseDown(with event: NSEvent) { pop(event) }
        override func mouseDown(with event: NSEvent) { pop(event) }
        private func pop(_ event: NSEvent) {
            guard let m = MainActor.assumeIsolated({ menuFor?() }) else { return }
            NSMenu.popUpContextMenu(m, with: event, for: self)
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.menuFor = menu; return v }
    func updateNSView(_ v: V, context: Context) { v.menuFor = menu }
}
