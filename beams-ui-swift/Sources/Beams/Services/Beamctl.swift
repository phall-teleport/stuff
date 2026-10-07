import Foundation

/// A service managed by beam-init in a beam (`beamctl --json list`). Beams
/// created since 2026-10 run beam-init as PID 1; older beams have no beamctl.
struct BeamService: Identifiable, Hashable {
    var name: String
    /// Stopped, Running, Frozen, Restarting, Stopping, Exited, Error.
    var state: String
    var pid: Int?
    var hasPTY: Bool
    /// Exit status or error text, when there is one.
    var detail: String
    var id: String { name }

    var isLive: Bool { ["Running", "Frozen", "Restarting", "Stopping"].contains(state) }

    var label: String {
        var s = state.lowercased()
        if let pid { s += " · pid \(pid)" }
        if hasPTY { s += " · pty" }
        if !detail.isEmpty { s += " · \(detail)" }
        return s
    }
}

enum Beamctl {
    /// Printed by `listScript` when the beam has no beamctl (pre-beam-init).
    static let missingMarker = "__BEAMS_NO_BEAMCTL__"

    static let listScript = "command -v beamctl >/dev/null 2>&1 || { echo \(missingMarker); exit 0; }\nbeamctl --json list\n"

    /// Snapshot, or (follow) the snapshot then new output until stopped.
    static func logsScript(_ name: String, follow: Bool) -> String {
        "exec beamctl logs \(Shell.quote(name))\(follow ? " --follow" : "")\n"
    }

    /// restart / stop / freeze / thaw.
    static func actionScript(_ action: String, _ name: String) -> String? {
        guard ["restart", "stop", "freeze", "thaw"].contains(action) else { return nil }
        return "beamctl \(action) \(Shell.quote(name))\n"
    }

    /// Parses `beamctl --json list`: `{"name": status}` where status is
    /// `"Stopped"` or `{"Running": {"main_pid": 303, "pty": null}}`,
    /// `{"Exited": …}`, `{"Error": "…"}` and so on (beam-init-api ServiceStatus).
    /// nil = not JSON (e.g. the missing-beamctl marker).
    static func parseList(_ data: Data) -> [BeamService]? {
        guard let i = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try? JSONSerialization.jsonObject(with: data[i...]) as? [String: Any] else { return nil }
        return obj.map { name, status in service(name, status) }.sorted { $0.name < $1.name }
    }

    static func service(_ name: String, _ status: Any) -> BeamService {
        if let s = status as? String { return BeamService(name: name, state: s, pid: nil, hasPTY: false, detail: "") }
        guard let d = status as? [String: Any], let (state, body) = d.first else {
            return BeamService(name: name, state: "Unknown", pid: nil, hasPTY: false, detail: "")
        }
        var pid: Int?, pty = false, detail = ""
        if let b = body as? [String: Any] {
            pid = b["main_pid"] as? Int
            if let p = b["pty"], !(p is NSNull) { pty = true }
        } else if let s = body as? String {
            detail = s
        } else if let n = body as? Int {
            detail = "exit \(n)"
        } else if !(body is NSNull) {
            detail = String(describing: body)
        }
        return BeamService(name: name, state: state, pid: pid, hasPTY: pty, detail: detail)
    }
}
