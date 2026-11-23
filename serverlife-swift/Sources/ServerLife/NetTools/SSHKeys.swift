import Foundation

/// A keypair in ~/.ssh (`listKeys()` in sshkeys.js).
struct SSHKey: Equatable, Identifiable {
    var name: String
    var publicPath: String
    var privatePath: String?
    var hasPrivate: Bool
    var privMode: Int?
    /// Read from the private key's own header; nil when it could not be read.
    var encrypted: Bool?
    var mtime: Double?
    var permissionsOk: Bool
    var publicKey: String
    var bits: Int?
    var fingerprint: String?
    var comment: String?
    var type: String?
    var id: String { publicPath }
}

/// An identity ssh-agent holds.
struct AgentKey: Equatable {
    var bits: Int?
    var fingerprint: String
    var comment: String?
    var type: String?
}

struct AgentState: Equatable {
    var running = false
    var keys: [AgentKey] = []
    /// No ssh-add at all — a different problem from an agent not answering.
    var missing = false
    var error: String?
}

/// SSH key and known_hosts management (src/main/sshkeys.js): seeing which
/// keys you have, adding them to the agent, generating one, installing a
/// public key on a server, and clearing a stale host key after a rebuild.
enum SSHKeys {
    /// ~/.ssh — overridable so tests work in a temporary directory and never
    /// touch the real one.
    nonisolated(unsafe) static var sshDir = NSHomeDirectory() + "/.ssh"
    static var knownHosts: String { sshDir + "/known_hosts" }

    struct Run { var ok: Bool; var stdout: String; var stderr: String; var code: Int32; var missing: Bool }

    /// Run an OpenSSH tool, found beside ssh first. A missing binary comes
    /// back as `missing` rather than as an error.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 20) async -> Run {
        let r = await Proc.run(Tools.tool(tool), args, timeout: timeout)
        return Run(ok: r.ok, stdout: r.out, stderr: r.err, code: r.code, missing: r.spawnError != nil)
    }

    /// "<bits> <hash> <comment> (<TYPE>)" → its parts.
    static func parseFingerprintLine(_ line: String) -> AgentKey {
        if let m = NetCheck.firstMatch(#"^(\d+)\s+(\S+)\s+(.*?)\s+\(([^)]+)\)$"#, line.ntTrimmed) {
            return AgentKey(bits: Int(m[1] ?? ""), fingerprint: m[2] ?? "", comment: m[3], type: m[4])
        }
        return AgentKey(bits: nil, fingerprint: line.ntTrimmed, comment: nil, type: nil)
    }

    /// The fingerprint and comment of a key file.
    static func describe(_ pubPath: String) async -> AgentKey? {
        let r = await run("ssh-keygen", ["-l", "-f", pubPath])
        guard r.ok else { return nil }
        return parseFingerprintLine(r.stdout)
    }

    /// Whether a private key is passphrase-protected, from its own header:
    /// OpenSSH format names its cipher ("none" when plain); old PEM says
    /// `Proc-Type: 4,ENCRYPTED`.
    static func headerSaysEncrypted(_ head: Data) -> Bool? {
        let text = String(decoding: head.prefix(1024).map { $0 }, as: UTF8.self)
        let latin = String(data: head.prefix(1024), encoding: .isoLatin1) ?? text
        if latin.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") { return opensshKeyEncrypted(latin) }
        return (try! NSRegularExpression(pattern: #"Proc-Type:\s*4,ENCRYPTED"#, options: .caseInsensitive)).matches(latin)
    }

    /// An OpenSSH-format key: `openssh-key-v1\0`, then a length-prefixed
    /// cipher name — "none" when the key is plain. Read as that one field
    /// rather than searched for: "none" can turn up anywhere in base64 (a
    /// salt, the key itself), which made an encrypted key look plain. nil
    /// when the header is not what it should be.
    static func opensshKeyEncrypted(_ headerText: String) -> Bool? {
        var b64 = headerText.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .map { $0.ntTrimmed }.joined()
        b64 = String(b64.prefix(b64.count - b64.count % 4))
        guard let raw = Data(base64Encoded: b64).map(Array.init) else { return nil }
        let magic = Array("openssh-key-v1\0".utf8)
        guard raw.count >= magic.count + 4, Array(raw[0..<magic.count]) == magic else { return nil }
        let len = raw[magic.count..<magic.count + 4].reduce(0) { $0 << 8 | Int($1) }
        let start = magic.count + 4
        guard len <= 64, start + len <= raw.count else { return nil }
        return String(decoding: raw[start..<start + len], as: UTF8.self) != "none"
    }

    /// Every keypair in ~/.ssh, found by its .pub file.
    static func listKeys() async -> [SSHKey] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sshDir) else { return [] }
        var out: [SSHKey] = []
        for name in names where name.hasSuffix(".pub") {
            let pub = sshDir + "/" + name
            let priv = String(pub.dropLast(4))
            var hasPrivate = false
            var privMode: Int? = nil
            // Followed through symlinks, as fs.stat does: a key kept by a
            // dotfile manager or on another volume is a link to the real file.
            if let a = try? fm.attributesOfItem(atPath: (priv as NSString).resolvingSymlinksInPath) {
                hasPrivate = (a[.type] as? FileAttributeType) == .typeRegular
                privMode = (a[.posixPermissions] as? NSNumber).map { $0.intValue & 0o777 }
            }
            let info = await describe(pub)
            let publicKey = ((try? String(contentsOfFile: pub, encoding: .utf8)) ?? "").ntTrimmed
            var encrypted: Bool? = nil
            if hasPrivate, let h = FileHandle(forReadingAtPath: priv) {
                encrypted = headerSaysEncrypted(h.readData(ofLength: 1024))
                try? h.close()
            }
            let mtime = ((try? fm.attributesOfItem(atPath: (pub as NSString).resolvingSymlinksInPath))?[.modificationDate] as? Date).map { $0.timeIntervalSince1970 * 1000 }
            out.append(SSHKey(name: (priv as NSString).lastPathComponent, publicPath: pub,
                              privatePath: hasPrivate ? priv : nil, hasPrivate: hasPrivate, privMode: privMode,
                              encrypted: encrypted, mtime: mtime,
                              // 0600 is what sshd insists on; anything looser is silently ignored.
                              permissionsOk: privMode == nil || privMode == 0o600 || privMode == 0o400,
                              publicKey: publicKey, bits: info?.bits, fingerprint: info.map(\.fingerprint),
                              comment: info?.comment, type: info?.type))
        }
        out.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        return out
    }

    /// Keys currently loaded into the agent. A wedged socket must not stall the dialog.
    static func agentKeys() async -> AgentState {
        let r = await run("ssh-add", ["-l"], timeout: 6)
        if !r.ok {
            if r.missing { return AgentState(running: false, keys: [], missing: true, error: "ssh-add was not found on this machine") }
            let text = (r.stdout + r.stderr).lowercased()
            if text.contains("no identities") { return AgentState(running: true) }
            return AgentState(running: false, error: (r.stderr.isEmpty ? r.stdout : r.stderr).ntTrimmed)
        }
        return AgentState(running: true, keys: r.stdout.ntTrimmed.split(separator: "\n").map { parseFingerprintLine(String($0)) })
    }

    /// Does this key need a passphrase?
    static func isEncrypted(_ privatePath: String) async -> Bool {
        !(await run("ssh-keygen", ["-y", "-P", "", "-f", privatePath], timeout: 8)).ok
    }

    struct AddResult { var ok: Bool; var output: String; var needsPassphrase = false; var missing = false }

    /// Add a key to the agent — or, with no path, the default identities.
    ///
    /// `ssh-add` asks for a passphrase on its controlling terminal; spawned
    /// from a GUI app there is none, so it falls back to SSH_ASKPASS. Running
    /// it on a pty with askpass disabled keeps the prompt where it can be
    /// answered — every prompt, since plain `ssh-add` walks each default
    /// identity and asks for each encrypted one.
    @MainActor
    static func addToAgent(_ privatePath: String?, passphrase: String? = nil, timeout: TimeInterval = 30,
                           keychain: Bool = false, pkcs11Provider: String? = nil) async -> AddResult {
        guard Tools.toolAvailable("ssh-add") else {
            return AddResult(ok: false, output: "ssh-add was not found on this machine.", missing: true)
        }
        var args: [String] = []
        // `--apple-use-keychain` stores the passphrase in the login keychain;
        // Apple's fork only, so opt-in.
        if keychain { args.append("--apple-use-keychain") }
        // `-s <provider>`: every identity a PKCS#11 token holds, through its
        // provider library; the prompt is then for the token's PIN.
        if let pkcs11Provider { args += ["-s", pkcs11Provider] } else if let privatePath { args.append(privatePath) }
        let promptRe = pkcs11Provider != nil ? "enter pin" : "passphrase"
        let wrongRe = pkcs11Provider != nil ? "incorrect pin|wrong pin" : "bad passphrase|incorrect passphrase"
        let term: PTYProcess
        do {
            term = try PTYProcess(exe: Tools.tool("ssh-add"), args: args,
                                  env: ["SSH_ASKPASS_REQUIRE": "never", "SSH_ASKPASS": "", "DISPLAY": ""])
        } catch {
            return AddResult(ok: false, output: "Could not run ssh-add: \(error.localizedDescription)", missing: true)
        }
        return await withCheckedContinuation { cont in
            var out = ""
            // What arrived since the last prompt was answered: plain `ssh-add`
            // prompts once per encrypted default key, and each needs an answer.
            var fresh = ""
            var settled = false
            let finish: (Bool, String?) -> Void = { ok, extra in
                guard !settled else { return }
                settled = true
                term.terminate()
                let text = out.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression).ntTrimmed
                cont.resume(returning: AddResult(ok: ok, output: extra ?? text,
                                                 needsPassphrase: !ok && text.range(of: promptRe, options: [.caseInsensitive, .regularExpression]) != nil && passphrase == nil))
            }
            let timer = DispatchWorkItem { finish(false, "ssh-add did not finish in time") }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
            term.onData = { d in
                let chunk = String(decoding: d, as: UTF8.self)
                out += chunk
                fresh += chunk
                if fresh.range(of: promptRe, options: [.caseInsensitive, .regularExpression]) != nil {
                    fresh = ""
                    guard let passphrase else {
                        // Nothing to type; stop rather than leaving it waiting.
                        timer.cancel()
                        finish(false, pkcs11Provider != nil ? "This PKCS#11 token needs its PIN"
                               : privatePath != nil ? "This key is protected by a passphrase"
                               : "One of the default keys is protected by a passphrase — add it on its own to enter it")
                        return
                    }
                    term.write(passphrase + "\r")
                }
                if (try! NSRegularExpression(pattern: wrongRe, options: .caseInsensitive)).matches(out) {
                    timer.cancel()
                    finish(false, pkcs11Provider != nil ? "Incorrect PIN" : "Incorrect passphrase")
                }
            }
            term.onExit = { code in
                timer.cancel()
                // Let the last output land before deciding.
                DispatchQueue.main.async { finish(code == 0, nil) }
            }
        }
    }

    struct Generated {
        var name, privatePath, publicPath, publicKey: String; var type: String?; var fingerprint: String?
        var securityKey = false
    }

    static let securityKeyTypes = ["ed25519-sk", "ecdsa-sk"]

    /// Create a new keypair in ~/.ssh.
    static func generate(name: String, type: String = "ed25519", bits: Int? = nil, comment: String? = nil,
                         passphrase: String = "", resident: Bool = false, verifyRequired: Bool = false,
                         pin: String? = nil) async throws -> Generated {
        let securityKey = securityKeyTypes.contains(type)
        if securityKey && !SSHVersion.supports("securityKeyIdentities") {
            let v = SSHVersion.current()
            throw AppError("This machine's ssh-keygen\(v.map { " (\($0.raw))" } ?? "") is too old for FIDO2 security-key "
                + "keys — OpenSSH 8.2 or later is needed.")
        }
        if name.isEmpty || name.contains("/") || name.contains("\\") { throw AppError("Give the key a simple file name") }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = sshDir + "/" + name
        if fm.fileExists(atPath: target) || fm.fileExists(atPath: target + ".pub") { throw AppError("\(name) already exists") }
        var host = [CChar](repeating: 0, count: 256)
        gethostname(&host, 255)
        let c = (comment ?? "").isEmpty ? "\(NSUserName())@\(String(cString: host))" : comment!
        var args = ["-t", type, "-f", target, "-N", passphrase, "-C", c]
        if type == "rsa" { args += ["-b", String(bits ?? 4096)] }
        if securityKey {
            if resident { args += ["-O", "resident"] }
            if verifyRequired { args += ["-O", "verify-required"] }
        }
        let r = securityKey ? await generateSecurityKey(args, pin: pin) : await run("ssh-keygen", args, timeout: 120)
        if !r.ok {
            let m = (r.stderr.isEmpty ? r.stdout : r.stderr).ntTrimmed
            throw AppError(m.isEmpty ? "ssh-keygen failed" : m)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        let info = await describe(target + ".pub")
        let pub = ((try? String(contentsOfFile: target + ".pub", encoding: .utf8)) ?? "").ntTrimmed
        return Generated(name: name, privatePath: target, publicPath: target + ".pub", publicKey: pub,
                         type: info?.type, fingerprint: info?.fingerprint, securityKey: securityKey)
    }

    /// The script that appends a public key to authorized_keys if absent and
    /// fixes the permissions sshd requires — ssh-copy-id over an open session.
    static func installScript(_ publicKey: String) throws -> String {
        let key = publicKey.ntTrimmed
        if key.range(of: #"^(ssh|ecdsa|sk-)\S+\s+\S+"#, options: .regularExpression) == nil {
            throw AppError("That does not look like a public key")
        }
        return [
            "set -e",
            "mkdir -p ~/.ssh",
            "chmod 700 ~/.ssh",
            "touch ~/.ssh/authorized_keys",
            "chmod 600 ~/.ssh/authorized_keys",
            "if grep -qF \(shellQuote(key)) ~/.ssh/authorized_keys 2>/dev/null; then",
            "  echo already-present",
            "else",
            "  printf '%s\\n' \(shellQuote(key)) >> ~/.ssh/authorized_keys",
            "  echo installed",
            "fi",
        ].joined(separator: "\n")
    }

    static func installResult(_ out: String) -> (installed: Bool, alreadyPresent: Bool) {
        let last = out.ntTrimmed.components(separatedBy: "\n").last ?? ""
        return (last == "installed", last == "already-present")
    }

    @MainActor
    static func install(connId: String, publicKey: String) async throws -> (installed: Bool, alreadyPresent: Bool) {
        let script = try installScript(publicKey)
        let c = try NTConnections.require(connId)
        try await c.connect()
        return installResult(try await c.exec(script, timeout: 20))
    }

    struct KnownHost: Equatable { var line: String; var type: String; var key: String; var file: String? = nil }

    /// Host keys recorded for a hostname.
    static func knownHostEntries(_ host: String) async -> [KnownHost] {
        let r = await run("ssh-keygen", ["-F", host, "-f", knownHosts])
        guard r.ok, !r.stdout.ntTrimmed.isEmpty else { return [] }
        return parseKnownHosts(r.stdout)
    }

    static func parseKnownHosts(_ text: String) -> [KnownHost] {
        text.ntTrimmed.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return KnownHost(line: line, type: parts.count > 1 ? parts[1] : "",
                             key: String((parts.count > 2 ? parts[2] : "").prefix(24)) + "…")
        }
    }

    /// Remove a host's key — the fix for "REMOTE HOST IDENTIFICATION HAS
    /// CHANGED" after a server is rebuilt.
    static func forgetHost(_ host: String) async throws -> Int {
        let before = await knownHostEntries(host)
        if before.isEmpty { return 0 }
        let r = await run("ssh-keygen", ["-R", host, "-f", knownHosts], timeout: 30)
        if !r.ok {
            let m = (r.stderr.isEmpty ? r.stdout : r.stderr).ntTrimmed
            throw AppError(m.isEmpty ? "ssh-keygen -R failed" : m)
        }
        return before.count
    }

    /// Unpack a Teleport agent identity: `teleport:<proxy>:<cluster>:<user>`.
    /// The proxy may be host:port, so the user is the last field and the
    /// cluster the one before it.
    static func teleportIdentity(_ comment: String?) -> (proxy: String, cluster: String, user: String)? {
        let parts = (comment ?? "").components(separatedBy: ":")
        guard parts.first == "teleport", parts.count >= 4 else { return nil }
        return (parts[1..<(parts.count - 2)].joined(separator: ":"), parts[parts.count - 2], parts[parts.count - 1])
    }

    /// Does an ssh_config IdentityFile refer to this key? On the file name alone.
    static func sameKeyPath(_ identityFile: String, _ key: SSHKey) -> Bool {
        func base(_ p: String) -> String {
            var b = p.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
            if b.hasSuffix(".pub") { b.removeLast(4) }
            return b
        }
        return base(identityFile) == base(key.privatePath ?? key.publicPath)
    }

    /// Agent identities with no keypair here, one per fingerprint: `tsh login`
    /// loads each identity twice (certificate and key) with one fingerprint.
    struct AgentOnly { var key: AgentKey; var types: [String]; var entries: Int }

    static func agentOnly(_ agent: [AgentKey], local: [SSHKey]) -> (groups: [AgentOnly], extra: Int) {
        let localFps = Set(local.compactMap(\.fingerprint))
        let extra = agent.filter { !$0.fingerprint.isEmpty && !localFps.contains($0.fingerprint) }
        var groups: [AgentOnly] = []
        for a in extra {
            if let i = groups.firstIndex(where: { $0.key.fingerprint == a.fingerprint }) {
                groups[i].entries += 1
                if let t = a.type, !groups[i].types.contains(t) { groups[i].types.append(t) }
            } else {
                groups.append(AgentOnly(key: a, types: a.type.map { [$0] } ?? [], entries: 1))
            }
        }
        return (groups, extra.count)
    }
}
