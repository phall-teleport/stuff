import AppKit

// phasesetup.js `fromYaml`, and main.js's phasesetup:* handlers.
extension PhaseSetups {
    /**
     * An existing phase.yaml as the builder's stages, to carry on from: each
     * document a stage with its name, parent (the first one's), kind, and what it
     * holds kept exactly as written in a "Written in YAML" setup. Relative file
     * sources are made absolute against `dir`, where the file was, as tsh reads
     * them. A raw --commands-file (one document of commands:, no metadata) is
     * read as a single stage too.
     */
    static func fromYaml(_ text: String, dir: String = "") throws -> (stages: [PhaseStage], warnings: [String]) {
        let docs: [YAMLValue]
        do { docs = try KubeYAML.loadAllValues(text).filter { !$0.isNull } } catch { throw AppError("not YAML: \(firstLine(error))") }
        if docs.isEmpty { throw AppError("the file is empty") }
        var warnings: [String] = []
        var stages: [PhaseStage] = []
        for (i, d) in docs.enumerated() {
            guard case .map(let entries) = d else { throw AppError("document \(i + 1) is not a mapping") }
            let raw = !d["version"].truthy && !d["metadata"].truthy && d["commands"].truthy
            if !raw && d["version"].string != "v1" {
                warnings.append("document \(i + 1): version is \(d["version"].isNull ? "missing" : d["version"].jsString), not v1")
            }
            let name = d["metadata"]["name"].truthy ? d["metadata"]["name"].jsString : (raw ? "imported" : "stage-\(i + 1)")
            let from = str(d["metadata"]["from"])
            if i > 0 && !from.isEmpty && from != str(docs[i - 1]["metadata"]["name"]) {
                warnings.append("\(name): was built on \(from), not the stage before it — here every stage builds on the one above")
            }
            var files = d["files"]
            if let list = d["files"].items {
                files = .seq(list.map { f in
                    let fr = f["from"]
                    guard fr.truthy, !dir.isEmpty, !fr.jsString.hasPrefix("/") else { return f }
                    return setting(f, "from", .string(join(dir, fr.jsString)))
                })
            }
            var body: [(String, YAMLValue)] = []
            if d["commands"].truthy { body.append(("commands", d["commands"])) }
            if files.truthy { body.append(("files", files)) }
            if d["services"].truthy { body.append(("services", d["services"])) }
            let homePaths = d["metadata"]["rebuild_home_paths"].truthy ? d["metadata"]["rebuild_home_paths"] : d["protected_paths"]
            if homePaths.truthy { body.append(("rebuild_home_paths", homePaths)) }
            let known = ["version", "metadata", "commands", "files", "services", "protected_paths"]
            let extra = uniqueKeys(entries).filter { !known.contains($0) }
            if !extra.isEmpty { warnings.append("\(name): left out \(extra.joined(separator: ", ")) — not part of phase.yaml") }
            stages.append(PhaseStage(name: name, from: i == 0 ? from : "", kind: d["files"].truthy ? "files" : "commands",
                                     setups: [PhaseSetupUse(id: "raw", values: ["yaml": dumpYaml(.map(body)).trimmingTrailingWhitespacePS])]))
        }
        return (stages, warnings)
    }
}

/// What checking hand-written phase.yaml says (main.js checkHandYaml).
struct PhaseYamlCheck {
    var ok: Bool
    var parsed: Bool
    var stages: [PhaseStage]?
    var errors: [String]
    var warnings: [String]
    var incomplete: [String]
    var names: [String] = []
}

/// main.js's phasesetup:* handlers: the files, the folder and the context.
@MainActor enum PhaseSetupFiles {
    /// Add-ins: a folder of setups of your own, read fresh each time — they are a few small files.
    static var customAddinsDir: String {
        get { Store.shared.setting("phaseAddinsDir", "") }
        set { Store.shared.setSetting("phaseAddinsDir", newValue) }
    }
    static var addinsDir: String {
        customAddinsDir.isEmpty ? Store.shared.dir.appendingPathComponent("phase-addins").path : customAddinsDir
    }
    static var setupsDir: String { Store.shared.dir.appendingPathComponent("phase-setups").path }

    static func context() -> PhaseSetupContext {
        PhaseSetupContext(home: NSHomeDirectory(), exists: { FileManager.default.fileExists(atPath: $0) },
                          addins: PhaseSetups.loadAddins(addinsDir).addins)
    }
    static func catalog() -> [PhaseSetup] { PhaseSetups.catalog(PhaseSetups.loadAddins(addinsDir).addins) }
    static func build(_ stages: [PhaseStage]) -> PhaseBuildResult { PhaseSetups.build(stages, context()) }

    /*
     * phase.yaml written by hand in the builder: read into stages (to show on
     * the left, and to check with the same rules), the text itself left as it
     * was typed — comments, order and all.
     */
    static func checkHandYaml(_ text: String) -> PhaseYamlCheck {
        let parsed: (stages: [PhaseStage], warnings: [String])
        do { parsed = try PhaseSetups.fromYaml(text) } catch {
            return PhaseYamlCheck(ok: false, parsed: false, stages: nil, errors: [PhaseSetups.firstLine(error)], warnings: [], incomplete: [])
        }
        var r = PhaseSetups.build(parsed.stages, context())
        // tsh reads a relative from: against the file's own folder — wherever it is saved — and does not expand ~.
        if let docs = try? KubeYAML.loadAllValues(text) {
            for d in docs {
                for f in d["files"].items ?? [] where f["from"].truthy && !f["from"].jsString.hasPrefix("/") {
                    let who = d["metadata"]["name"].truthy ? d["metadata"]["name"].jsString : "a stage"
                    r.errors.append("\(who): write \"\(f["from"].jsString)\" as a full path — tsh reads it relative to wherever the file is saved, and does not expand ~")
                }
            }
        }
        return PhaseYamlCheck(ok: r.errors.isEmpty, parsed: true, stages: parsed.stages, errors: r.errors,
                              warnings: parsed.warnings + r.warnings, incomplete: r.incomplete,
                              names: r.docs.map { $0["metadata"]["name"].jsString })
    }

    /// `new Date().toISOString().replace(/[:.]/g, '-')`.
    static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date()).replacingOccurrences(of: "[:.]", with: "-", options: .regularExpression)
    }

    struct Written { var file: String; var yaml: String; var stages: [String] }

    /// phasesetup:write — a build gets its own file under the app's data, kept
    /// so the build journal can say what ran. Throws the errors, one per line.
    static func write(stages: [PhaseStage], file: String? = nil, handText: String? = nil) throws -> Written {
        let fm = FileManager.default
        func target(_ first: String?) -> String {
            if let file, !file.isEmpty { return file }
            return (setupsDir as NSString).appendingPathComponent("\(first.flatMap { $0.isEmpty ? nil : $0 } ?? "phase")-\(stamp()).yaml")
        }
        if let handText {
            let c = checkHandYaml(handText)
            if !c.ok { throw PhaseWriteError(errors: c.errors) }
            let t = target(c.names.first)
            try fm.createDirectory(atPath: (t as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try (handText.hasSuffix("\n") ? handText : handText + "\n").write(toFile: t, atomically: true, encoding: .utf8)
            return Written(file: t, yaml: handText, stages: c.names)
        }
        let r = build(stages)
        if !r.errors.isEmpty { throw PhaseWriteError(errors: r.errors) }
        let t = target(r.docs.first?["metadata"]["name"].jsString)
        try fm.createDirectory(atPath: (t as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try r.yaml.write(toFile: t, atomically: true, encoding: .utf8)
        return Written(file: t, yaml: r.yaml, stages: r.docs.map { $0["metadata"]["name"].jsString })
    }

    /// phasesetup:open — an existing phase.yaml, picked from where the builds are kept unless told otherwise.
    static func open() async throws -> (file: String, text: String, stages: [PhaseStage], warnings: [String])? {
        try? FileManager.default.createDirectory(atPath: setupsDir, withIntermediateDirectories: true)
        guard let file = await Modal.openFiles(multiple: false, directory: setupsDir, title: "Open a phase.yaml").first?.path else { return nil }
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let r = try PhaseSetups.fromYaml(text, dir: (file as NSString).deletingLastPathComponent)
        return (file, text, r.stages, r.warnings)
    }

    // MARK: - The add-in manager: list, check as typed, save, delete, and where they live.

    static func addinFile(_ name: String) throws -> String {
        let base = name.trimmed.lowercased().replacingOccurrences(of: #"\.ya?ml$"#, with: "", options: .regularExpression)
        if !PhaseSetups.test(PhaseSetups.addinId, base) { throw AppError("A file name is lowercase letters, digits, . _ -") }
        return (addinsDir as NSString).appendingPathComponent(base + ".yaml")
    }
    static func insideAddins(_ file: String) -> Bool {
        ((file as NSString).standardizingPath as NSString).deletingLastPathComponent == (addinsDir as NSString).standardizingPath
    }

    struct AddinCheck { var ok: Bool; var errors: [String]; var label = ""; var stage = ""; var yaml = "" }

    /// phasesetup:checkAddin — built with its defaults, as the builder would on
    /// adding it: the errors a stage would show.
    static func checkAddin(text: String, name: String) -> AddinCheck {
        do {
            let a = try PhaseSetups.parseAddin(text, name: name.isEmpty ? "addin" : name)
            var values: [String: String] = [:]
            for f in a.fields { values[f.key] = (f.defaultValue ?? "").isEmpty ? (f.placeholder.isEmpty ? "x" : f.placeholder) : f.defaultValue! }
            var setups = [PhaseSetupUse(id: a.id, values: values)]
            if a.stage == "any" { setups.append(PhaseSetupUse(id: "command", values: ["shell": "true"])) }
            var ctx = context()
            ctx.addins = [a]
            ctx.exists = { _ in true }
            let r = PhaseSetups.build([PhaseStage(name: "check", kind: a.stage == "files" ? "files" : "commands", setups: setups)], ctx)
            return AddinCheck(ok: r.errors.isEmpty, errors: r.errors.map { $0.replacingOccurrences(of: #"^Stage "check", "#, with: "", options: .regularExpression) },
                              label: a.label, stage: a.stage, yaml: r.yaml)
        } catch { return AddinCheck(ok: false, errors: [(error as? AppError)?.message ?? "\(error)"]) }
    }

    @discardableResult
    static func saveAddin(name: String, text: String, file: String?) throws -> String {
        let t: String
        if let file, insideAddins(file) { t = file } else { t = try addinFile(name) }
        _ = try PhaseSetups.parseAddin(text, name: ((t as NSString).lastPathComponent).replacingOccurrences(of: #"\.ya?ml$"#, with: "", options: .regularExpression))
        if file == nil && FileManager.default.fileExists(atPath: t) {
            throw AppError("\((t as NSString).lastPathComponent) is already there — pick another name")
        }
        try FileManager.default.createDirectory(atPath: (t as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: t, atomically: true, encoding: .utf8)
        return t
    }

    /// phasesetup:chooseAddinsDir — nil when the picker was cancelled.
    static func chooseAddinsDir(reset: Bool = false) async -> (dir: String, custom: Bool)? {
        if reset { customAddinsDir = ""; return (addinsDir, false) }
        guard let u = await Modal.chooseDirectory(defaultPath: addinsDir, title: "Folder of Phase add-ins") else { return nil }
        customAddinsDir = u.path
        return (u.path, true)
    }

    /// phasesetup:openAddinsDir.
    static func openAddinsDir() {
        try? FileManager.default.createDirectory(atPath: addinsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: addinsDir))
    }

    static func removeAddin(_ file: String) throws {
        if file.isEmpty || !insideAddins(file) { throw AppError("Not an add-in file") }
        try? FileManager.default.removeItem(atPath: file)
    }
}

/// phasesetup:write's `{ ok: false, errors }`.
struct PhaseWriteError: Error { var errors: [String] }
