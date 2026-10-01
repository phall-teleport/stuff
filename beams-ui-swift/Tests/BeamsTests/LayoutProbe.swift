import Testing
import AppKit
import SwiftUI
@testable import Beams

// Layout diagnostic (skipped unless BEAMS_LAYOUT_PROBE is set). Renders the
// real UI offscreen, using your local sessions, with one session selected,
// and writes <outputDir>/<view>.png. A layout feedback loop shows up as a
// crash (AppKit "_postWindowNeedsUpdateConstraints"); a normal app swallows
// that exception and is left half laid out instead.
//
//   BEAMS_LAYOUT_PROBE="<sessionID or none>|<outputDir>|content" PROBE_WIDTH=1000 \
//     Scripts/test.sh --filter layoutProbe
//
// <view>: content | main | transcript | banner | composer | sidebar | inspector | measure
// Toggles: PROBE_NO_INSPECTOR, PROBE_GITHUB_TAB, PROBE_BEAM_ALIVE, PROBE_NO_ITEMS, PROBE_SSH_BLOCKED,
//          PROBE_SHORT_TITLE, PROBE_NO_GLOBE.
@MainActor @Test func layoutProbe() throws {
    guard let spec = ProcessInfo.processInfo.environment["BEAMS_LAYOUT_PROBE"] else { return }
    let parts = spec.split(separator: "|").map(String.init)
    let (sid, outDir, which) = (parts[0], parts[1], parts[2])
    _ = NSApplication.shared
    let model = try AppModel()
    model.sessions = model.store.listSessions()
    model.beams = [Beam(id: "polar-panel", name: "polar-panel"), Beam(id: "prompt-cursor", name: "prompt-cursor")]
    model.beamsLoaded = true
    model.tshChecked = true
    model.tsh = TshStatus(tshFound: true, loggedIn: true, proxy: "super-grass.beams.sh", user: "paul", cluster: "super-grass.beams.sh")
    if sid != "none" { model.openSession(sid) }   // "none" = no session (empty state)
    let s = model.current ?? Session(id: "none", beamId: "", beamName: "")

    let env = ProcessInfo.processInfo.environment
    if which == "measure" {
        // Smallest width each piece accepts when offered almost none.
        func minWidth(_ v: some View) -> CGFloat {
            NSHostingController(rootView: v.environment(model)).sizeThatFits(in: CGSize(width: 1, height: 600)).width
        }
        print("PROBE-MIN main=\(minWidth(NavigationStack { MainView() })) transcript=\(minWidth(TranscriptView(sessionID: sid))) composer=\(minWidth(Composer())) banner=\(minWidth(ContinueBanner(session: s))) sidebar=\(minWidth(SidebarView())) inspector=\(minWidth(InspectorView()))")
        // Transcript rows, widest first.
        var widths: [(CGFloat, TranscriptItem)] = []
        for item in model.items[sid] ?? [] { widths.append((minWidth(TranscriptRow(item: item)), item)) }
        for (w, item) in widths.sorted(by: { $0.0 > $1.0 }).prefix(5) {
            print("PROBE-ROW \(Int(w)) \(item.kind) \(String((item.tool?.summary ?? item.text).prefix(80)).replacingOccurrences(of: "\n", with: " "))")
        }
        return
    }
    let width = Double(env["PROBE_WIDTH"] ?? "") ?? (which == "content" ? 1000 : 600)
    if env["PROBE_NO_INSPECTOR"] != nil { model.showInspector = false }
    if let i = model.sessions.firstIndex(where: { $0.id == sid }) {
        if env["PROBE_SHORT_TITLE"] != nil { model.sessions[i].title = "short" }
        if env["PROBE_NO_GLOBE"] != nil { model.sessions[i].publishedUrls = [] }
        if env["PROBE_BEAM_ALIVE"] != nil { model.beams.append(Beam(id: model.sessions[i].beamId, name: model.sessions[i].beamName)) }
    }
    if env["PROBE_NO_ITEMS"] != nil { model.items[sid] = [] }
    if env["PROBE_SSH_BLOCKED"] != nil { model.tsh.roles = ["access", "beam-admin", "editor"]; model.tsh.logins = [] }
    if env["PROBE_GITHUB_TAB"] != nil { model.inspectorTab = .github }
    let size = NSSize(width: width, height: 600)
    let view: AnyView
    switch which {
    case "content":    view = AnyView(ContentView())
    case "main":       view = AnyView(NavigationStack { MainView() })
    case "transcript": view = AnyView(TranscriptView(sessionID: sid))
    case "banner":     view = AnyView(ContinueBanner(session: s))
    case "composer":   view = AnyView(Composer())
    case "sidebar":    view = AnyView(SidebarView())
    case "inspector":  view = AnyView(InspectorView())
    default:           view = AnyView(Text("?"))
    }
    let host = NSHostingView(rootView: view.environment(model).frame(width: size.width, height: size.height))
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    win.contentView = host
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/\(which).png"))
    }
    print("PROBE-OK \(which)")
}
