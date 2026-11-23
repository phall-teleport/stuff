import AppKit
import SwiftUI

/// The commands "Run a command…" has actually run, most recent first — not a
/// Snippet: nothing here was named or kept on purpose, it is just what was
/// typed before, like a shell's history. Capped and deduplicated.
enum SBCommandHistory {
    static let max = 25

    @MainActor static var list: [String] {
        SB.store.settingJSON("commandHistory").array?.compactMap(\.string) ?? []
    }

    @MainActor static func remember(_ cmd: String) {
        let next = Array(([cmd] + list.filter { $0 != cmd }).prefix(max))
        SB.store.setSetting("commandHistory", next)
    }

    /// The menu label: the first line only, so a long script does not blow out the list.
    nonisolated static func label(_ c: String) -> String {
        let first = c.components(separatedBy: "\n")[0]
        return String(first.prefix(60)) + (c.count > 60 || c.contains("\n") ? "…" : "")
    }
}

@MainActor
final class RunCommandModel: ObservableObject {
    let host: Host
    let login: String?
    let logins: [String]
    private var id: String?
    /// The session open now: the one asked for, else any connected to this host.
    private let openConn: Connection?
    @Published var command: String
    @Published var runAs: String
    @Published var output = "Output appears here."
    @Published var failed = false
    @Published var meta = ""
    /// The last line of a prompt a tsh-transport exec is waiting on; nil when none.
    @Published var prompt: String?
    @Published var answer = ""
    private var running = false
    private var lastOutput = ""
    /// Set only while a tsh-transport exec waits on an answer (per-session MFA).
    private var activeExecId: String?
    private var token: UUID?

    init(host: Host, login: String?, logins: [String], connId: String?, command: String) {
        self.host = host; self.login = login; self.logins = logins; self.id = connId; self.command = command
        let cm = ConnectionManager.shared
        openConn = connId.flatMap { cm.connection($0) }
            ?? cm.connections.first { $0.hostId == host.id && $0.state == .connected }
        runAs = openConn?.login ?? login ?? ""
        token = cm.subscribe { [weak self] e in
            guard let self, case .execPrompt(_, let execId, let text) = e, execId == self.activeExecId else { return }
            self.prompt = text.trimmed.components(separatedBy: "\n").filter { !$0.isEmpty }.last ?? "Waiting for a response…"
        }
    }

    /// Who it can run as, for the field's suggestions.
    var loginChoices: [String] {
        var seen = Set<String>()
        return ([openConn?.login ?? login] + logins.map { Optional($0) })
            .compactMap { $0?.nilIfEmpty }.filter { seen.insert($0).inserted }
    }

    var runAsNote: String {
        let who = runAs.trimmed
        let conn = id.flatMap { ConnectionManager.shared.connection($0) } ?? openConn
        if who.isEmpty { return "Runs as the host\u{2019}s default login." }
        if conn?.login == who { return "Runs as \(who), over the session already open." }
        return "Runs as \(who)" + (conn?.login.map { " — a new connection; the open session is \($0)" } ?? "") + "."
    }

    func answerPrompt() {
        guard let eid = activeExecId, let id, let c = ConnectionManager.shared.connection(id) else { return }
        c.writeExec(eid, answer + "\n")
        answer = ""
    }

    func closed() {
        if let token { ConnectionManager.shared.unsubscribe(token) }
        token = nil
        // Closed mid-prompt: stop the tsh process waiting on an answer never coming.
        if let eid = activeExecId, let id { ConnectionManager.shared.connection(id)?.killExec(eid) }
    }

    func run() {
        let cmd = command.trimmed
        if cmd.isEmpty { SBActions.toast("Enter a command", .error); return }
        if running { return }
        running = true
        SBCommandHistory.remember(cmd)
        output = "Running…"; failed = false; meta = ""; prompt = nil
        let t0 = nowMs()
        Task { @MainActor in
            defer { self.running = false; self.activeExecId = nil; self.prompt = nil }
            let cm = ConnectionManager.shared
            do {
                let who = runAs.trimmed.nilIfEmpty ?? login
                let cur = id.flatMap { cm.connection($0) }
                // The open connection only if it is the account asked for.
                if cur == nil || (who != nil && cur?.login != nil && cur?.login != who) {
                    let reuse = who == nil || openConn?.login == who
                    id = try await SBHostActions.ensureConnection(host, login: who, fresh: !reuse)
                }
                guard let cid = id, let conn = cm.connection(cid) else { throw AppError("Not connected") }
                meta = "Running as \(conn.login ?? who ?? "the default login")…"
                var out: String
                var fail: String?
                if conn.transport == .tsh {
                    // Per-session MFA: exec has no pty for the prompt, so this
                    // goes through the interactive exec; the prompt row answers it.
                    let eid = "rc\(Int(nowMs()))"
                    activeExecId = eid
                    let r = await conn.execInteractive(cmd, execId: eid)
                    activeExecId = nil; prompt = nil
                    out = r.stdout
                    if r.exitCode != 0 { fail = r.error?.trimmed.nilIfEmpty ?? "exited \(r.exitCode.map(String.init) ?? "?")" }
                } else {
                    out = try await cm.exec(cid, cmd).stdout
                }
                let shown = fail.map { out.trimmed.isEmpty ? $0 : "\(out.trimmed)\n\n\($0)" }
                lastOutput = shown ?? out
                output = shown ?? (out.trimmed.nilIfEmpty ?? "(no output)")
                failed = fail != nil
                meta = fail != nil ? "Failed after \(Fmt.duration(ms: nowMs() - t0))"
                    : "As \(cm.connection(cid)?.login ?? "the default login") · finished in \(Fmt.duration(ms: nowMs() - t0)) · \(out.utf8.count) bytes"
            } catch {
                // A non-zero exit arrives here too; the message is the server's stderr.
                let msg = (error as? AppError)?.message ?? error.localizedDescription
                lastOutput = msg
                output = msg.nilIfEmpty ?? "Command failed"
                failed = true
                meta = "Failed after \(Fmt.duration(ms: nowMs() - t0))"
            }
        }
    }

    func copyOutput() {
        if lastOutput.isEmpty { SBActions.toast("Nothing to copy yet", .info); return }
        Clipboard.write(lastOutput)
        SBActions.status("Output copied")
    }
}
