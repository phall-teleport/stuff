import SwiftUI
import UniformTypeIdentifiers

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.items[sessionID] ?? []) { item in
                        TranscriptRow(item: item)
                    }
                    if let req = model.pendingPermissions[sessionID]?.first {
                        PermissionCard(request: req, queued: (model.pendingPermissions[sessionID]?.count ?? 1) - 1)
                            .padding(.leading, 30)
                    } else if model.busy.contains(sessionID) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(thinkingLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 30)
                    }
                    // Room for the composer's floating image thumbnails (inside the
                    // scroll content, so it doesn't change the window's layout).
                    Color.clear.frame(height: model.composerImages.isEmpty ? 1 : 76).id("bottom")
                }
                .padding(.horizontal, 28).padding(.vertical, 18)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.items[sessionID]?.count ?? 0) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.pendingPermissions[sessionID]?.count ?? 0) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.composerImages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var thinkingLabel: String {
        if let last = model.items[sessionID]?.last, last.kind == .tool, last.tool?.result == nil { return "running \(last.tool?.name ?? "tool")…" }
        return "thinking…"
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(gutter).font(.system(.body, design: .monospaced)).foregroundStyle(gutterColor).frame(width: 18)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gutter: String {
        switch item.kind {
        case .user: return "›"
        case .assistant: return "◈"
        case .tool: return ""
        case .systemInit: return "◦"
        case .thinking: return "∴"
        case .stderr: return "·"
        case .result: return item.ok ? "✓" : "✕"
        case .permission: return item.ok ? "✓" : "⊘"
        }
    }

    private var gutterColor: Color {
        switch item.kind {
        case .user, .assistant: return .accentColor
        case .result: return item.ok ? .secondary : .red
        case .permission: return item.ok ? .green : .orange
        default: return .secondary
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .leading, spacing: 8) {
                if !item.images.isEmpty { UserImages(paths: item.images) }
                if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
            }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        case .assistant:
            MarkdownText(item.text)
        case .tool:
            if let t = item.tool { ToolCard(tool: t) }
        case .systemInit, .thinking:
            Text(item.text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        case .permission:
            Text(item.text).font(.caption.monospaced()).foregroundStyle(item.ok ? Color.secondary : Color.orange).textSelection(.enabled)
        case .stderr:
            Text(item.text).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        case .result:
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.bottom, 6)
                Text(item.text).font(.caption.monospaced()).foregroundStyle(item.ok ? Color.secondary : Color.red).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Permission prompt (inline, like the CLI's)

struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest
    let queued: Int
    @StateObject private var showInput = LocalFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Claude wants to use").foregroundStyle(.secondary)
                Text(request.toolName).font(.body.monospaced().weight(.semibold))
                if queued > 0 { Text("+\(queued) more waiting").font(.caption).foregroundStyle(.tertiary) }
                Spacer()
            }
            if !request.summary.isEmpty || !request.description.isEmpty {
                Text(request.summary.isEmpty ? request.description : request.summary)
                    .font(.callout.monospaced()).textSelection(.enabled).lineLimit(6)
                    .padding(.trailing, 28).copyable(request.summary.isEmpty ? request.description : request.summary)
            }
            Button(showInput.on ? "Hide details" : "Show details") { withAnimation { showInput.on.toggle() } }
                .buttonStyle(.link).font(.caption)
            if showInput.on { CodeBlock(text: request.inputJSON) }
            HStack(spacing: 8) {
                Button("Allow") { model.answer(request, allow: true) }
                    .buttonStyle(.borderedProminent).keyboardShortcut("y", modifiers: [])
                Button("Allow all this turn") { model.answer(request, allow: true, allRestOfTurn: true) }
                    .buttonStyle(.bordered).keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Deny") { model.answer(request, allow: false) }
                    .buttonStyle(.bordered).tint(.red).keyboardShortcut("n", modifiers: [])
                Spacer()
                Text("Y allow · N deny").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.5)))
    }
}

// MARK: - Tool card

/// Images attached to a user turn, loaded off the main thread (AsyncImage)
/// from the session's images folder. Click one to open it in Preview.
struct UserImages: View {
    @Environment(AppModel.self) private var model
    let paths: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(paths, id: \.self) { rel in
                let url = model.currentID.map { model.store.sessionDir($0).appendingPathComponent(rel) }
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFit() }
                    else { RoundedRectangle(cornerRadius: 6).fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                            .frame(width: 120, height: 90) }
                }
                .frame(maxWidth: 220, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
                .help("Open in Preview")
            }
        }
    }
}

struct ToolCard: View {
    let tool: ToolInfo
    @StateObject private var open = LocalFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.12)) { open.on.toggle() } } label: {
                HStack(spacing: 8) {
                    Text(tool.name).font(.callout.monospaced().weight(.semibold)).foregroundStyle(.blue)
                    Text(tool.summary).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    if tool.result == nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: tool.isError ? "xmark" : "checkmark").font(.caption.weight(.bold))
                            .foregroundStyle(tool.isError ? .red : .green)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.on {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("INPUT").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    CodeBlock(text: tool.inputJSON)
                    if let r = tool.result {
                        Text(tool.isError ? "ERROR" : "RESULT").font(.caption2.weight(.semibold)).foregroundStyle(tool.isError ? Color.red : Color(nsColor: .tertiaryLabelColor))
                        CodeBlock(text: r.isEmpty ? "(no output)" : r)
                    }
                }
                .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}

struct CodeBlock: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .copyable(text)
    }
}

// MARK: - Markdown

enum MDBlock: Hashable {
    case paragraph(String)
    case heading(Int, String)
    case code(String, String)
    case list(Bool, [String])
}

enum MarkdownBlocks {
    static func parse(_ src: String) -> [MDBlock] {
        var out: [MDBlock] = []
        var para: [String] = []
        var list: (ordered: Bool, items: [String])? = nil
        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushList() { if let l = list { out.append(.list(l.ordered, l.items)); list = nil } }
        let lines = src.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let ln = lines[i]
            if ln.hasPrefix("```") {
                flushPara(); flushList()
                let lang = String(ln.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var buf: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") { buf.append(lines[i]); i += 1 }
                i += 1
                out.append(.code(lang, buf.joined(separator: "\n")))
                continue
            }
            if let m = ln.firstMatch(of: #/^(#{1,3})\s+(.*)$/#) {
                flushPara(); flushList(); out.append(.heading(m.1.count, String(m.2))); i += 1; continue
            }
            if let m = ln.firstMatch(of: #/^\s*[-*]\s+(.*)$/#) {
                flushPara(); if list == nil || list!.ordered { flushList(); list = (false, []) }
                list!.items.append(String(m.1)); i += 1; continue
            }
            if let m = ln.firstMatch(of: #/^\s*\d+[.)]\s+(.*)$/#) {
                flushPara(); if list == nil || !list!.ordered { flushList(); list = (true, []) }
                list!.items.append(String(m.1)); i += 1; continue
            }
            if ln.trimmingCharacters(in: .whitespaces).isEmpty { flushPara(); flushList(); i += 1; continue }
            para.append(ln); i += 1
        }
        flushPara(); flushList()
        return out
    }

    /// Wraps bare URLs as markdown links so AttributedString makes them tappable.
    static func linkify(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?<![\(<\[])(https?://[^\s<>"')\]]+?)([.,;:!?]*)(?=$|[\s<)\]])"#,
                               with: "[$1]($1)$2", options: .regularExpression)
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linkify(s), options: opts)) ?? AttributedString(s)
    }
}

struct MarkdownText: View {
    let blocks: [MDBlock]
    init(_ text: String) { blocks = MarkdownBlocks.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .paragraph(let s):
                    Text(MarkdownBlocks.inline(s)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                case .heading(_, let s):
                    Text(MarkdownBlocks.inline(s)).font(.headline).padding(.top, 4)
                case .code(_, let s):
                    CodeBlock(text: s)
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ordered ? "\(i + 1)." : "•").foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                                Text(MarkdownBlocks.inline(it)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Composer

/// Catches ⌘V while the composer has focus: an image on the clipboard is
/// attached instead of pasted (a text field can't take images). Text pastes
/// pass through untouched.
@MainActor
final class ImagePasteMonitor: ObservableObject {
    private var token: Any?

    func install(_ model: AppModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] ev in
            guard let model, model.composerFocused, model.current != nil,
                  ev.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  ev.charactersIgnoringModifiers == "v",
                  let imgs = ImageAttachment.fromPasteboard(.general) else { return ev }
            model.attachImages(imgs)
            return nil
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @StateObject private var paste = ImagePasteMonitor()
    @StateObject private var dropping = LocalFlag()

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                Text("›").font(.body.monospaced()).foregroundStyle(Color.accentColor).padding(.bottom, 6)
                TextField("Ask Claude to do something in this sandbox… (⌥Enter for newline; paste or drop images)", text: $m.composer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { model.send() }
                    .padding(.vertical, 6)
                if model.currentBusy {
                    Button { model.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.bordered).tint(.red).help("Stop (⌘.)")
                } else {
                    Button { model.send() } label: { Image(systemName: "return") }
                        .buttonStyle(.borderedProminent).help("Send (Enter)")
                        .disabled(model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.composerImages.isEmpty)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(dropping.on ? Color.accentColor : focused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor),
                                                               lineWidth: dropping.on ? 2 : 1))
            .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { dropping.on }, set: { dropping.on = $0 })) { providers in
                loadDropped(providers); return true
            }
            Text(model.probeHint).font(.caption2.monospaced()).foregroundStyle(.tertiary).frame(height: 12)
        }
        .padding(.horizontal, 28).padding(.bottom, 12).padding(.top, 6)
        .frame(maxWidth: 956)
        .frame(maxWidth: .infinity)
        // Thumbnails float above the composer as an overlay: inserting them in
        // the VStack made the composer taller and set off the split view's
        // layout loop at narrow widths (LayoutProbe PROBE_IMAGES=composer).
        .overlay(alignment: .topLeading) {
            if !model.composerImages.isEmpty { attachments.offset(y: -64) }
        }
        .onAppear { focused = true; paste.install(model) }
        .onDisappear { paste.remove(); model.composerFocused = false }
        .onChange(of: focused) { _, f in model.composerFocused = f }
        .onChange(of: model.currentID) { _, _ in focused = true; model.composerImages = [] }
    }

    /// Thumbnails of the images that go with the next prompt.
    private var attachments: some View {
        HStack(spacing: 8) {
            ForEach(model.composerImages) { img in
                Image(nsImage: img.thumbnail).resizable().scaledToFill()
                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .overlay(alignment: .topTrailing) {
                        Button { model.composerImages.removeAll { $0.id == img.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain).help("Remove image").padding(2)
                    }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .padding(.leading, 52)
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadDataRepresentation(for: .fileURL) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil),
                          let raw = try? Data(contentsOf: url), let img = ImageAttachment.make(from: raw) else { return }
                    DispatchQueue.main.async { model.attachImages([img]) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = p.loadDataRepresentation(for: .image) { data, _ in
                    guard let data, let img = ImageAttachment.make(from: data) else { return }
                    DispatchQueue.main.async { model.attachImages([img]) }
                }
            }
        }
    }
}
