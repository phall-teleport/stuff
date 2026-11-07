// TshClient+Phase.swift
import Foundation

/// A Phase image from `tsh phase ls`: a saved /home snapshot that new beams can start from.
struct BeamPhase: Identifiable, Hashable {
    var name: String
    /// The phase this one was built on (`--from`), if reported.
    var parent: String = ""
    /// True once other phases are built on it; snapshots then need a fork.
    var locked: Bool = false
    /// Every scalar field from the listing, for display and later mapping.
    var raw: [String: String] = [:]
    var id: String { name }

    /// JSON rows, either Teleport-resource style (`metadata.name`, `spec.*`)
    /// or flat. `null` or no rows parses to [].
    static func parse(_ json: Any) -> [BeamPhase] {
        let rows: [[String: Any]]
        if let a = json as? [[String: Any]] { rows = a }
        else if let d = json as? [String: Any], let a = (d["phases"] ?? d["items"]) as? [[String: Any]] { rows = a }
        else { return [] }
        return rows.compactMap { row in
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
            absorb(row)
            if let m = row["metadata"] as? [String: Any] { absorb(m) }
            if let s = row["spec"] as? [String: Any] { absorb(s) }
            if let s = row["status"] as? [String: Any] { absorb(s) }
            guard let name = flat["name"], !name.isEmpty else { return nil }
            let parent = flat["from"] ?? flat["parent"] ?? flat["base"] ?? ""
            let locked = ["true", "1", "yes"].contains((flat["locked"] ?? "").lowercased())
                || (flat["state"] ?? flat["status"] ?? "").lowercased() == "locked"
            return BeamPhase(name: name, parent: parent, locked: locked, raw: flat)
        }
    }

    /// Fallback for a plain-text table: a header row, an optional dashed
    /// separator, then whitespace-separated columns. The name is the "Name"
    /// column, or the first one.
    static func parseTable(_ text: String) -> [BeamPhase] {
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let headers = lines.removeFirst().split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let nameCol = headers.firstIndex(of: "name") ?? 0
        return lines.compactMap { line in
            if line.allSatisfy({ $0 == "-" || $0 == " " }) { return nil }
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard nameCol < cols.count else { return nil }
            var raw: [String: String] = [:]
            for (i, h) in headers.enumerated() where i < cols.count { raw[h] = cols[i] }
            return BeamPhase(name: cols[nameCol], parent: raw["from"] ?? raw["parent"] ?? "",
                             locked: (raw["locked"] ?? raw["state"] ?? "").lowercased().hasPrefix("locked") || raw["locked"] == "true",
                             raw: raw)
        }
    }

    /// Phase names as Teleport resource names: letters, digits, `-_.`.
    static func safeName(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
    }
}

struct PhaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// Heuristic until a real error message is captured: a snapshot to a
    /// phase that has children fails, and the fix is `--fork-from`.
    static func isLocked(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("locked") || l.contains("has dependent") || l.contains("fork")
    }
}

/// Scripts run *inside* the beam through `client.run`.
enum PhaseScripts {
    /// Saves the beam's /home to the phase it was created from. `final`
    /// also deletes the beam, so the caller should drop the beam afterwards.
    static func snapshot(final: Bool = false) -> String {
        "command -v tsh >/dev/null || { echo 'beams: tsh not found in this beam' >&2; exit 127; }\n"
            + "exec tsh phase snapshot" + (final ? " --final" : "") + " 2>&1\n"
    }
}

extension TshClient {
    /// `tsh phase ls`, as JSON when supported, otherwise the text table.
    /// Like `mcpList`, an expired certificate makes tsh start a login, so
    /// callers check status first.
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
        let n = BeamPhase.safeName(name)
        guard !n.isEmpty else { throw PhaseError(message: "Invalid phase name “\(name)”") }
        try await Shell.run(phaseArgs(["phase", "rm", n]), extraEnv: Self.env, timeout: 60)
    }

    /// `tsh phase apply -f <file>`: the non-interactive way to create or change phases.
    @discardableResult
    func phaseApply(file: URL) async throws -> String {
        let res = try await Shell.run(phaseArgs(["phase", "apply", "-f", file.path]), extraEnv: Self.env, timeout: 600)
        return res.stdoutText
    }

    private func phaseArgs(_ sub: [String]) -> [String] {
        var a = [bin]
        if !proxy.isEmpty { a.append("--proxy=\(proxy)") }
        return a + sub
    }
}
