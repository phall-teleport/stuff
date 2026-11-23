import Foundation

// phasesetup.js `tidy`, `checkCommand`, `build`, `toYaml`.
extension PhaseSetups {
    /// Plain copy without empty fields, so the YAML has no `key: null` lines.
    static func tidy(_ v: YAMLValue) -> YAMLValue {
        switch v {
        case .seq(let a): return .seq(a.map(tidy))
        case .map(let mm):
            var out: [(String, YAMLValue)] = []
            for (k, x) in mm {
                if x.isNull { continue }
                if case .string(let s) = x, s.isEmpty { continue }
                if case .seq(let a) = x, a.isEmpty, k != "files" { continue }
                out.append((k, tidy(x)))
            }
            return .map(out)
        default: return v
        }
    }

    /// `${x.key}` of a loaded value — "undefined" when it has none.
    static func said(_ v: YAMLValue, _ key: String) -> String {
        if case .map(let mm) = v, let x = mm.last(where: { $0.0 == key })?.1 { return x.jsString }
        return "undefined"
    }

    static func checkCommand(_ c: YAMLValue, _ wh: String, _ errors: inout [String]) {
        if c["shell"].truthy && c["command"].truthy { errors.append("\(wh): a shell script or a command, not both") }
        if str(c["shell"]).trimmed.isEmpty && str(c["command"]).trimmed.isEmpty { errors.append("\(wh): nothing to run") }
        if c["workdir"].truthy {
            let w = c["workdir"].jsString
            if !w.hasPrefix("/") || normalize(w) != w || (w.count > 1 && w.hasSuffix("/")) {
                errors.append("\(wh): the working folder must be a clean absolute path (\(w))")
            }
        }
        var seen = Set<String>()
        for e in c["env"].items ?? [] {
            let name = e["name"].truthy ? e["name"].jsString : ""
            if name.isEmpty || name.contains("=") || name.contains("\0") || seen.contains(name) {
                errors.append("\(wh): environment variable \"\(said(e, "name"))\" is empty, repeated or has \"=\"")
            }
            if let n = e["name"].string, reservedEnv.contains(n) { errors.append("\(wh): \(n) is reserved for builds") }
            seen.insert(name)
        }
        for s in [c["shell"], c["command"], c["workdir"]] + (c["args"].items ?? []) {
            if let t = s.string, t.contains("\0") { errors.append("\(wh): contains a NUL byte") }
        }
    }

    /// Turn the dialog's stages into phase.yaml documents, and say what tsh
    /// would refuse. `ctx.home` resolves ~ in local paths; `ctx.exists`
    /// (optional) says whether a local path is there.
    static func build(_ stages: [PhaseStage], _ ctx: PhaseSetupContext = PhaseSetupContext()) -> PhaseBuildResult {
        var errors: [String] = []
        var warnings: [String] = []
        var docs: [YAMLValue] = []
        /*
         * What is only not filled in yet — an empty stage, a required field left
         * blank, a stage with no name — as against something wrong. Both stop a
         * build; the dialog holds the first kind back until a build is asked for,
         * rather than greeting a new, empty stage with an error.
         */
        var incomplete: [String] = []
        func unfinished(_ m: String) { errors.append(m); incomplete.append(m) }
        var names = Set<String>()
        for (i, st) in stages.enumerated() {
            let label = st.name.isEmpty ? "Stage \(i + 1)" : "Stage \"\(st.name)\""
            let name = st.name.trimmed
            if name.isEmpty { unfinished("\(label): needs a name") }
            else if !test(dnsLabel, name) || name.utf16.count > maxName {
                errors.append("\(label): a name is lowercase letters, digits and hyphens, starting and ending with a letter or digit, up to \(maxName) characters")
            } else if names.contains(name) { errors.append("\(label): another stage already has this name") }
            names.insert(name)

            // The chain: every stage after the first builds on the one before it.
            var from = i == 0 ? st.from.trimmed : stages[i - 1].name.trimmed
            if from == defaultPhase { from = "" }
            if i == 0 && !from.isEmpty && !test(dnsLabel, from) { errors.append("\(label): \"\(from)\" is not a Phase name") }

            let kind = st.kind == "files" ? "files" : "commands"
            var commands: [(YAMLValue, String)] = []
            var services: [(YAMLValue, String)] = []
            var files: [(YAMLValue, String)] = []
            var homePaths: [YAMLValue] = []
            for use in st.setups {
                let found = setup(use.id, ctx)
                let wh = "\(label), \(found?.label ?? use.id)"
                guard let setup = found else {
                    errors.append("\(wh): \(use.id.hasPrefix("addin:") ? "add-in not found — removed, or its file has a problem (My add-ins…)" : "unknown setup")")
                    continue
                }
                if setup.stage != "any" && setup.stage != kind {
                    errors.append("\(wh): goes in a \(setup.stage == "files" ? "copy-files" : "commands") stage — add it to a stage of that kind")
                    continue
                }
                var values: [String: String] = [:]
                for f in setup.fields { values[f.key] = f.defaultValue ?? "" }
                for (k, v) in use.values { values[k] = v }
                for f in setup.fields where f.required && (values[f.key] ?? "").trimmed.isEmpty {
                    unfinished("\(wh): \"\(f.label)\" is needed")
                }
                let out = setup.expand(values, ctx)
                for m in out.check { errors.append("\(wh): \(m)") }
                if kind == "files" && !out.commands.isEmpty {
                    errors.append("\(wh): a copy-files stage runs no commands — make this stage \"Install and run commands\", or move them to a stage of that kind")
                }
                if kind == "commands" && !out.files.isEmpty { errors.append("\(wh): a commands stage copies no files — put them in a \"Copy files\" stage") }
                if kind == "files" && !out.homePaths.isEmpty { errors.append("\(wh): rebuild_home_paths needs a commands stage") }
                commands += out.commands.map { ($0, wh) }
                services += out.services.map { ($0, wh) }
                files += out.files.map { ($0, wh) }
                homePaths += out.homePaths
            }

            if kind == "commands" && commands.isEmpty {
                unfinished("\(label): a commands stage needs at least one command — add a setup that installs or runs something")
            }
            for (c, wh) in commands { checkCommand(c, wh, &errors) }

            var serviceNames = Set<String>()
            for (sv, wh) in services {
                let sn = str(sv["name"])
                if !test(serviceName, sn) || sn.utf16.count > 128 || reservedServices.contains(sv["name"].string ?? "\u{0}") {
                    errors.append("\(wh): \"\(said(sv, "name"))\" can't be a service name")
                } else if serviceNames.contains(sn) {
                    errors.append("\(wh): two services are called \"\(sn)\" — the later one would replace the first")
                }
                serviceNames.insert(sn)
                if sv["type"].truthy && !serviceTypes.contains(sv["type"].string ?? "\u{0}") { errors.append("\(wh): kind must be background or pre-start") }
                if sv["context"].truthy && !serviceContexts.contains(sv["context"].string ?? "\u{0}") {
                    errors.append("\(wh): runs in must be one of \(serviceContexts.joined(separator: ", "))")
                }
                checkCommand(sv, wh, &errors)
            }
            if kind == "files" && services.contains(where: { $0.0["context"].string == "rebuild" }) {
                warnings.append("\(label): copy stages never run services; a service that runs only in rebuilds belongs on a commands stage")
            }

            for pv in homePaths {
                let p = pv.jsString
                if !p.hasPrefix("/") || normalize(p) != p || p.contains("\0") || test(#"[*?\[\]]"#, p) || (p.count > 1 && p.hasSuffix("/")) {
                    errors.append("\(label): reserved home folder \"\(p)\" must be a clean absolute path, without wildcards")
                } else if p != "/home" && !p.hasPrefix("/home/") {
                    warnings.append("\(label): \"\(p)\" is not under /home — only home folders need reserving")
                }
            }

            for (f, wh) in files {
                let to = str(f["to"])
                if !f["from"].truthy { errors.append("\(wh): which file or folder to copy?") }
                if !to.hasPrefix("/") { errors.append("\(wh): the destination must be an absolute path (\(to.isEmpty ? "none" : to))") }
                let clean = normalize(to)
                if clean == "/home" || clean.hasPrefix("/home/") {
                    errors.append("\(wh): copies go outside /home — use \"My dotfiles and settings\" for files the Beam user should have")
                }
                if f["from"].truthy, let exists = ctx.exists, !exists(f["from"].jsString) {
                    errors.append("\(wh): \(f["from"].jsString) is not on this computer")
                }
            }

            var meta: [(String, YAMLValue)] = [("name", .string(name))]
            if !from.isEmpty { meta.append(("from", .string(from))) }
            if !homePaths.isEmpty { meta.append(("rebuild_home_paths", .seq(homePaths))) }
            var doc: [(String, YAMLValue)] = [("version", .string("v1")), ("metadata", .map(meta))]
            if kind == "commands" { doc.append(("commands", .seq(commands.map(\.0)))) }
            else { doc.append(("files", .seq(files.map(\.0)))) }
            if !services.isEmpty { doc.append(("services", .seq(services.map(\.0)))) }
            let clean = tidy(.map(doc))
            docs.append(clean)

            // What tsh stores as the build configuration has to fit in 32 KiB.
            let raw = jsonStringify(.map([("protected_paths", .seq(homePaths)),
                                          ("commands", clean["commands"].isNull ? .seq([]) : clean["commands"]),
                                          ("services", clean["services"].isNull ? .seq([]) : clean["services"])]))
            if raw.utf16.count > maxBuildConfig {
                errors.append("\(label): its commands and services come to \(raw.utf16.count) bytes; a stage can hold \(maxBuildConfig)")
            }
        }
        if docs.isEmpty { unfinished("Add a stage") }
        return PhaseBuildResult(docs: docs, errors: errors, warnings: warnings, incomplete: incomplete, yaml: toYaml(docs))
    }

    /// The documents as phase.yaml text.
    static func toYaml(_ docs: [YAMLValue], header: Bool = true) -> String {
        let body = docs.map { dumpYaml($0).trimmingTrailingWhitespacePS }.joined(separator: "\n---\n")
        let head = header ? "# A Phase setup made in ServerLife. Build it with: tsh phase apply -f <this file>\n" : ""
        return head + body + "\n"
    }

    /// js-yaml `dump(d, { lineWidth: -1, noRefs: true })`.
    static func dumpYaml(_ v: YAMLValue) -> String {
        KubeYAML.dump(v, lineWidth: -1)
    }
}

extension String {
    /// JS `trimEnd()`.
    var trimmingTrailingWhitespacePS: String {
        var s = Substring(self)
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
