import Foundation

/*
 * Add-ins: setups of your own, one YAML file each (phasesetup.js).
 *
 * An add-in is a setup written as data rather than code — the same shape the
 * built-in ones have, so it sits in the same list and is checked the same
 * way. Its strings may use {{field}} for what was typed into a field, or
 * {{field|sh}} for the same quoted as one shell word. The files live in a
 * folder (Settings: phaseAddinsDir, or the app's own phase-addins folder), so
 * a team can point everyone at one checked-out repo.
 */
extension PhaseSetups {
    static let addinKeys: Set<String> = ["id", "label", "group", "help", "stage", "fields", "commands", "services", "files", "rebuild_home_paths"]
    static let fieldKinds = ["text", "textarea", "select", "path", "paths"]
    static let addinId = #"^[a-z0-9][a-z0-9._-]*$"#

    /// {{key}} and {{key|sh}} in every string of `value`, from `values`.
    static func fill(_ value: YAMLValue, _ values: [String: String]) -> YAMLValue {
        switch value {
        case .string(let str):
            guard let re = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][\w-]*)\s*(?:\|\s*(sh))?\s*\}\}"#) else { return value }
            let ns = str as NSString
            var out = ""
            var last = 0
            for mt in re.matches(in: str, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: mt.range.location - last))
                let v = values[ns.substring(with: mt.range(at: 1))] ?? ""
                out += mt.range(at: 2).location != NSNotFound ? sq(v) : v
                last = mt.range.location + mt.range.length
            }
            out += ns.substring(from: last)
            return .string(out)
        case .seq(let a): return .seq(a.map { fill($0, values) })
        case .map(let mm): return .map(mm.map { ($0.0, fill($0.1, values)) })
        default: return value
        }
    }

    /// Read one add-in's text into a setup, or throw saying what is wrong with
    /// it. `name` (the file's name without .yaml) is its id when it gives none.
    static func parseAddin(_ text: String, name: String = "addin") throws -> PhaseSetup {
        let doc: YAMLValue
        do { doc = try YAMLReader.load(text) } catch { throw AppError("not YAML: \(firstLine(error))") }
        guard case .map(let entries) = doc else { throw AppError("should be a mapping, starting with label:") }
        let unknown = uniqueKeys(entries).filter { !addinKeys.contains($0) }
        if !unknown.isEmpty { throw AppError("unknown key\(unknown.count > 1 ? "s" : ""): \(unknown.joined(separator: ", "))") }
        let id = (doc["id"].truthy ? doc["id"].jsString : name).lowercased()
        if !test(addinId, id) { throw AppError("\"\(id)\" can't be an id — lowercase letters, digits, . _ -") }
        if str(doc["label"]).trimmed.isEmpty { throw AppError("needs a label") }
        let stage = doc["stage"].truthy ? doc["stage"].jsString
            : (doc["files"].truthy ? "files" : (doc["commands"].truthy ? "commands" : "any"))
        if !["commands", "files", "any"].contains(stage) { throw AppError("stage is commands, files or any") }
        if stage == "commands" && doc["files"].truthy { throw AppError("a commands add-in copies no files — use stage: files") }
        if stage == "files" && doc["commands"].truthy { throw AppError("a files add-in runs no commands — use stage: commands") }
        if stage == "any" && (doc["commands"].truthy || doc["files"].truthy) {
            throw AppError("stage: any fits either kind of stage, so it can only add services")
        }
        for k in ["commands", "services", "files", "rebuild_home_paths", "fields"] where !doc[k].isNull && doc[k].items == nil {
            throw AppError("\(k) should be a list")
        }
        if (doc["commands"].items ?? []).isEmpty && (doc["services"].items ?? []).isEmpty && (doc["files"].items ?? []).isEmpty {
            throw AppError("adds nothing — give it commands, services or files")
        }
        var fields: [PhaseSetupField] = []
        for (i, f) in (doc["fields"].items ?? []).enumerated() {
            guard f.isMap, test(#"^[A-Za-z_][\w-]*$"#, str(f["key"])) else {
                throw AppError("fields[\(i)] needs a key (letters, digits, _ -)")
            }
            let kind = f["kind"].truthy ? (f["kind"].string ?? "?") : "text"
            if !fieldKinds.contains(kind) { throw AppError("fields[\(i)]: kind is one of \(fieldKinds.joined(separator: ", "))") }
            let options = f["options"].items ?? []
            if kind == "select" && options.isEmpty { throw AppError("fields[\(i)]: a select needs options") }
            let key = str(f["key"])
            fields.append(PhaseSetupField(
                key: key, label: f["label"].truthy ? f["label"].jsString : key, kind: kind,
                placeholder: f["placeholder"].isNull ? "" : f["placeholder"].jsString,
                defaultValue: !f["default"].isNull ? f["default"].jsString : (kind == "select" ? options[0].jsString : ""),
                required: f["required"].truthy,
                options: kind == "select" ? options.map(\.jsString) : nil))
        }
        // Fields the strings name but the add-in never asks for: a typo, almost always.
        let scan = jsonStringify(.seq([doc["commands"], doc["services"], doc["files"], doc["rebuild_home_paths"]]))
        var used: [String] = []
        if let re = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][\w-]*)"#) {
            let ns = scan as NSString
            for mt in re.matches(in: scan, range: NSRange(location: 0, length: ns.length)) {
                let k = ns.substring(with: mt.range(at: 1))
                if !used.contains(k) { used.append(k) }
            }
        }
        let missing = used.filter { k in !fields.contains { $0.key == k } }
        if !missing.isEmpty { throw AppError("uses {{\(missing.joined(separator: "}}, {{"))}} but has no such field") }
        let tpl: [(String, YAMLValue)] = [("commands", doc["commands"]), ("services", doc["services"]),
                                          ("files", doc["files"]), ("homePaths", doc["rebuild_home_paths"])]
        return PhaseSetup(
            id: "addin:" + id, group: doc["group"].truthy ? doc["group"].jsString : "My add-ins",
            label: doc["label"].jsString, help: doc["help"].truthy ? doc["help"].jsString : "",
            stage: stage, fields: fields, addin: true) { values, _ in
            let out = fill(.map(tpl), values)
            // A path field may start with ~, as the built-in file setups allow.
            let home = NSHomeDirectory()
            let files = (out["files"].items ?? []).map { f -> YAMLValue in
                let from = str(f["from"]).replacingOccurrences(of: #"^~(?=/|$)"#, with: home, options: .regularExpression)
                return setting(f, "from", .string(from))
            }
            return PhaseSetupOutput(commands: out["commands"].items ?? [], services: out["services"].items ?? [],
                                    files: files, homePaths: out["homePaths"].items ?? [])
        }
    }

    /// A file of the add-ins folder that is not a usable add-in, and why.
    struct AddinProblem { var file: String; var error: String }

    /// Every add-in in `dir`: the setups, and what is wrong with the files that are not.
    static func loadAddins(_ dir: String) -> (addins: [PhaseSetup], problems: [AddinProblem], dir: String) {
        var addins: [PhaseSetup] = []
        var problems: [AddinProblem] = []
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return (addins, problems, dir) }
        let names = all.filter { test(#"(?i)\.ya?ml$"#, $0) }.sorted()
        var seen = Set<String>()
        for n in names {
            let file = (dir as NSString).appendingPathComponent(n)
            do {
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { throw AppError("can't be read") }
                var a = try parseAddin(text, name: n.replacingOccurrences(of: #"(?i)\.ya?ml$"#, with: "", options: .regularExpression))
                if seen.contains(a.id) { throw AppError("another add-in already has the id \(a.id.dropFirst(6))") }
                seen.insert(a.id)
                a.file = file
                addins.append(a)
            } catch { problems.append(AddinProblem(file: file, error: (error as? AppError)?.message ?? "\(error)")) }
        }
        return (addins, problems, dir)
    }

    /// A starting point for a new add-in.
    static let addinTemplate = """
    # A setup of your own for "Build a Phase from setups".
    # {{field}} is what was typed in a field; {{field|sh}} is the same, shell-quoted.
    label: My tool
    group: My add-ins
    help: What it installs, in a sentence.
    stage: commands          # commands | files | any (services only)
    fields:
      - key: version
        label: Version
        default: "1.0.0"
        required: true
    commands:
      - comment: Install my tool {{version}}
        shell: |
          set -eu
          curl -fsSL "https://example.com/mytool-{{version}}-linux-$(dpkg --print-architecture).tar.gz" | tar -xz -C /usr/local/bin
    # services:
    #   - name: my-tool
    #     type: background     # or pre-start
    #     context: user        # user, runtime, snapshot, rebuild, build, all
    #     shell: exec mytool serve

    """
}
