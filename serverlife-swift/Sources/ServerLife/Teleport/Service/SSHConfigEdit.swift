import AppKit
import Foundation

/// Removing or commenting out any Host, wherever it was written
/// (sshconfig.js `findHostBlock`, `hostBlockPreview`, `removeHostFromFile`),
/// and editing an ssh config inside the app (main.js `sshconfig:read`,
/// `sshconfig:check`, `sshconfig:write`, `sshconfig:openInEditor`,
/// `knownConfigFile`).
extension SSHConfig {
    struct HostBlock: Equatable, Sendable {
        /// The `Host` line.
        var start: Int
        /// The first comment line touching it (its description).
        var lead: Int
        /// One past the block's last line.
        var end: Int
        /// The other names on the same `Host` line.
        var shared: [String]
    }

    /// `findHostBlock`: where an alias's `Host` block sits in one file.
    ///
    /// The block runs from its `Host` line to the line before the next `Host`
    /// or `Match`, less the blank and comment lines at its end — those are
    /// usually the next host's description, which is how the sidebar reads
    /// them too. `shared` lists the other names on the same `Host` line:
    /// removing the block would take them with it, so for those only the one
    /// name is taken off.
    static func findHostBlock(_ lines: [String], alias: String) -> HostBlock? {
        for i in lines.indices {
            guard let kv = splitLine(lines[i]), kv.key == "host" else { continue }
            let names = tokens(kv.value).map(stripQuotes)
            if !names.contains(alias) { continue }
            var end = i + 1
            while end < lines.count {
                if let next = splitLine(lines[end]), next.key == "host" || next.key == "match" { break }
                end += 1
            }
            while end > i + 1 && (lines[end - 1].trimmed.isEmpty || lines[end - 1].trimmed.hasPrefix("#")) { end -= 1 }
            var lead = i
            while lead > 0 && lines[lead - 1].trimmed.hasPrefix("#") { lead -= 1 }
            return HostBlock(start: i, lead: lead, end: end, shared: names.filter { $0 != alias })
        }
        return nil
    }

    /// JS `text.split(/\r?\n/)`.
    static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    struct BlockPreview: Equatable, Sendable {
        var file: String
        var alias: String
        var text: String
        var shared: [String]
        /// 1-based line of the `Host` line.
        var line: Int
    }

    /// `hostBlockPreview`: the text of an alias's block, to show before anything is changed.
    static func hostBlockPreview(file: String, alias: String) throws -> BlockPreview {
        let text = try readText(expandHome(file))
        let lines = splitLines(text)
        guard let b = findHostBlock(lines, alias: alias) else { throw AppError("\"\(alias)\" is not defined in \(file)") }
        let from = b.shared.isEmpty ? b.lead : b.start
        return BlockPreview(file: file, alias: alias, text: lines[from..<b.end].joined(separator: "\n"),
                            shared: b.shared, line: b.start + 1)
    }

    struct RemoveResult: Equatable, Sendable {
        var file: String
        var alias: String
        var mode: String
        var shared: [String]
        var backup: String
    }

    static func isoDay(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The pure half of `removeHostFromFile`: the new text, or nil when the
    /// alias is not there. `mode` is "delete" or "comment".
    static func removingHost(_ text: String, alias: String, mode: String, today: String = isoDay())
        -> (text: String, shared: [String])? {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = splitLines(text)
        guard let b = findHostBlock(lines, alias: alias) else { return nil }
        if !b.shared.isEmpty {
            // Other names share this block: take this one off the Host line only.
            let indent = TPText.match(#"^\s*"#, lines[b.start])?[0] ?? ""
            let kept = "\(indent)Host \(b.shared.joined(separator: " "))"
            let replacement = mode == "comment"
                ? ["\(indent)# \(alias) taken off this Host line by ServerLife, \(today)", kept]
                : [kept]
            lines.replaceSubrange(b.start...b.start, with: replacement)
        } else if mode == "comment" {
            let replacement = ["# Commented out by ServerLife, \(today)"]
                + lines[b.start..<b.end].map { $0.trimmed.isEmpty ? $0 : "# " + $0 }
            lines.replaceSubrange(b.start..<b.end, with: replacement)
        } else {
            // Its description goes with it, and a blank line either side of
            // the hole becomes one.
            var end = b.end
            if b.lead > 0 && lines[b.lead - 1].trimmed.isEmpty && end < lines.count && lines[end].trimmed.isEmpty { end += 1 }
            lines.removeSubrange(b.lead..<end)
        }
        return (lines.joined(separator: eol), b.shared)
    }

    /// `removeHostFromFile`: delete an alias from the file it was written in,
    /// or comment its block out. The file as it was is copied to
    /// `<file>.serverlife-backup` first — over the last one, so it is always
    /// the state before the most recent edit — and the new text is written
    /// beside it and renamed over, keeping the file's mode.
    @discardableResult
    static func removeHostFromFile(file: String, alias: String, mode: String = "delete") throws -> RemoveResult {
        if file.isEmpty || alias.isEmpty { throw AppError("Give a file and an alias.") }
        let target = expandHome(file)
        let text = try readText(target)
        guard let r = removingHost(text, alias: alias, mode: mode) else {
            throw AppError("\"\(alias)\" is not defined in \(file)")
        }
        let backup = target + ".serverlife-backup"
        try replaceKeepingMode(target, with: r.text, backup: backup)
        return RemoveResult(file: file, alias: alias, mode: mode, shared: r.shared, backup: backup)
    }

    // MARK: - Editing a config file in the app

    /// `knownConfigFile`: only a file the host list was actually read from.
    /// These write to disk (or hand a path to the system), so no caller can
    /// name any file it likes.
    @MainActor
    static func knownConfigFile(_ file: String?) throws -> String {
        let p = (expandHome((file ?? "").trimmed) as NSString).standardizingPath
        let extra: [String] = Store.shared.setting("sshConfigFiles", [String]())
        let roots = listConfigFiles(extra).map(\.file)
        let sources = configRoots(extra).flatMap { collectAliases($0.file).map(\.source) }
        let known = Set(([defaultPath] + roots + sources).map { ($0 as NSString).standardizingPath })
        if !known.contains(p) { throw AppError("\(file ?? "") is not one of the ssh config files ServerLife reads.") }
        return p
    }

    /// `sshconfig:read` (a missing file reads as empty).
    @MainActor
    static func readConfig(_ file: String?) throws -> (path: String, text: String) {
        let p = try knownConfigFile(file?.nilIfEmpty ?? defaultPath)
        if !FileManager.default.fileExists(atPath: p) { return (p, "") }
        return (p, try readText(p))
    }

    struct CheckResult: Equatable, Sendable {
        var ok: Bool
        var errors: [String] = []
        var warnings: [String] = []
    }

    /// The lines of `ssh -G` stderr that say what is wrong.
    static func checkProblems(_ stderr: String, tmp: String, realPath: String?) -> [String] {
        stderr.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: tmp, with: realPath ?? "config").trimmed }
            .filter { !$0.isEmpty }
    }

    /// `checkSshConfigText`: never saved without ssh itself having parsed the
    /// new text first — `ssh -G -F <copy>` reads every line the way a real
    /// connection would, so a typo is caught here, with its line number,
    /// instead of breaking every ssh on the machine.
    static func checkText(_ text: String, realPath: String?) async -> CheckResult {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("serverlife-sshconfig-\(getpid())-\(Int(Date().timeIntervalSince1970 * 1000))")
        guard FileManager.default.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            return CheckResult(ok: false, errors: ["Could not write \(tmp)"])
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = await Proc.run(Tools.ssh, ["-G", "-F", tmp, "serverlife-config-check.invalid"], timeout: 15)
        let said = checkProblems(r.err + (r.spawnError.map { "\n" + $0 } ?? ""), tmp: tmp, realPath: realPath)
        let problems = said.filter {
            TPText.test(#"line \d+|Bad configuration|bad|unsupported|Unsupported|error|missing|garbage"#, $0, .caseInsensitive)
        }
        return r.ok ? CheckResult(ok: true, warnings: problems)
                    : CheckResult(ok: false, errors: problems.isEmpty ? Array(said.prefix(5)) : problems)
    }

    /// `sshconfig:check`.
    @MainActor
    static func checkConfig(file: String?, text: String) async throws -> CheckResult {
        let p = try knownConfigFile(file?.nilIfEmpty ?? defaultPath)
        return await checkText(text, realPath: p)
    }

    struct WriteResult: Equatable, Sendable {
        var ok: Bool
        var path = ""
        var backup = ""
        var errors: [String] = []
        var warnings: [String] = []
    }

    /// `sshconfig:write`: checked first; the file it replaces is kept beside
    /// it as <file>.serverlife-backup, and its permissions are kept.
    @MainActor
    static func writeConfig(file: String?, text: String) async throws -> WriteResult {
        let p = try knownConfigFile(file?.nilIfEmpty ?? defaultPath)
        let check = await checkText(text, realPath: p)
        if !check.ok { return WriteResult(ok: false, errors: check.errors) }
        let backup = p + ".serverlife-backup"
        try replaceKeepingMode(p, with: text, backup: backup, atomic: false)
        return WriteResult(ok: true, path: p, backup: backup, warnings: check.warnings)
    }

    /// `sshconfig:openInEditor`: in the text editor, not whatever claims
    /// extension-less files — `config` would otherwise open in a terminal,
    /// or nothing at all.
    @MainActor @discardableResult
    static func openInEditor(_ file: String?) async throws -> String {
        let p = try knownConfigFile(file?.nilIfEmpty ?? defaultPath)
        let r = await Proc.run("/usr/bin/open", ["-t", p], timeout: 15)
        if !r.ok { throw AppError(TPText.errText(r).nilIfEmpty ?? "Could not open \(p)") }
        return p
    }

    // MARK: - Files

    static func readText(_ path: String) throws -> String {
        do { return try String(contentsOfFile: path, encoding: .utf8) } catch {
            throw AppError("Could not read \(path): \(error.localizedDescription)")
        }
    }

    /// Back the file up (when it exists), then write the new text with the
    /// old file's mode (0600 for a new one) — beside it and renamed over
    /// when `atomic`.
    static func replaceKeepingMode(_ path: String, with text: String, backup: String, atomic: Bool = true) throws {
        let fm = FileManager.default
        var mode = 0o600
        if fm.fileExists(atPath: path) {
            if let m = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber { mode = m.intValue & 0o777 }
            try? fm.removeItem(atPath: backup)
            do { try fm.copyItem(atPath: path, toPath: backup) } catch {
                throw AppError("Could not back up \(path): \(error.localizedDescription)")
            }
        }
        let dest = atomic ? path + ".serverlife-tmp" : path
        do { try Data(text.utf8).write(to: URL(fileURLWithPath: dest)) } catch {
            throw AppError("Could not write \(dest): \(error.localizedDescription)")
        }
        chmod(dest, mode_t(mode))
        if atomic, rename(dest, path) != 0 { throw AppError("Could not replace \(path): \(String(cString: strerror(errno)))") }
    }
}
