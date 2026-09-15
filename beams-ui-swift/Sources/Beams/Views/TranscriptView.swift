import SwiftUI

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
                    if model.busy.contains(sessionID) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(thinkingLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 30)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28).padding(.vertical, 18)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.items[sessionID]?.count ?? 0) { _, _ in
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
        }
    }

    private var gutterColor: Color {
        switch item.kind {
        case .user, .assistant: return .accentColor
        case .result: return item.ok ? .secondary : .red
        default: return .secondary
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user:
            Text(item.text).textSelection(.enabled)
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

// MARK: - Tool card

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

struct Composer: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                Text("›").font(.body.monospaced()).foregroundStyle(Color.accentColor).padding(.bottom, 6)
                TextField("Ask Claude to do something in this sandbox… (Enter to send, ⌥Enter for newline)", text: $m.composer, axis: .vertical)
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
                        .disabled(model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)))
            Text(model.probeHint).font(.caption2.monospaced()).foregroundStyle(.tertiary).frame(height: 12)
        }
        .padding(.horizontal, 28).padding(.bottom, 12).padding(.top, 6)
        .frame(maxWidth: 956)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
        .onChange(of: model.currentID) { _, _ in focused = true }
    }
}
