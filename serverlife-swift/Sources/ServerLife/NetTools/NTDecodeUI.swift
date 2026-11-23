import SwiftUI
import AppKit

// The pieces nettools.js's decoders and command blocks share: commandBlock,
// tags, rows (values that can be views), card, headline, stateTag, whenNode,
// fileCard and withRawToggle.

extension Store {
    /// "readable" or "raw" — the decoders' last-picked view (settings.decoderView).
    var ntDecoderView: String {
        get { setting("decoderView", "readable") }
        set { setSetting("decoderView", newValue) }
    }
}

/// `commandBlock(command, note)`: the command the tool ran, to run it
/// yourself outside ServerLife. The note is a caveat, never copied with it.
struct NTCmdBlock: View {
    let command: String?
    var note: String? = nil
    var body: some View {
        if let command, !command.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 8) {
                    NTCmd(text: command).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy") {
                        Clipboard.write(command)
                        StatusBus.shared.show("Command copied")
                    }
                    .buttonStyle(.ghostSmall)
                    .help("Copy this command to run it yourself, outside ServerLife")
                }
                if let note, !note.isEmpty {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.shared.p.muted.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

enum NTWhen {
    /// `inWords(sec)`: "in 3d 4h", "12m 5s ago".
    static func inWords(_ sec: Int?) -> String {
        guard let sec else { return "" }
        let past = sec < 0
        var s = abs(sec)
        let d = s / 86400; s -= d * 86400
        let h = s / 3600; s -= h * 3600
        let m = s / 60
        let txt = d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m \(s % 60)s"
        return past ? "\(txt) ago" : "in \(txt)"
    }

    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// `when(iso)`: "Mon 12 Oct 2026, 3:20 PM".
    static func when(_ iso: String?) -> String {
        guard let iso, iso != "forever" else { return iso ?? "" }
        guard let d = date(iso) else { return iso }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy j:mm")
        return f.string(from: d)
    }

    /// `whenNode(iso)` as text: the date with how far off it is.
    static func node(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        if iso == "forever" { return "never" }
        guard let d = date(iso) else { return iso }
        return when(iso) + "  " + inWords(Int((d.timeIntervalSinceNow).rounded()))
    }

    /// `stateTag(state, expiresIn)`.
    static func stateTag(_ state: String, _ expiresIn: Int?) -> (text: String, kind: String) {
        let ok = state == "valid"
        let label = ok ? (expiresIn == nil ? "valid, never expires" : "valid — expires \(inWords(expiresIn))")
            : state == "expired" && expiresIn != nil ? "expired \(inWords(expiresIn))" : state
        return (label, ok ? "ok" : "bad")
    }
}

/// `tags(values, {max, kind})`: the first `max`, then "+N more".
struct NTTags: View {
    let values: [String]
    var max = 12
    var kind = ""
    @StateObject private var all = LocalFlag()
    var body: some View {
        if values.isEmpty {
            Text("none").font(.system(size: 11.5)).foregroundStyle(Theme.shared.p.muted)
        } else {
            NTFlow {
                ForEach(Array((all.on ? values : Array(values.prefix(max))).enumerated()), id: \.offset) { _, v in
                    NTBadge(text: v, kind: kind).help(v)
                }
                if values.count > max {
                    Button(all.on ? "show fewer" : "+\(values.count - max) more") { all.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.shared.p.accent)
                }
            }
        }
    }
}

/// A `rows()` value: text, or a view.
enum NTVal {
    case text(String?)
    case view(AnyView)
    static func tags(_ v: [String], max: Int = 12, kind: String = "") -> NTVal { .view(AnyView(NTTags(values: v, max: max, kind: kind))) }
    static func when(_ iso: String?) -> NTVal { .text(NTWhen.node(iso)) }
    var isEmpty: Bool { if case .text(let s) = self { return (s ?? "").isEmpty }; return false }
}

/// `rows(list)`: label/value pairs whose values may be views.
struct NTRows: View {
    let rows: [(String, NTVal)]
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                if !r.1.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(r.0).font(.system(size: 12)).foregroundStyle(p.muted).frame(width: 150, alignment: .leading)
                        Group {
                            switch r.1 {
                            case .text(let s):
                                Text(s ?? "").font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .view(let v): v
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// `card(title, …)`.
struct NTCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 4) {
            if let title { NTHead(text: title) }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
        .padding(.bottom, 8)
    }
}

/// `headline(text, ...badges)`.
struct NTHeadline: View {
    let text: String
    let badges: [(text: String, kind: String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            NTFlow { ForEach(Array(badges.enumerated()), id: \.offset) { _, b in NTBadge(text: b.text, kind: b.kind) } }
        }
        .padding(.bottom, 10)
    }
}

/// `fileCard(file)`: where a decoded file lives, with Show in Finder.
struct NTFileCard: View {
    let file: String?
    var body: some View {
        if let file, !file.isEmpty {
            NTCard(title: "File") {
                HStack(spacing: 8) {
                    Text(file).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(file)
                    Spacer(minLength: 4)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                        .buttonStyle(.ghostSmall).help("Open the folder it is in, with the file selected")
                }
            }
        }
    }
}

/// `withRawToggle(node, raw)`: Readable and Raw, the choice remembered.
struct NTRawToggle<Content: View>: View {
    let raw: String
    @ViewBuilder var content: () -> Content
    @StateObject private var mode = Local(Store.shared.ntDecoderView == "raw" ? "raw" : "readable")
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { mode.value }, set: { v in
                    mode.value = v
                    Store.shared.ntDecoderView = v
                })) {
                    Text("Readable").tag("readable")
                    Text("Raw").tag("raw")
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                Spacer()
                Button("Copy raw") { Clipboard.write(raw); StatusBus.shared.show("Raw output copied") }.buttonStyle(.ghostSmall)
            }
            if mode.value == "raw" { NTPre(text: raw, boxed: true) } else { content() }
        }
    }
}
