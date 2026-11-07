// Sources/Beams/Services/TshClient+Phase.swift
import Foundation

/// A Phase image from `tsh phase ls -f json`. Verified 2026-11 row shape:
/// `{"name","owner","strategy","parent","state","region","roles"}`, where
/// `parent` is a reference like "default:v1" and `state` is e.g. "building".
/// Rows have no lock flag and no build beam.
struct BeamPhase: Identifiable, Hashable {
    var name: String
    /// The phase this one was built on, e.g. "default:v1".
    var parent: String = ""
    /// Other phases are built on it, so it takes no new snapshots (fork instead).
    var locked: Bool = false
    /// Every scalar field from the listing.
    var raw: [String: String] = [:]
    var id: String { name }

    var state: String { raw["state"] ?? "" }
    var isBuilding: Bool { state == "building" }

    /// JSON rows (flat, or Teleport-resource style). `null` parses to [].
    static func parse(_ json: Any) -> [BeamPhase] {
        let rows: [[String: Any]]
        if let a = json as? [[String: Any]] { rows = a }
        else if let d = json as? [String: Any], let a = (d["phases"] ?? d["items"]) as? [[String: Any]] { rows = a }
        else { return [] }
        let phases: [BeamPhase] = rows.compactMap { row in
            let flat = PhaseJSON.flatten(row)
            guard let name = flat["name"], !name.isEmpty else { return nil }
            let parent = flat["parent"] ?? flat["from"] ?? flat["base"] ?? ""
            let locked = ["true", "1", "yes"].contains((flat["locked"] ?? "").lowercased())
                || (flat["state"] ?? "").lowercased() == "locked"
            return BeamPhase(name: name, parent: parent, locked: locked, raw: flat)
        }
        return markLocked(phases)
    }

    /// Fallback for a plain-text table: header row, optional dashed separator, columns.
    static func parseTable(_ text: String) -> [BeamPhase] {
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let headers = lines.removeFirst().split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let nameCol = headers.firstIndex(of: "name") ?? 0
        let phases: [BeamPhase] = lines.compactMap { line in
            if line.allSatisfy({ $0 == "-" || $0 == " " }) { return nil }
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard nameCol < cols.count else { return nil }
            var raw: [String: String] = [:]
            for (i, h) in headers.enumerated() where i < cols.count { raw[h] = cols[i] }
            return BeamPhase(name: cols[nameCol], parent: raw["parent"] ?? raw["from"] ?? "",
                             locked: (raw["locked"] ?? raw["state"] ?? "").lowercased().hasPrefix("locked") || raw["locked"] == "true",
                             raw: raw)
        }
        return markLocked(phases)
    }

    /// A phase is locked once another phase is built on it.
    static func markLocked(_ phases: [BeamPhase]) -> [BeamPhase] {
        let parents = Set(phases.map(\.parent).filter { !$0.isEmpty })
        return phases.map { p in
            var p = p
            if parents.contains(p.name) { p.locked = true }
            return p
        }
    }

    /// A *new* phase name: letters, digits, `-_.`.
    static func safeName(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
    }

    /// An *existing* phase reference: "x", "default:v1" or "name@sha256:digest".
    static func safeRef(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@:".contains($0)) })
    }
}

/// `tsh phase add --no-console --format=json` output. Verified shape:
/// `{"name":"x", "parent":"default:v1", "state":"building",
///   "build_beam":"af775672-8eea-…", "region":"us-west-2", …}`.
/// `build_beam` is the build beam's uuid.
struct PhaseBuild: Hashable {
    var name: String
    var buildBeam: String
    var raw: [String: String] = [:]

    static func parse(_ data: Data, fallbackName: String) -> PhaseBuild? {
        guard let i = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try? JSONSerialization.jsonObject(with: data[i...]) as? [String: Any] else { return nil }
        let flat = PhaseJSON.flatten(obj)
        var beam = ""
        for key in ["build_beam", "buildBeam", "build_beam_id", "beam_id", "beam"] {
            if let s = obj[key] as? String, !s.isEmpty { beam = s; break }
            if let d = obj[key] as? [String: Any] {
                let f = PhaseJSON.flatten(d)
                beam = f["uuid"] ?? f["id"] ?? f["name"] ?? ""
                if !beam.isEmpty { break }
            }
        }
        return PhaseBuild(name: flat["name"] ?? fallbackName, buildBeam: beam, raw: flat)
    }
}

enum PhaseJSON {
    /// Top-level scalars plus those under metadata/spec/status.
    static func flatten(_ d: [String: Any]) -> [String: String] {
        var flat: [String: String] = [:]
        func absorb(_ d: [String: Any]) {
            for (k, v) in d {
                switch v {
                case let s as String: flat[k] = s
                case let n as NSNumber: flat[k] = n.stringValue
                default: break
                }
            }
        }
        absorb(d)
        for k in ["metadata", "spec", "status"] { if let sub = d[k] as? [String: Any] { absorb(sub) } }
        return flat
    }
}

struct PhaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// Heuristic until a real message is captured.
    static func isLocked(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("locked") || l.contains("has dependent") || l.contains("fork")
    }
}

/// Scripts run *inside* a build beam through `client.run`.
enum PhaseScripts {
    private static let needTsh = "command -v tsh >/dev/null || { echo 'beams: tsh not found in this beam' >&2; exit 127; }\n"

    /// Saves the build beam's /home to its phase. `final` also deletes the beam.
    static func snapshot(final: Bool = false) -> String {
        needTsh + "exec tsh phase snapshot" + (final ? " --final" : "") + " 2>&1\n"
    }

    /// Captures this build beam's filesystem as a new phase (the way out of a locked phase).
    static func fork(newName: String) -> String {
        needTsh + "exec tsh phase add \(Shell.quote(BeamPhase.safeName(newName))) --fork --no-console --format=json 2>&1\n"
    }
}

extension TshClient {
    /// Arguments after `tsh [--proxy=…]` for a headless `phase add`.
    static func phaseAddArgs(name: String, from: String = "", forkFrom: String = "", region: String = "") throws -> [String] {
        let n = BeamPhase.safeName(name)
        let f = BeamPhase.safeRef(from)
        let ff = BeamPhase.safeRef(forkFrom)
        if !f.isEmpty && !ff.isEmpty { throw PhaseError(message: "Choose either a base phase or a phase to fork, not both.") }
        var a = ["phase", "add"]
        if !f.isEmpty { a.append("--from=\(f)") }
        if !ff.isEmpty { a.append("--fork-from=\(ff)") }
        let r = region.trimmingCharacters(in: .whitespaces)
        if !r.isEmpty { a.append("--region=\(r)") }
        a += ["--no-console", "--format=json"]
        if !n.isEmpty { a.append(n) }   // omitted: tsh generates a name
        return a
    }

    /// Arguments after `tsh [--proxy=…]` for an ordinary beam started from a phase.
    static func beamAddArgs(phase: String, region: String = "") throws -> [String] {
        let p = BeamPhase.safeRef(phase)
        guard !p.isEmpty else { throw PhaseError(message: "Pick a phase to start the beam from.") }
        var a = ["beams", "add", "--no-console", "-f", "json", "--phase=\(p)"]
        let r = region.trimmingCharacters(in: .whitespaces)
        if !r.isEmpty { a.append("--region=\(r)") }
        return a
    }

    /// The `id` from `tsh beams add -f json` (log lines before the JSON are skipped).
    static func beamID(fromAddOutput data: Data) -> String? {
        guard let i = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try? JSONSerialization.jsonObject(with: data[i...]) as? [String: Any] else { return nil }
        let flat = PhaseJSON.flatten(obj)
        let id = flat["id"] ?? flat["uuid"] ?? flat["name"] ?? ""
        return id.isEmpty ? nil : id
    }

    /// `tsh phase add … --no-console --format=json`: provisions a build beam.
    func phaseAdd(name: String, from: String = "", forkFrom: String = "", region: String = "") async throws -> PhaseBuild {
        let args = try Self.phaseAddArgs(name: name, from: from, forkFrom: forkFrom, region: region)
        let res = try await Shell.run(phaseArgs(args), extraEnv: Self.env, timeout: 600)
        return PhaseBuild.parse(res.stdout, fallbackName: BeamPhase.safeName(name))
            ?? PhaseBuild(name: BeamPhase.safeName(name), buildBeam: "", raw: ["output": res.stdoutText])
    }

    /// `tsh beams add --no-console -f json --phase=<phase>`. Returns the beam id.
    func beamAddFromPhase(_ phase: String, region: String = "") async throws -> String {
        let args = try Self.beamAddArgs(phase: phase, region: region)
        let res = try await Shell.run(phaseArgs(args), extraEnv: Self.env, timeout: 180)
        guard let id = Self.beamID(fromAddOutput: res.stdout) else {
            throw PhaseError(message: "tsh beams add didn't return a beam id: \(res.stdoutText.prefix(200))")
        }
        return id
    }

    /// `tsh phase ls -f json`, falling back to the text table.
    /// An expired certificate makes tsh start a login, so callers check status first.
    func phaseList() async throws -> [BeamPhase] {
        let json = try await Shell.run(phaseArgs(["phase", "ls", "-f", "json"]), extraEnv: Self.env, timeout: 45, check: false)
        if json.ok, let i = json.stdout.firstIndex(where: { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "{") }),
           let obj = try? JSONSerialization.jsonObject(with: json.stdout[i...], options: [.fragmentsAllowed]) {
            return BeamPhase.parse(obj)
        }
        let text = try await Shell.run(phaseArgs(["phase", "ls"]), extraEnv: Self.env, timeout: 45)
        return BeamPhase.parseTable(text.stdoutText)
    }

    /// `tsh phase rm <name>`. Beams already using the phase keep running.
    func phaseRemove(_ name: String) async throws {
        let n = BeamPhase.safeRef(name)
        guard !n.isEmpty else { throw PhaseError(message: "Invalid phase name “\(name)”") }
        try await Shell.run(phaseArgs(["phase", "rm", n]), extraEnv: Self.env, timeout: 60)
    }

    /// `tsh phase apply -f <file>`: define phases in YAML, non-interactively.
    @discardableResult
    func phaseApply(file: URL) async throws -> String {
        try await Shell.run(phaseArgs(["phase", "apply", "-f", file.path]), extraEnv: Self.env, timeout: 600).stdoutText
    }

    private func phaseArgs(_ sub: [String]) -> [String] {
        var a = [bin]
        if !proxy.isEmpty { a.append("--proxy=\(proxy)") }
        return a + sub
    }
}
