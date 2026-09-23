import Foundation

/// Keeps credentials out of anything Sync commits. A beam's working directory
/// can hold .env files, tbot identities and private keys, and an agent that
/// `cat`s them puts the material into the transcript too; both once ended up
/// in a public repo. Everything written to GitHub goes through here.
enum Secrets {
    /// Well-known secret files, excluded when the workspace is tarred in the beam.
    static let excludedPatterns: [String] = [
        ".env", ".env.*", "*.env",
        "*.pem", "*.key", "*.p12", "*.pfx", "*.jks", "*.keystore",
        "id_rsa*", "id_ecdsa*", "id_ed25519*", "*.ppk",
        ".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", ".pypirc", ".git-credentials",
        "kubeconfig", "*.kubeconfig",
        // tbot / Teleport outputs
        "tokenhash", "bkp_*", "id_bkp", "identity", "tlscert", "sshcert", "key", "key.pub",
        "teleport-host-cert*", "*-cert.pub",
    ]

    private static let rules: [(NSRegularExpression, String)] = {
        func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
        return [
            // PEM private keys, including when newlines are JSON-escaped (\n).
            (re(#"-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----.*?-----END \1PRIVATE KEY-----"#, [.dotMatchesLineSeparators]), "[REDACTED PRIVATE KEY]"),
            (re(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#), "[REDACTED PRIVATE KEY]"),
            // JWTs (Teleport bot certs and join tokens use these).
            (re(#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#), "[REDACTED JWT]"),
            // Well-known token formats.
            (re(#"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9]{32,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})\b"#), "[REDACTED TOKEN]"),
            // KEY=value / "key": "value" assignments for secret-ish names.
            // Handles .env lines, JSON ("token": "…") and JSON escaped inside a
            // transcript string (\"token\": \"…\"). The value must contain a
            // letter so numeric JSON values (which would break JSON) are left alone.
            (re(#"((?:[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CLIENT_?SECRET))\\?"?\s*[=:]\s*\\?"?)(?=[A-Za-z0-9/+_.@:-]*[A-Za-z])([A-Za-z0-9/+_.@:-]{8,})"#, [.caseInsensitive]), "$1[REDACTED]"),
        ]
    }()

    /// Returns text with credentials replaced by [REDACTED …] markers.
    static func redact(_ text: String) -> String {
        var s = text
        for (re, template) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    /// True when text holds material that must never be committed.
    static func containsSecret(_ text: String) -> Bool {
        redact(text) != text
    }

    /// Redacts credentials in place in every text file under `dir` (up to
    /// 2 MB; binary files are skipped, and binary key formats are excluded
    /// from the tar instead). Returns the relative paths changed, for the log.
    @discardableResult
    static func redactFiles(in dir: URL) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var changed: [String] = []
        let root = dir.resolvingSymlinksInPath().path + "/"
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true, (v?.fileSize ?? 0) <= 2_000_000,
                  let data = try? Data(contentsOf: url), !data.contains(0) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let clean = redact(text)
            if clean != text {
                try? Data(clean.utf8).write(to: url)
                changed.append(url.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: ""))
            }
        }
        return changed.sorted()
    }

    /// Copies `src` to `dst` with credentials redacted (text files).
    static func copyRedacted(_ src: URL, to dst: URL) throws {
        let data = try Data(contentsOf: src)
        let text = String(decoding: data, as: UTF8.self)
        try? FileManager.default.removeItem(at: dst)
        try Data(redact(text).utf8).write(to: dst)
    }
}
