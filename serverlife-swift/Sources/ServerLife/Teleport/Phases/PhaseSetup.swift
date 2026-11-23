import Foundation

/*
 * Phase setups (phasesetup.js): ready-made steps for a phase.yaml, put
 * together into stages and checked against the rules `tsh phase apply`
 * itself applies.
 *
 * A Phase is a saved Beam image and how it stays current. `tsh phase apply`
 * takes a chain of stages, one YAML document each: a stage either runs
 * commands as root (a rebuild Phase, run again whenever its parent changes and
 * every day) or copies local files in (a copy Phase), and either kind can
 * declare services — programs started whenever a Beam starts from the image.
 * A setup here is one useful thing to do in a stage: install Go, keep a
 * Postgres running, clone a repository on first start, bring dotfiles in.
 *
 * What a setup produces is plain phase.yaml, shown before anything runs, so
 * nothing here is beyond what a person could write by hand. The rules follow
 * tsh's own (tool/tsh/common/phases_config.go in core): checking here means a
 * mistake is pointed at in the dialog rather than reported by a build that
 * already started.
 *
 * Commands must be repeatable: a rebuild stage runs them again on a fresh copy
 * of its parent every time it refreshes. Files under /home belong to
 * interactive work, so a command stage leaves /home alone (unless a path is
 * reserved with rebuild_home_paths) and anything a user should find in their
 * home is put there by a pre-start service on first start instead.
 */

/// One field a setup asks for.
struct PhaseSetupField: Equatable, Sendable {
    var key: String
    var label: String
    /// text, textarea, select, path, paths, yaml
    var kind = "text"
    var placeholder = ""
    /// nil where the original left `default` out (`f.default ?? ''`).
    var defaultValue: String?
    var required = false
    var options: [String]?
}

/// What a setup adds to its stage.
struct PhaseSetupOutput {
    var commands: [YAMLValue] = []
    var services: [YAMLValue] = []
    var files: [YAMLValue] = []
    var homePaths: [YAMLValue] = []
    /// `_check`: what is wrong with the values.
    var check: [String] = []
}

/// The context a build is made in: `home` resolves ~ in local paths;
/// `exists` (optional) says whether a local path is there.
struct PhaseSetupContext {
    var home = ""
    var exists: ((String) -> Bool)?
    var addins: [PhaseSetup] = []
}

/// A setup: where it goes (`stage`: commands, files, or any), the fields it
/// asks for, and what it adds to its stage.
struct PhaseSetup: Identifiable {
    var id: String
    var group: String
    var label: String
    var help = ""
    var stage: String
    var fields: [PhaseSetupField] = []
    var addin = false
    /// An add-in's file.
    var file: String?
    var expand: ([String: String], PhaseSetupContext) -> PhaseSetupOutput
}

/// One use of a setup in a stage.
struct PhaseSetupUse: Equatable, Identifiable {
    var key = uid("use")
    var id: String
    var values: [String: String] = [:]

    static func == (a: PhaseSetupUse, b: PhaseSetupUse) -> Bool { a.id == b.id && a.values == b.values }

    init(id: String, values: [String: String] = [:]) { self.id = id; self.values = values }
    var json: JSON { ["id": .string(id), "values": .object(values.mapValues { .string($0) })] }
    init(json: JSON) {
        id = json["id"].stringish ?? ""
        values = json["values"].entries.mapValues { $0.stringish ?? "" }
    }
}

/// A stage: `name`, `from` (first stage only), `kind` commands|files, its setups.
struct PhaseStage: Equatable, Identifiable {
    var key = uid("stage")
    var name = ""
    var from = ""
    var kind = "commands"
    var setups: [PhaseSetupUse] = []
    var id: String { key }

    static func == (a: PhaseStage, b: PhaseStage) -> Bool {
        a.name == b.name && a.from == b.from && a.kind == b.kind && a.setups == b.setups
    }
    init(name: String = "", from: String = "", kind: String = "commands", setups: [PhaseSetupUse] = []) {
        self.name = name; self.from = from; self.kind = kind; self.setups = setups
    }
    var json: JSON {
        ["name": .string(name), "from": .string(from), "kind": .string(kind), "setups": .array(setups.map(\.json))]
    }
    init(json: JSON) {
        name = json["name"].stringish ?? ""
        from = json["from"].stringish ?? ""
        kind = json["kind"].string == "files" ? "files" : "commands"
        setups = json["setups"].items.map(PhaseSetupUse.init(json:))
    }
}

/// What `build` says.
struct PhaseBuildResult {
    var docs: [YAMLValue]
    var errors: [String]
    var warnings: [String]
    /// Only not filled in yet, as against something wrong.
    var incomplete: [String]
    var yaml: String
    var ok: Bool { errors.isEmpty }
}

enum PhaseSetups {
    // The same limits tsh checks (services.MaxPhaseNameLength, MaxPhaseBuildConfigSize).
    static let maxName = 54
    static let maxBuildConfig = 32 * 1024
    static let dnsLabel = #"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"#
    static let serviceName = #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
    static let reservedServices: Set<String> = ["bootstrap", "beam-assemble"]
    static let reservedEnv: Set<String> = [
        "BEAM_BUILD_CONFIG_FILE", "BEAM_PARENT_PHASE_NAME", "BEAM_PHASE_NAME",
        "BEAM_WORKING_DIGEST", "BEAM_STREAM_BUILD_LOGS", "BEAM_BUILD_TYPE",
    ]
    static let serviceTypes = ["background", "pre-start"]
    static let serviceContexts = ["user", "runtime", "snapshot", "rebuild", "build", "all"]
    static let defaultPhase = "default:v1"
    /// Where copied home files wait for the pre-start service that puts them in place.
    static let homeStaging = "/opt/serverlife/home"

    // MARK: - Small helpers

    static func test(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static let aptEnv: YAMLValue = env("DEBIAN_FRONTEND", "noninteractive")
    static func apt(_ pkgs: String) -> String { "apt-get update && apt-get install -y --no-install-recommends \(pkgs)" }
    static func words(_ s: String?) -> [String] {
        (s ?? "").components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map(\.trimmed).filter { !$0.isEmpty }
    }
    /// One shell word, quoted only when it has to be.
    static func sq(_ s: String) -> String {
        test(#"^[A-Za-z0-9_@%+=:,./-]+$"#, s) ? s : "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A mapping that leaves out keys given as nil.
    static func m(_ pairs: (String, YAMLValue?)...) -> YAMLValue {
        .map(pairs.compactMap { k, v in v.map { (k, $0) } })
    }
    static func s(_ x: String?) -> YAMLValue? { x.map { .string($0) } }
    static func env(_ name: String, _ value: String) -> YAMLValue {
        .seq([.map([("name", .string(name)), ("value", .string(value))])])
    }
    /// `String(x || '')`.
    static func str(_ v: YAMLValue) -> String { v.truthy ? v.jsString : "" }
    /// `x || fallback` for a field value.
    static func or(_ v: String?, _ fallback: String) -> String { (v ?? "").isEmpty ? fallback : v! }
    /// `String(x || '').trim() || undefined`.
    static func trimmedOrNil(_ v: String?) -> String? {
        let t = (v ?? "").trimmed
        return t.isEmpty ? nil : t
    }

    static func firstLine(_ e: Error) -> String {
        let msg = (e as? YAMLError)?.message ?? (e as? AppError)?.message ?? e.localizedDescription
        return msg.components(separatedBy: "\n").first ?? ""
    }

    /// `Object.keys` of a loaded mapping.
    static func uniqueKeys(_ m: [(String, YAMLValue)]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for (k, _) in m where seen.insert(k).inserted { out.append(k) }
        return out
    }

    /// `{ ...a, key: v }`: replace in place, or append.
    static func setting(_ v: YAMLValue, _ key: String, _ x: YAMLValue) -> YAMLValue {
        guard case .map(var mm) = v else { return .map([(key, x)]) }
        if let i = mm.firstIndex(where: { $0.0 == key }) { mm[i].1 = x }
        else { mm.append((key, x)) }
        return .map(mm)
    }

    // MARK: - POSIX paths (node's path.posix)

    static func normalize(_ p: String) -> String {
        if p.isEmpty { return "." }
        let abs = p.hasPrefix("/")
        let trailing = p.hasSuffix("/")
        var out: [String] = []
        for seg in p.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." {
                if let l = out.last, l != ".." { out.removeLast() } else if !abs { out.append("..") }
                continue
            }
            out.append(String(seg))
        }
        var r = out.joined(separator: "/")
        if r.isEmpty && !abs { r = "." }
        if !r.isEmpty && trailing { r += "/" }
        return abs ? "/" + r : r
    }

    static func basename(_ p: String) -> String {
        var t = Substring(p)
        while t.count > 1 && t.hasSuffix("/") { t = t.dropLast() }
        if t == "/" { return "" }
        return t.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    static func dirname(_ p: String) -> String {
        let d = (p as NSString).deletingLastPathComponent
        return d.isEmpty ? "." : d
    }

    static func join(_ parts: String...) -> String {
        let j = parts.filter { !$0.isEmpty }.joined(separator: "/")
        return j.isEmpty ? "." : normalize(j)
    }

    static func relative(_ from: String, _ to: String) -> String {
        let a = normalize(from).split(separator: "/").map(String.init)
        let b = normalize(to).split(separator: "/").map(String.init)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
    }

    // MARK: - JSON.stringify (for the 32 KiB limit and the {{field}} scan)

    static func jsonStringify(_ v: YAMLValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return d.isFinite ? YAMLValue.jsNumber(d) : "null"
        case .string(let s): return jsonQuote(s)
        case .seq(let a): return "[" + a.map(jsonStringify).joined(separator: ",") + "]"
        case .map(let m):
            var seen: [String: Int] = [:]
            var out: [(String, YAMLValue)] = []
            for (k, x) in m { if let i = seen[k] { out[i].1 = x } else { seen[k] = out.count; out.append((k, x)) } }
            return "{" + out.map { jsonQuote($0.0) + ":" + jsonStringify($0.1) }.joined(separator: ",") + "}"
        }
    }

    static func jsonQuote(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case "\u{08}": o += "\\b"
            case "\u{0C}": o += "\\f"
            default:
                if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        return o + "\""
    }

    static func setup(_ id: String, _ ctx: PhaseSetupContext) -> PhaseSetup? {
        setups.first { $0.id == id } ?? ctx.addins.first { $0.id == id }
    }

    /// What the dialog shows: every setup — the built-in ones, then any add-ins.
    static func catalog(_ addins: [PhaseSetup] = []) -> [PhaseSetup] { setups + addins }
}
