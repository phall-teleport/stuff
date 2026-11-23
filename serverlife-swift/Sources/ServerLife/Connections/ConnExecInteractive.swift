import Foundation

/// `execInteractive`'s answer.
struct InteractiveExecResult: Sendable {
    var execId: String
    /// Everything the pty printed (last 2 MB).
    var stdout: String
    /// nil when it timed out.
    var exitCode: Int32?
    var error: String?
}

/// `teleportPresence`: whether a directly reached box already runs Teleport.
struct TeleportPresence: Sendable, Equatable {
    var installed: Bool
    var running: Bool
    var checkedAt: Double

    var json: JSON { ["installed": .bool(installed), "running": .bool(running), "checkedAt": .number(checkedAt)] }
}

/// `hostSockets`' answer, unparsed: the rows are sockets.js `parseRemote(tool,
/// text)`, which belongs with the sockets view ([nettools]).
struct HostSocketsRaw: Sendable {
    var ok: Bool
    var text: String
    /// "ss" or "netstat"; nil when neither is installed.
    var tool: String?
    var command: String
    /// The tool to install when `ok` is false.
    var missing: String?
}

nonisolated(unsafe) private var execSeq = 0

extension Connection {
    /// A one-off command on the `tsh` transport that can prompt — per-session
    /// MFA, the same ceremony the interactive master surfaces. `exec` has no
    /// pty and no stdin, so a prompt had nowhere to appear or be answered.
    /// A parallel path, not a replacement: single-command and multi-exec use
    /// it only for the tsh transport; `serverInfo`, `hostTools` … keep exec's
    /// clean stdout. On a host that never prompts, the prompt pattern just
    /// never matches and this behaves as a plain run.
    ///
    /// Output goes out as `.execData`, prompts as `.execPrompt`; answer with
    /// `writeExec`, stop with `killExec`.
    func execInteractive(_ command: String, timeout: TimeInterval = 20, execId: String? = nil) async -> InteractiveExecResult {
        let eid: String
        if let execId { eid = execId } else { execSeq += 1; eid = "exec\(execSeq)" }
        let p: PTYProcess
        do {
            p = try PTYProcess(exe: Tools.tsh, args: tshArgs([], command: command), env: procEnv(["TERM": "xterm-256color"]),
                               cwd: NSHomeDirectory(), cols: 100, rows: 30)
        } catch {
            let msg = (error as? AppError)?.message ?? error.localizedDescription
            return InteractiveExecResult(execId: eid, stdout: "", exitCode: nil, error: msg)
        }
        execs[eid] = p
        let connId = id
        return await withCheckedContinuation { (cont: CheckedContinuation<InteractiveExecResult, Never>) in
            var out = ""
            var timedOut = false
            let timer = DispatchWorkItem { timedOut = true; p.terminate(grace: 0.5) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
            p.onData = { [weak self] d in
                MainActor.assumeIsolated {
                    let s = String(decoding: d, as: UTF8.self)
                    out += s
                    if out.utf8.count > 2_000_000 { out = String(out.suffix(2_000_000)) }
                    self?.onEvent?(.execData(id: connId, execId: eid, data: s))
                    if ConnText.isPrompt(s) { self?.onEvent?(.execPrompt(id: connId, execId: eid, text: s)) }
                }
            }
            p.onExit = { [weak self] code in
                MainActor.assumeIsolated {
                    timer.cancel()
                    if self?.execs[eid] === p { self?.execs[eid] = nil }
                    let exit = code
                    let err: String? = timedOut
                        ? "Timed out waiting for the command, or for an answer to a prompt."
                        : (exit == 0 ? nil : (ConnText.cleanupError(out) ?? "exited \(exit)"))
                    cont.resume(returning: InteractiveExecResult(execId: eid, stdout: out,
                                                                exitCode: timedOut ? nil : exit, error: err))
                }
            }
        }
    }

    /// Answer a prompt `execInteractive` raised — an MFA code, a tap confirmed.
    func writeExec(_ execId: String, _ data: String) { execs[execId]?.write(data) }

    /// Stop a still-running interactive exec — a cancelled run, a closed dialog.
    func killExec(_ execId: String) {
        guard let p = execs[execId] else { return }
        p.terminate(grace: 0.5)
        execs[execId] = nil
    }

    /// `teleportPresence`: whether this box already runs Teleport — asked
    /// only of a direct connection, where the answer is a genuine "did you
    /// know". One round trip, cached for the life of the connection.
    func teleportPresence(refresh: Bool = false) async -> TeleportPresence {
        if let c = teleportPresenceCache, !refresh { return c }
        let script = "command -v teleport >/dev/null 2>&1 && echo bin=yes || echo bin=no; "
            + "pgrep -x teleport >/dev/null 2>&1 && echo running=yes || echo running=no"
        let text = await execResult(script, timeout: 10).out
        let p = TeleportPresence(installed: text.contains("bin=yes"), running: text.contains("running=yes"),
                                 checkedAt: nowMs())
        teleportPresenceCache = p
        return p
    }

    /// `hostSockets`: what is listening, and what is connected, on the host —
    /// `ss` first, `netstat` as the fallback.
    func hostSockets() async -> HostSocketsRaw {
        let caps = try? await hostTools()
        let tool: String? = caps?.has("ss") == true ? "ss" : caps?.has("netstat") == true ? "netstat" : nil
        guard let tool else { return HostSocketsRaw(ok: false, text: "", tool: nil, command: "ss -tulpn", missing: "ss") }
        let text: String
        do { text = try await exec("LC_ALL=C; \(tool) -tulpn 2>&1", timeout: 15, keepOutput: true) } catch {
            text = (error as? AppError)?.message ?? error.localizedDescription
        }
        return HostSocketsRaw(ok: true, text: text.trimmed, tool: tool, command: "\(tool) -tulpn", missing: nil)
    }
}
