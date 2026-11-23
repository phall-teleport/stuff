import Foundation

/// What this tsh's `beams add` can do beyond a region (beams.js `addSupport`).
struct BeamAddSupport: Equatable, Sendable {
    /// `beams add --phase` and `tsh phase ls`.
    var phases = false
    /// `beams add --roles`.
    var roles = false
    /// Newer than `tsh phase` itself: a multi-stage phase.yaml…
    var apply = false
    /// …copied files…
    var copy = false
    /// …and starting a build without opening its console.
    var noConsole = false

    var json: JSON {
        ["phases": .bool(phases), "roles": .bool(roles), "apply": .bool(apply), "copy": .bool(copy),
         "noConsole": .bool(noConsole)]
    }
}

/// One Phase: a saved, reusable image a beam can start from (`tsh phase ls`).
struct BeamPhase: Equatable, Hashable, Sendable, Identifiable {
    var name: String
    var state = ""
    var parent = ""
    var region = ""
    var digest = ""
    var owner = ""
    var strategy = ""
    var roles: [String] = []
    /// ms since the epoch.
    var publishedAt: Double?
    var nextBuild: Double?
    /// Why a build failed, and how to look inside what it left.
    var lastError = ""
    /// The build Beam of a build still running: where to save it from.
    var buildBeam = ""
    var id: String { name }
}

/// A build that failed, and the snapshot it left (`tsh phase ls-failed`).
struct FailedPhase: Equatable, Hashable, Sendable {
    var phase: String
    var digest = ""
    var at: Double?
    var expires: Double?
}

/// A service beam-init runs in a Beam (`beamctl --json list`).
struct BeamService: Equatable, Hashable, Sendable {
    var name: String
    var status: String
    var state = ""
}

/// A file copied into a Phase build: local `from`, Beam path `to`.
struct PhaseCopy: Equatable, Sendable {
    var from: String
    var to: String
}

/// The beams.js Phase plumbing (`addSupport`, `phases`, `failedPhases`,
/// `removePhase`, `phaseAddArgs`, `phaseEditArgs`, `phaseApplyArgs`,
/// `copyFlags`, `startNonInteractive`, `phaseSnapshot`, `beamServices`,
/// `servicesFrom`, `beamServiceLogs`) and the renderer's beams-by-name rule.
/// The Phase UI and phasesetup.js are the phases owner's.
extension Beams {
    // MARK: - Beams by name

    /// `BEAMS_DOMAINS`: the hosted Beams service's own clusters.
    static let beamsDomains = #"(^|\.)beams\.(sh|run)$"#

    /// `beamsByName`: a cluster on beams.sh / beams.run is a beams cluster
    /// without anyone having to say so (the scheme, path and port are ignored).
    static func beamsByName(_ proxy: String?) -> Bool {
        let host = (proxy ?? "").trimmed
            .replacingOccurrences(of: #"^[a-z][a-z0-9+.-]*://"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
        return !host.isEmpty && TPText.test(beamsDomains, host, .caseInsensitive)
    }

    // MARK: - What this tsh can do

    private static let addSupportCache = TPLocked<[String: BeamAddSupport]>([:])

    /// The pure half of `addSupport`: the three help texts, read.
    /// `--help` exits non-zero on some builds, so the text is read rather than the code.
    static func parseAddSupport(addHelp: String, phaseHelp: String, phaseHelpStderr: String, phaseAddHelp: String) -> BeamAddSupport {
        let help = TPText.plain(addHelp)
        let phaseText = TPText.plain(phaseHelp)
        let phaseAddText = TPText.plain(phaseAddHelp)
        return BeamAddSupport(
            phases: TPText.test(#"--phase[=\s]"#, help) && TPText.test(#"\bls\b"#, phaseText)
                && !TPText.test(#"expected command but got "phase""#, TPText.plain(phaseHelpStderr)),
            roles: TPText.test(#"--roles[=\s]"#, help),
            apply: TPText.test(#"\bphase apply\b"#, phaseText),
            copy: TPText.test(#"--copy[=\s]"#, phaseAddText),
            noConsole: TPText.test(#"--\[no-\]console|--no-console"#, phaseAddText))
    }

    /// `addSupport`: whether this tsh's `beams add` can start from a Phase
    /// and delegate roles — both newer than beams. v18's tsh lists and starts
    /// beams but has neither `tsh phase`, `beams add --phase` nor `--roles`,
    /// and offering a choice it cannot act on ends in "unknown flag" after the
    /// person has already picked. So each is asked of the binary itself, from
    /// its own help, which needs no cluster and no login. Kept per tsh binary
    /// and per the variables it runs with: TELEPORT_TOOLS_VERSION set for a
    /// cluster makes the same tsh another version for that cluster.
    static func addSupport(proxy: String?, home: String?) async -> BeamAddSupport {
        let key = "\(Tools.tsh)|\(TshEnv.key(TshEnv.envFor(proxy)))"
        if let hit = addSupportCache.get()[key] { return hit }
        // A tsh that cannot be run at all answers "no" to everything.
        async let a = Teleport.run(base(proxy: proxy) + ["beams", "add", "--help"], home: home, timeout: 60)
        async let p = Teleport.run(base(proxy: proxy) + ["phase", "--help"], home: home, timeout: 60)
        async let pa = Teleport.run(base(proxy: proxy) + ["phase", "add", "--help"], home: home, timeout: 60)
        let (addHelp, phaseHelp, phaseAddHelp) = await (a, p, pa)
        let answer = parseAddSupport(addHelp: addHelp.out + addHelp.err, phaseHelp: phaseHelp.out + phaseHelp.err,
                                     phaseHelpStderr: phaseHelp.err, phaseAddHelp: phaseAddHelp.out + phaseAddHelp.err)
        addSupportCache.mutate { $0[key] = answer }
        return answer
    }

    /// Forget what each tsh said (a different tsh was chosen, or variables changed).
    static func forgetAddSupport() { addSupportCache.set([:]) }

    // MARK: - Phases

    static func parsePhases(_ text: String) -> [BeamPhase]? {
        let out = TPText.plain(text)
        guard let at = out.firstIndex(of: "["), let data = try? JSON.parse(String(out[at...])), let arr = data.array
        else { return nil }
        return arr.map { p in
            BeamPhase(name: p["name"].stringish ?? "", state: p["state"].stringish ?? "",
                      parent: p["parent"].stringish ?? "", region: p["region"].stringish ?? "",
                      digest: p["image_digest"].stringish ?? "", owner: p["owner"].stringish ?? "",
                      strategy: p["strategy"].stringish ?? "", roles: p["roles"].items.compactMap(\.stringish),
                      publishedAt: TPText.parseDate(p["published_at"].string),
                      nextBuild: TPText.parseDate(p["next_build"].string),
                      lastError: p["last_error"].stringish ?? "", buildBeam: p["build_beam"].stringish ?? "")
        }.filter { !$0.name.isEmpty }
    }

    /// `phases`: the Phases this login can start a beam from (`tsh phase ls`).
    static func phases(proxy: String?, home: String?) async -> TshList<BeamPhase> {
        let r = await Teleport.run(base(proxy: proxy) + ["phase", "ls", "--format=json"], home: home, timeout: 45)
        if let list = parsePhases(r.out) { return TshList(ok: true, error: nil, items: list) }
        let e = TPText.plain(r.err), out = TPText.plain(r.out)
        return .failed(!e.isEmpty ? e : (!out.isEmpty ? out : (r.spawnError ?? "Could not read the Phase list")))
    }

    static func parseFailed(_ text: String) -> [FailedPhase]? {
        let out = TPText.plain(text)
        guard let at = out.firstIndex(of: "["), let data = try? JSON.parse(String(out[at...])), let arr = data.array
        else { return nil }
        return arr.map { f in
            FailedPhase(phase: f["phase"].stringish ?? "", digest: f["digest"].stringish ?? "",
                        at: TPText.parseDate(f["timestamp"].string), expires: TPText.parseDate(f["expiration"].string))
        }.filter { !$0.phase.isEmpty }
    }

    /// `failedPhases`: builds that failed, and the snapshot each left.
    static func failedPhases(proxy: String?, home: String?) async -> TshList<FailedPhase> {
        let r = await Teleport.run(base(proxy: proxy) + ["phase", "ls-failed", "--format=json"], home: home, timeout: 45)
        if let list = parseFailed(r.out) { return TshList(ok: true, error: nil, items: list) }
        let e = TPText.plain(r.err), out = TPText.plain(r.out)
        return .failed(!e.isEmpty ? e : (!out.isEmpty ? out : (r.spawnError ?? "Could not read the failed builds")))
    }

    /// `removePhase`: `tsh phase rm`, which asks nothing of its own — the app
    /// asks first. Beams already started from it keep running; it is the
    /// image that goes, and what is built from it next.
    static func removePhase(name: String, proxy: String?, home: String?) async throws -> TshOutput {
        if name.isEmpty { throw AppError("Which Phase?") }
        let r = await Teleport.run(base(proxy: proxy) + ["phase", "rm", name], home: home, timeout: 120)
        if let e = r.spawnError, r.out.isEmpty, r.err.isEmpty { return TshOutput(ok: false, output: e) }
        return TshOutput(ok: r.ok, output: TPText.plain(r.out + "\n" + r.err))
    }

    // MARK: - Build argv (run in a terminal tab)

    /// `copyFlags`: `--copy=<destination>:<local source>`, once per file.
    /// tsh writes the destination first, which reads backwards next to
    /// everything else, so callers pass from/to and this spells it.
    static func copyFlags(_ copies: [PhaseCopy]) throws -> [String] {
        try copies.filter { !$0.from.isEmpty || !$0.to.isEmpty }.map { c in
            let to = c.to.trimmed, from = c.from.trimmed
            if !to.hasPrefix("/") {
                throw AppError("Where in the Beam should \(from.isEmpty ? "it" : from) go? An absolute path, outside /home")
            }
            if to == "/home" || to.hasPrefix("/home/") { throw AppError("\(to): copied files go outside /home") }
            if from.isEmpty { throw AppError("Which local file goes to \(to)?") }
            return "--copy=\(to):\(from)"
        }
    }

    /// `phaseAddArgs`: `tsh phase add`. It opens an interactive build console
    /// — a shell on a build beam, finished with `tsh phase snapshot --final` —
    /// so it is run in a terminal tab; this only says what to run. `from`
    /// builds on another Phase as the base image; `forkFrom` starts from
    /// another Phase's last saved files (never both); `roles` limits what the
    /// builds may act as, and is otherwise inherited.
    static func phaseAddArgs(proxy: String?, name: String? = nil, from: String? = nil, forkFrom: String? = nil,
                             commandsFile: String? = nil, copies: [PhaseCopy] = [], noConsole: Bool = false,
                             roles: [String] = [], region: String? = nil) throws -> [String] {
        let from = from?.nilIfEmpty, forkFrom = forkFrom?.nilIfEmpty, commandsFile = commandsFile?.nilIfEmpty
        if from != nil && forkFrom != nil { throw AppError("Build on a Phase or fork one — not both") }
        if forkFrom != nil && commandsFile != nil { throw AppError("A fork starts from saved files — it takes no command file") }
        let copyArgs = try copyFlags(copies)
        if !copyArgs.isEmpty && (commandsFile != nil || forkFrom != nil) {
            throw AppError("Copied files make a Phase of their own — not with a command file or a fork")
        }
        var args = base(proxy: proxy) + ["phase", "add"]
        if let n = name?.nilIfEmpty { args.append(n) }
        if let f = from { args.append("--from=" + f) }
        if let f = forkFrom { args.append("--fork-from=" + f) }
        if let c = commandsFile { args.append("--commands-file=" + c) }
        args += copyArgs
        if noConsole { args += ["--no-console", "--format=json"] }
        if !roles.isEmpty { args.append("--roles=" + roles.joined(separator: ",")) }
        if let r = region?.nilIfEmpty { args.append("--region=" + r) }
        return args
    }

    /// `phaseEditArgs`: `tsh phase edit` — a build console on its saved
    /// files, or for a Phase built from commands or copied files, those replaced.
    static func phaseEditArgs(proxy: String?, name: String, from: String? = nil, commandsFile: String? = nil,
                              copies: [PhaseCopy] = [], noConsole: Bool = false, region: String? = nil) throws -> [String] {
        if name.isEmpty { throw AppError("Which Phase?") }
        let from = from?.nilIfEmpty, commandsFile = commandsFile?.nilIfEmpty
        let copyArgs = try copyFlags(copies)
        if commandsFile != nil && !copyArgs.isEmpty { throw AppError("A command file or copied files — not both") }
        if from != nil && (commandsFile != nil || !copyArgs.isEmpty) {
            throw AppError("Editing from another Phase takes no command file or copies")
        }
        var args = base(proxy: proxy) + ["phase", "edit", name]
        if let f = from { args.append("--from=" + f) }
        if let c = commandsFile { args.append("--commands-file=" + c) }
        args += copyArgs
        if noConsole { args.append("--no-console") }
        if let r = region?.nilIfEmpty { args.append("--region=" + r) }
        return args
    }

    /// `phaseApplyArgs`: `tsh phase apply -f`, every stage of a phase.yaml in
    /// order. It opens no console but streams each stage's log, so it still
    /// runs in a terminal tab.
    static func phaseApplyArgs(proxy: String?, file: String, noConsole: Bool = false, region: String? = nil) throws -> [String] {
        if file.isEmpty { throw AppError("Which phase.yaml?") }
        var args = base(proxy: proxy) + ["phase", "apply", "--file=" + file]
        if noConsole { args.append("--no-console") }
        if let r = region?.nilIfEmpty { args.append("--region=" + r) }
        return args
    }

    /// `startNonInteractive`: run a `--no-console` build argv here and read
    /// the JSON tsh prints once the build Beam is up.
    static func startNonInteractive(_ args: [String], home: String?) async -> (ok: Bool, buildBeam: String, name: String, raw: JSON, error: String?) {
        let r = await Teleport.run(args, home: home, timeout: 300)
        let out = TPText.plain(r.out)
        if let at = out.firstIndex(of: "{"), let data = try? JSON.parse(String(out[at...])) {
            return (true, data["build_beam"].stringish ?? "", data["name"].stringish ?? "", data, nil)
        }
        let e = TPText.plain(r.err)
        return (false, "", "", .null, !e.isEmpty ? e : (!out.isEmpty ? out : "tsh phase add/edit returned nothing to read"))
    }

    /// `phaseSnapshot`: save a running build — `tsh phase snapshot` inside its
    /// build Beam, through `beams exec`. `final` ends the build once saved;
    /// `force` leaves out changes outside /home instead of refusing them.
    /// --final ends the Beam it ran in, which can cut the exec off before it
    /// reports: the Phase list says whether it was saved, not this exit code.
    static func phaseSnapshot(beam: String, proxy: String?, home: String?, final: Bool = false,
                              force: Bool = false) async throws -> TshOutput {
        if beam.isEmpty { throw AppError("Which build Beam?") }
        let cmd = ["tsh", "phase", "snapshot", force ? "--force" : "", final ? "--final" : ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let r = await Teleport.run(argsFor("exec", [beam, "--", cmd], proxy: proxy), home: home, timeout: 15 * 60)
        if let e = r.spawnError, r.out.isEmpty, r.err.isEmpty { return TshOutput(ok: false, output: e) }
        return TshOutput(ok: r.ok, output: TPText.plain(r.out + "\n" + r.err).trimmed)
    }

    /// `servicesFrom`: `beamctl --json list` is a map of name to its one
    /// state — `{"web":{"running":{"main_pid":165}},"init":{"exited":{"code":0}}}`
    /// — said here as a name and a few words.
    static func servicesFrom(_ data: JSON) -> [BeamService] {
        if let arr = data.array {
            return arr.map { BeamService(name: $0["name"].stringish ?? "",
                                         status: $0["status"].stringish?.nilIfEmpty ?? $0["state"].stringish ?? "") }
        }
        return data.entries.map { name, st -> BeamService in
            let first = st.entries.sorted { $0.key < $1.key }.first
            let state = first?.key ?? "unknown"
            let detail = first?.value ?? .object([:])
            var status = state
            if state == "running", detail["main_pid"].truthy, let pid = detail["main_pid"].stringish {
                status = "running (pid \(pid))"
            } else if state == "exited", detail.object?["code"] != nil {
                let code = detail["code"]
                status = code == .number(0) ? "finished" : "exited with \(code.stringish ?? code.text())"
            } else if let reason = detail["reason"].stringish, detail["reason"].truthy {
                status = "\(state): \(reason)"
            }
            return BeamService(name: name, status: status, state: state)
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// `beamServices`: the services beam-init runs in a Beam — what a Phase's
    /// `services:` became.
    static func beamServices(name: String, proxy: String?, home: String?) async throws -> TshList<BeamService> {
        if name.isEmpty { throw AppError("Which beam?") }
        let r = await Teleport.run(argsFor("exec", [name, "--", "beamctl --json list"], proxy: proxy), home: home, timeout: 60)
        let out = TPText.plain(r.out)
        if r.ok, let at = out.firstIndex(where: { $0 == "[" || $0 == "{" }), let data = try? JSON.parse(String(out[at...])) {
            return TshList(ok: true, error: nil, items: servicesFrom(data))
        }
        let e = TPText.plain(r.err.isEmpty ? (r.spawnError ?? "") : r.err)
        return .failed(!e.isEmpty ? e : (!out.isEmpty ? out : "beamctl list said nothing"))
    }

    /// `beamServiceLogs`: one service's log so far (`beamctl logs <service>`).
    static func beamServiceLogs(name: String, service: String, proxy: String?, home: String?) async throws -> TshOutput {
        if name.isEmpty || service.isEmpty { throw AppError("Which beam and service?") }
        if !TPText.test(#"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, service) { throw AppError("Not a service name") }
        let r = await Teleport.run(argsFor("exec", [name, "--", "beamctl logs \(service)"], proxy: proxy), home: home, timeout: 60)
        return TshOutput(ok: r.ok, output: TPText.plain(r.out + (r.ok ? "" : "\n" + (r.err.isEmpty ? (r.spawnError ?? "") : r.err))).trimmed)
    }
}
