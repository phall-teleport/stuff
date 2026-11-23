import Foundation

/// js-yaml as the kube modules used it: `dump(v, {lineWidth: -1})`,
/// `load`, `loadAll`, over Fleet's YAML port.
enum KubeYAML {
    /// `yaml.dump(value, { lineWidth })`; `-1` (the kube modules' choice) never folds.
    static func dump(_ value: YAMLValue, lineWidth: Int = -1, noRefs: Bool = true) -> String {
        var o = YAMLEmitter.Options()
        o.lineWidth = lineWidth < 0 ? 1_000_000_000 : lineWidth
        return YAMLEmitter.dump(value, o)
    }

    static func dump(_ json: JSON, lineWidth: Int = -1) -> String { dump(yaml(json), lineWidth: lineWidth) }

    /// `yaml.load(text)` as JSON.
    static func load(_ text: String) throws -> JSON { try YAMLReader.load(text).json }

    /// `yaml.loadAll(text)`: every document in a `---`-separated stream.
    static func loadAll(_ text: String) throws -> [JSON] {
        try documents(text).map { try YAMLReader.load($0).json }
    }

    static func loadAllValues(_ text: String) throws -> [YAMLValue] {
        try documents(text).map { try YAMLReader.load($0) }
    }

    /// The text of each document (a line that is `---`, optionally followed
    /// by content, starts the next; `...` ends one).
    static func documents(_ text: String) -> [String] {
        var docs: [String] = []
        var cur: [String] = []
        var started = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw
            if line == "---" || line.hasPrefix("--- ") || line.hasPrefix("---\t") {
                if started || cur.contains(where: { !isBlank($0) }) { docs.append(cur.joined(separator: "\n")) }
                cur = []
                started = true
                let rest = String(line.dropFirst(3)).trimmed
                if !rest.isEmpty { cur.append(rest) }
                continue
            }
            if line == "..." {
                docs.append(cur.joined(separator: "\n")); cur = []; started = false
                continue
            }
            if !started && line.hasPrefix("%") { continue }   // directives
            cur.append(line)
        }
        if started || cur.contains(where: { !isBlank($0) }) { docs.append(cur.joined(separator: "\n")) }
        return docs
    }

    private static func isBlank(_ l: String) -> Bool {
        let t = l.trimmed
        return t.isEmpty || t.hasPrefix("#")
    }

    /// JSON → YAMLValue, object keys sorted (JSON here keeps no order).
    static func yaml(_ j: JSON) -> YAMLValue {
        switch j {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 9e15 { return .int(Int(n)) }
            return .double(n)
        case .string(let s): return .string(s)
        case .array(let a): return .seq(a.map(yaml))
        case .object(let o): return .map(o.keys.sorted().map { ($0, yaml(o[$0]!)) })
        }
    }

    /// JSON text → YAMLValue keeping the object key order kubectl wrote — so an
    /// export reads like `kubectl get -o yaml` and not alphabetically.
    static func orderedJSON(_ text: String) throws -> YAMLValue {
        var p = OrderedJSONParser(Array(text.utf8))
        p.skip()
        let v = try p.value()
        p.skip()
        if p.i < p.b.count { throw AppError("Unexpected text after JSON") }
        return v
    }
}

private struct OrderedJSONParser {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { self.b = b }

    mutating func skip() { while i < b.count, [0x20, 0x0a, 0x0d, 0x09].contains(b[i]) { i += 1 } }

    func bad() -> AppError { AppError("Could not read JSON at byte \(i)") }

    mutating func value() throws -> YAMLValue {
        guard i < b.count else { throw bad() }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1; skip()
            var out: [(String, YAMLValue)] = []
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .map(out) }
            while true {
                skip()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw bad() }
                let k = try string()
                skip()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw bad() }
                i += 1; skip()
                let v = try value()
                if let at = out.firstIndex(where: { $0.0 == k }) { out[at].1 = v } else { out.append((k, v)) }
                skip()
                guard i < b.count else { throw bad() }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .map(out) }
                throw bad()
            }
        case UInt8(ascii: "["):
            i += 1; skip()
            var out: [YAMLValue] = []
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .seq(out) }
            while true {
                skip()
                out.append(try value())
                skip()
                guard i < b.count else { throw bad() }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .seq(out) }
                throw bad()
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            guard lit("true") else { throw bad() }; return .bool(true)
        case UInt8(ascii: "f"):
            guard lit("false") else { throw bad() }; return .bool(false)
        case UInt8(ascii: "n"):
            guard lit("null") else { throw bad() }; return .null
        default:
            let start = i
            while i < b.count, let c = Optional(b[i]), (c >= 0x30 && c <= 0x39) || c == 0x2d || c == 0x2b || c == 0x2e || c == 0x65 || c == 0x45 { i += 1 }
            guard i > start, let s = String(bytes: b[start..<i], encoding: .utf8), let d = Double(s) else { throw bad() }
            if !s.contains("."), !s.lowercased().contains("e"), let n = Int(s) { return .int(n) }
            return .double(d)
        }
    }

    mutating func lit(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= b.count, Array(b[i..<(i + u.count)]) == u else { return false }
        i += u.count
        return true
    }

    mutating func string() throws -> String {
        let start = i
        i += 1
        var escaped = false
        while i < b.count {
            let c = b[i]
            if escaped { escaped = false } else if c == 0x5c { escaped = true } else if c == 0x22 { break }
            i += 1
        }
        guard i < b.count else { throw bad() }
        i += 1
        let slice = Data(b[start..<i])
        guard let s = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]) as? String else { throw bad() }
        return s
    }
}
