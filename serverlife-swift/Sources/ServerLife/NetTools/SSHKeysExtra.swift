import Foundation

/// 0.39 additions to SSHKeys (sshkeys.js): FIDO2 security-key generation on a
/// pty, and known_hosts across every file a host uses.
extension SSHKeys {
    /// `ssh-keygen -t *-sk` asks for the security key's PIN on its terminal
    /// and waits for a touch, so it runs on a pty like ssh-add does.
    @MainActor
    static func generateSecurityKey(_ args: [String], pin: String?) async -> Run {
        guard Tools.toolAvailable("ssh-keygen") else {
            return Run(ok: false, stdout: "ssh-keygen was not found on this machine.", stderr: "", code: -1, missing: true)
        }
        let term: PTYProcess
        do {
            term = try PTYProcess(exe: Tools.tool("ssh-keygen"), args: args)
        } catch {
            return Run(ok: false, stdout: "Could not run ssh-keygen: \(error.localizedDescription)", stderr: "", code: -1, missing: false)
        }
        return await withCheckedContinuation { cont in
            var out = ""
            var fresh = ""
            var pinSent = false
            var settled = false
            let finish: (Bool, String?) -> Void = { ok, extra in
                guard !settled else { return }
                settled = true
                term.terminate()
                let text = out.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression).ntTrimmed
                cont.resume(returning: Run(ok: ok, stdout: ok ? text : "", stderr: ok ? "" : (extra ?? text),
                                           code: ok ? 0 : 1, missing: false))
            }
            let timer = DispatchWorkItem { finish(false, "Timed out waiting on the security key") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timer)
            term.onData = { d in
                let chunk = String(decoding: d, as: UTF8.self)
                out += chunk
                fresh += chunk
                if !pinSent && fresh.range(of: "enter pin", options: .caseInsensitive) != nil {
                    fresh = ""
                    guard let pin else { timer.cancel(); finish(false, "This security key needs its PIN"); return }
                    pinSent = true
                    term.write(pin + "\r")
                }
                if fresh.range(of: "incorrect pin|wrong pin", options: [.caseInsensitive, .regularExpression]) != nil {
                    timer.cancel()
                    finish(false, "Incorrect PIN")
                }
            }
            term.onExit = { code in
                timer.cancel()
                DispatchQueue.main.async { finish(code == 0, nil) }
            }
        }
    }

    /// Host keys recorded for a hostname, in each of `files` (the default
    /// known_hosts plus any UserKnownHostsFile the host's config names).
    static func knownHostEntries(_ host: String, files: [String]) async -> [KnownHost] {
        var out: [KnownHost] = []
        for file in (files.isEmpty ? [knownHosts] : files) {
            let r = await run("ssh-keygen", ["-F", host, "-f", file])
            guard r.ok, !r.stdout.ntTrimmed.isEmpty else { continue }
            out += parseKnownHosts(r.stdout).map { var e = $0; e.file = file; return e }
        }
        return out
    }

    /// Remove a host's key from every file it is in; how many went.
    static func forgetHost(_ host: String, files: [String]) async throws -> (removed: Int, files: [String]) {
        let before = await knownHostEntries(host, files: files)
        var touched: [String] = []
        for e in before where !touched.contains(e.file ?? knownHosts) { touched.append(e.file ?? knownHosts) }
        var removed = 0
        for file in touched {
            let r = await run("ssh-keygen", ["-R", host, "-f", file], timeout: 30)
            if r.ok { removed += before.filter { ($0.file ?? knownHosts) == file }.count }
        }
        return (removed, touched)
    }

    /// The known_hosts files for a host (main.js knownHostsFilesFor): the
    /// default, plus whatever `ssh -G` says UserKnownHostsFile is.
    static func knownHostsFiles(alias: String?, configFile: String?) async -> [String] {
        var files = [knownHosts]
        guard let alias, !alias.isEmpty, Tools.sshAvailable else { return files }
        let cfg = await SSHConfig.resolveHost(alias, extraArgs: configFile.map { ["-F", $0] } ?? [])
        for entry in cfg?["userknownhostsfile"] ?? [] {
            for p in entry.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                let expanded = SSHConfig.expandHome(p)
                if !files.contains(expanded) { files.append(expanded) }
            }
        }
        return files
    }
}
