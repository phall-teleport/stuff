import SwiftUI

/// yamlpath.js — indentation-based "what key path is the cursor under".
enum KubeYamlPath {
    private static func prefix(_ line: String) -> (indent: Int, dash: Int) {
        var spaces = 0, dash = 0
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { spaces += 1; i += 1 }
        if i < chars.count, chars[i] == "-" {
            var j = i + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            dash = j - i
        }
        return (spaces, dash)
    }

    private static let keyLine = try! NSRegularExpression(pattern: #"^(\s*)(-\s*)?([A-Za-z0-9_.-]+):(?:\s|$)"#)

    /// `inferYamlPath(text, cursorPos)` — `cursor` is a UTF-16 offset.
    static func infer(_ text: String, cursor: Int) -> [String] {
        let ns = text as NSString
        let before = ns.substring(to: min(max(cursor, 0), ns.length))
        let lines = before.components(separatedBy: "\n")
        let last = prefix(lines.last ?? "")
        var boundary = last.indent + last.dash
        var path: [String] = []
        var i = lines.count - 2
        while i >= 0 {
            let l = lines[i] as NSString
            if let m = keyLine.firstMatch(in: lines[i], range: NSRange(location: 0, length: l.length)) {
                let ind = m.range(at: 1).length + (m.range(at: 2).location == NSNotFound ? 0 : m.range(at: 2).length)
                if ind < boundary {
                    path.insert(l.substring(with: m.range(at: 3)), at: 0)
                    boundary = ind
                    if ind == 0 { break }
                }
            }
            i -= 1
        }
        return path
    }

    /// `topLevelKind(text)`.
    static func topLevelKind(_ text: String) -> (kind: String, apiVersion: String?)? {
        var kind: String?, api: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("kind:") {
                let v = line.dropFirst(5).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
                if let v, !v.isEmpty { kind = v }
            }
            if line.hasPrefix("apiVersion:") {
                let v = line.dropFirst(11).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
                if let v, !v.isEmpty { api = v }
            }
            if kind != nil && api != nil { break }
        }
        return kind.map { ($0, api) }
    }
}

/// yamleditor.js's linter (kube:validateYaml) and completer (kube:explainFields).
final class KubeYamlAssist: @unchecked Sendable {
    let spec: KubeSpec
    private let lock = NSLock()
    private var cache: [String: [JSON]] = [:]
    init(spec: KubeSpec) { self.spec = spec }

    var linter: @Sendable (String) async -> [CodeDiagnostic] {
        let spec = spec
        return { text in
            if text.trimmed.isEmpty { return [] }
            let r = await KubeResources.validateYaml(spec, yaml: text)
            if r["ok"].bool == true { return [] }
            let message = r["error"].string?.nilIfEmpty ?? "kubectl rejected this."
            var from = 0, to = min((text as NSString).length, 1)
            if let m = try? NSRegularExpression(pattern: #"field "([^"]+)""#).firstMatch(in: message, range: NSRange(location: 0, length: (message as NSString).length)) {
                let key = ((message as NSString).substring(with: m.range(at: 1)).split(separator: ".").last.map(String.init)) ?? ""
                let idx = (text as NSString).range(of: key + ":")
                if idx.location != NSNotFound { from = idx.location; to = idx.location + (key as NSString).length }
            }
            return [CodeDiagnostic(from: from, to: to, message: message)]
        }
    }

    private func fields(kind: String, api: String?) async -> [JSON] {
        let key = "\(kind)|\(api ?? "")"
        if let f = lock.withLock({ cache[key] }) { return f }
        let r = await KubeExplain.explainFields(spec, kind: kind, apiVersion: api)
        let f = r["ok"].bool == true ? r["fields"].items : []
        lock.withLock { cache[key] = f }
        return f
    }

    var completer: @Sendable (String, Int, Bool) async -> CodeCompletions? {
        { [self] text, pos, explicit in
            guard let top = KubeYamlPath.topLevelKind(text) else { return nil }
            let ns = text as NSString
            var from = min(pos, ns.length)
            let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            while from > 0, let u = UnicodeScalar(ns.character(at: from - 1)), wordChars.contains(u) { from -= 1 }
            if from == pos && !explicit { return nil }
            let prefix = KubeYamlPath.infer(text, cursor: pos).joined(separator: ".")
            let items = await fields(kind: top.kind, api: top.apiVersion).compactMap { f -> CodeCompletions.Item? in
                let path = f["path"].string ?? ""
                let parent = path.range(of: ".", options: .backwards).map { String(path[..<$0.lowerBound]) } ?? ""
                guard parent == prefix else { return nil }
                return .init(label: path.split(separator: ".").last.map(String.init) ?? path, detail: f["type"].string ?? "")
            }
            return items.isEmpty ? nil : CodeCompletions(from: from, items: items)
        }
    }
}

/// kubebrowser.js `textModal`: YAML (or text) in the code editor; editable
/// ones get "Preview the diff before applying" and Apply.
@MainActor
enum KubeTextModal {
    static func show(_ title: String, _ text: String, editable: Bool = false, spec: KubeSpec? = nil,
                     language: CodeLanguage = .yaml,
                     onApply: ((String, Bool) async -> Bool)? = nil) {
        Modal.sheet(title: title, width: 920, height: 640, resizable: true, autosave: "kube-text") { h in
            KubeTextModalView(title: title, text: text, editable: editable, spec: spec, language: language,
                              onApply: onApply, close: { h.close() })
        }
    }

    /// The diff → confirm → apply flow every editable YAML view shares.
    static func applyFlow(_ spec: KubeSpec, label: String, name: String) -> (String, Bool) async -> Bool {
        { yaml, preview in
            if preview {
                let d = await KubeResources.diffYaml(spec, yaml: yaml)
                if d["ok"].bool != true { StatusBus.shared.toast(d["error"].string ?? "Could not compute the diff", kind: .error); return false }
                if d["diff"].string == "(no changes)" { StatusBus.shared.toast("Nothing to apply — the edit matches what is already there"); return false }
                let sure = await Modal.confirm(title: "Apply changes to \(label)?",
                                               message: "This is what applying the edit below would change:",
                                               detail: d["diff"].string, ok: "Apply", destructive: true)
                if !sure { return false }
            }
            let a = await KubeResources.applyYaml(spec, yaml: yaml)
            if a["ok"].bool != true { StatusBus.shared.toast(a["error"].string ?? "kubectl apply failed", kind: .error); return false }
            StatusBus.shared.toast("Applied changes to \(name)")
            return true
        }
    }
}

private struct KubeTextModalView: View {
    let title: String
    let editable: Bool
    let spec: KubeSpec?
    let language: CodeLanguage
    let onApply: ((String, Bool) async -> Bool)?
    let close: () -> Void
    @StateObject private var text: Local<String>
    @StateObject private var preview = Local(false)
    @StateObject private var busy = Local(false)
    private let assist: KubeYamlAssist?

    init(title: String, text: String, editable: Bool, spec: KubeSpec?, language: CodeLanguage,
         onApply: ((String, Bool) async -> Bool)?, close: @escaping () -> Void) {
        self.title = title; self.editable = editable; self.spec = spec; self.language = language
        self.onApply = onApply; self.close = close
        _text = StateObject(wrappedValue: Local(text))
        assist = (editable && language == .yaml) ? spec.map { KubeYamlAssist(spec: $0) } : nil
    }

    var body: some View {
        DialogScaffold(title: title, scroll: false) {
            VStack(alignment: .leading, spacing: 8) {
                CodeEditor(text: $text.value, language: language, readOnly: !editable, tabIndents: false,
                           linter: assist?.linter, completer: assist?.completer)
                    .frame(minHeight: 360, maxHeight: .infinity)
                if editable { Toggle("Preview the diff before applying", isOn: $preview.value) }
            }
        } footer: {
            if editable {
                Button("Cancel") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let onApply, !busy.value else { return }
                    busy.value = true
                    Task { @MainActor in
                        let ok = await onApply(text.value, preview.value)
                        busy.value = false
                        if ok { close() }
                    }
                }.buttonStyle(.primary).disabled(busy.value)
            } else {
                Button("Close") { close() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
            }
        }
    }
}
