import AppKit
import SwiftUI

/// Environment variables for tsh, from Settings — the port of tshenv.js and
/// teleport.js `parseEnvText` / `expandHome`, plus main.js
/// `teleport:resolveHome`.
///
/// For every cluster (in Locate tsh / ssh…), for one home (in its row of
/// Teleport homes) and for one cluster (from its heading's menu, teleport-ui),
/// the cluster's on top. The case this is for: Teleport's client tools
/// version, as its docs describe it — TELEPORT_TOOLS_VERSION=18.11.9 for one
/// cluster has tsh fetch and run that version for it, and every other cluster
/// keeps its own. Lines are `NAME=value`; `export NAME="value"` from a shell
/// profile is read as it is pasted.
///
/// Applying the variables to the tsh runs themselves is `Tools.tshEnv`'s
/// (Core) — this is the reading, checking and editing of them.
enum MiscTshEnv {
    struct Parsed: Equatable {
        /// In the order they were written; a later line for a name replaces the earlier.
        var vars: [(name: String, value: String)] = []
        var errors: [String] = []
        var dict: [String: String] { Dictionary(vars.map { ($0.name, $0.value) }, uniquingKeysWith: { _, b in b }) }
        static func == (a: Parsed, b: Parsed) -> Bool {
            a.errors == b.errors && a.vars.map(\.name) == b.vars.map(\.name) && a.vars.map(\.value) == b.vars.map(\.value)
        }
    }

    private static let lineRe = try! NSRegularExpression(pattern: "^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", options: [.dotMatchesLineSeparators])

    private static func stripExport(_ s: String) -> String {
        s.replacingOccurrences(of: #"^export\s+"#, with: "", options: .regularExpression)
    }

    /// teleport.js `parseEnvText`.
    static func parse(_ text: String?) -> Parsed {
        var out = Parsed()
        let lines = (text ?? "").components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let body = stripExport(line)
            let ns = body as NSString
            guard let m = lineRe.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else {
                out.errors.append("line \(i + 1): not NAME=value — \(String(line.prefix(60)))")
                continue
            }
            let name = ns.substring(with: m.range(at: 1))
            var v = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if let at = out.vars.firstIndex(where: { $0.name == name }) { out.vars[at].value = v }
            else { out.vars.append((name, v)) }
        }
        return out
    }

    /// The names a text sets, as the launch reminder lists them (index.js
    /// `remindCustomTeleport` `names`): any non-comment line with an `=`.
    static func names(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: "\n")
            .map { stripExport($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.contains("=") }
            .map { String($0[..<$0.firstIndex(of: "=")!]) }
    }

    /// How many lines of a home's text look like a variable (the row's "N vars").
    static func countVars(_ text: String?) -> Int {
        (text ?? "").components(separatedBy: "\n")
            .filter { $0.range(of: #"^\s*(export\s+)?[A-Za-z_]\w*="#, options: .regularExpression) != nil }.count
    }

    /// `corp.example.com:443`, `https://corp.example.com/web` → `corp.example.com`.
    static func bareProxy(_ p: String?) -> String {
        var s = (p ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.replacingOccurrences(of: #"^[a-z][a-z0-9+.-]*://"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #":443$"#, with: "", options: .regularExpression)
        return s
    }

    /// Values of names that look secret are not shown back.
    static func isSecret(_ name: String) -> Bool {
        name.range(of: #"KEY|TOKEN|SECRET|PASSWORD|PASS\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func shown(_ name: String, _ value: String) -> String { isSecret(name) ? "•••" : value }

    /// settings.clusterTshEnv[bareProxy(proxy)].
    @MainActor static func clusterText(_ proxy: String?) -> String {
        Store.shared.settings["clusterTshEnv"][bareProxy(proxy)].string ?? ""
    }

    /// What the box under a text says about it.
    static func note(_ text: String) -> (text: String, error: Bool) {
        let r = parse(text)
        if !r.errors.isEmpty { return (r.errors.joined(separator: "\n"), true) }
        if r.vars.isEmpty { return ("Nothing set.", false) }
        return ("Sets " + r.vars.map { "\($0.name)=\(shown($0.name, $0.value))" }.joined(separator: ", "), false)
    }

    static let example = "TELEPORT_TOOLS_VERSION=18.11.9"

    /// The example's Insert button: add the line, replacing a
    /// TELEPORT_TOOLS_VERSION line already there.
    static func insertExample(into text: String) -> String {
        var lines = text.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }
        if let at = lines.firstIndex(where: { $0.trimmed.range(of: #"^(export\s+)?TELEPORT_TOOLS_VERSION="#, options: .regularExpression) != nil }) {
            lines[at] = example
        } else {
            lines.append(example)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Homes (teleport.js expandHome, main.js teleport:resolveHome)

    /// `$VAR` and `${VAR}` substituted (a missing one is empty), `~` the home
    /// folder, and anything else made absolute. `unset` names the variables
    /// that were not there.
    static func expandHome(_ raw: String, env: [String: String] = ProcessInfo.processInfo.environment)
        -> (path: String, unset: [String]) {
        var unset: [String] = []
        let re = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)
        let ns = raw.trimmed as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let name = ns.substring(with: r)
            if let v = env[name] { out += v } else { if !unset.contains(name) { unset.append(name) } }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        let home = NSHomeDirectory()
        if out.isEmpty { return ("", unset) }
        if out == "~" { return (home, unset) }
        if out.hasPrefix("~/") { return ((home as NSString).appendingPathComponent(String(out.dropFirst(2))), unset) }
        let abs = out.hasPrefix("/") ? out : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(out)
        return ((abs as NSString).standardizingPath, unset)
    }

    struct ResolvedHome {
        var raw: String
        var resolved: String
        var exists: Bool
        var profiles: Int
        var unset: [String]
    }

    /// `teleport:resolveHome`: where a typed home points now, and what is there.
    static func resolveHome(_ raw: String) -> ResolvedHome {
        let r = raw.trimmed
        let (path, unset) = expandHome(r)
        var isDir: ObjCBool = false
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        let profiles = exists
            ? ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasSuffix(".yaml") }.count
            : 0
        return ResolvedHome(raw: r, resolved: path, exists: exists, profiles: profiles, unset: unset)
    }

    /// The line under a home's path in its dialog.
    static func homeNote(_ raw: String) -> (text: String, amber: Bool) {
        let r = resolveHome(raw)
        if r.raw.isEmpty { return ("", false) }
        if !r.unset.isEmpty {
            return ("$\(r.unset.joined(separator: ", $")) is not set for ServerLife — the home would be skipped until it is", true)
        }
        let s = r.profiles == 1 ? "" : "s"
        if r.resolved == r.raw {
            return (r.exists ? "\(r.profiles) profile\(s) there" : "Not there yet — tsh makes it at the first login", false)
        }
        return ("Now: \(r.resolved)" + (r.exists ? " — \(r.profiles) profile\(s)" : " — not there yet"), false)
    }
}

// MARK: - Views

/// tshenv.js `envBox`: the example to copy with an Insert button, a box for
/// `NAME=value` lines, and what it will set, said as it is typed.
struct MiscEnvBox: View {
    @Binding var text: String
    var placeholder = MiscTshEnv.example

    var body: some View {
        let p = Theme.shared.p
        let n = MiscTshEnv.note(text)
        VStack(alignment: .leading, spacing: 4) {
            // A placeholder vanishes the moment anything is typed, which is no
            // help when the thing to type is the line itself.
            HStack(spacing: 8) {
                MiscHint(text: "e.g.")
                Text(MiscTshEnv.example).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                Button("Insert") { text = MiscTshEnv.insertExample(into: text) }
                    .buttonStyle(.ghostSmall)
                    .help("Add this line to the box — replacing a TELEPORT_TOOLS_VERSION line already there")
            }
            .padding(.top, 2).padding(.bottom, 2)
            MiscTextArea(text: $text, rows: 4, placeholder: placeholder)
            MiscHint(text: n.text, color: n.error ? p.red : nil)
        }
    }
}

/// A monospaced multi-line box (`textarea`), with a placeholder.
struct MiscTextArea: View {
    @Binding var text: String
    let rows: Int
    var placeholder = ""
    var body: some View {
        let p = Theme.shared.p
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted)
                    .padding(.leading, 5).allowsHitTesting(false)
            }
        }
        .padding(4)
        .frame(height: CGFloat(rows) * 17 + 10)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }
}

/// "Add a tsh home" / "Change a tsh home": the path typed (~, $VAR and
/// ${VAR} allowed, read each time) or browsed for, where it points now, and
/// NAME=value variables for every tsh run against it.
@MainActor
enum MiscHomeDialog {
    static func run(_ window: WindowModel?, path: String = "", env: String = "") async -> (path: String, env: String)? {
        await withCheckedContinuation { cont in
            var done = false
            let finish: ((String, String)?) -> Void = { v in
                if !done { done = true; cont.resume(returning: v.map { (path: $0.0, env: $0.1) }) }
            }
            let h = Modal.sheet(window, title: path.isEmpty ? "Add a tsh home" : "Change a tsh home", width: 600) { handle in
                HomeDialogView(start: path, env: env, owner: window) { v in finish(v); handle.close() }
            }
            h.onClose.append { finish(nil) }
        }
    }
}

private struct HomeDialogView: View {
    let start: String
    let owner: WindowModel?
    let done: ((String, String)?) -> Void
    @StateObject private var path: Local<String>
    @StateObject private var env: Local<String>

    init(start: String, env: String, owner: WindowModel?, done: @escaping ((String, String)?) -> Void) {
        self.start = start
        self.owner = owner
        self.done = done
        _path = StateObject(wrappedValue: Local(start))
        _env = StateObject(wrappedValue: Local(env))
    }

    var body: some View {
        let p = Theme.shared.p
        let whereNote = MiscTshEnv.homeNote(path.value)
        let parsed = MiscTshEnv.parse(env.value)
        let n = parsed.vars.count
        DialogScaffold(title: start.isEmpty ? "Add a tsh home" : "Change a tsh home") {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Directory (TELEPORT_HOME)",
                          hint: "A path, or an environment variable — $TELEPORT_HOME, ${WORK}/.tsh — read each time the app starts and when Settings are saved.") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField("~/.tsh-work  or  $TELEPORT_HOME  or  ${WORK}/.tsh", text: $path.value)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse…") {
                                Task { @MainActor in
                                    let cur = path.value.trimmed
                                    if let d = await Modal.chooseDirectory(owner, defaultPath: cur.isEmpty ? nil : MiscTshEnv.expandHome(cur).path) {
                                        path.value = d.path
                                    }
                                }
                            }
                            .buttonStyle(.ghostSmall)
                        }
                        MiscHint(text: whereNote.text, color: whereNote.amber ? p.amber : nil)
                            .frame(minHeight: 14, alignment: .topLeading)
                    }
                }
                MiscField(label: "Variables for this home (optional)",
                          hint: "NAME=value, one a line, for every tsh command run with this home — on top of the ones for every cluster, under a cluster\u{2019}s own.") {
                    VStack(alignment: .leading, spacing: 4) {
                        MiscTextArea(text: $env.value, rows: 4,
                                     placeholder: "TELEPORT_TOOLS_VERSION=18.11.10\nTELEPORT_ADD_KEYS_TO_AGENT=no")
                        MiscHint(text: !parsed.errors.isEmpty ? parsed.errors.joined(separator: " · ")
                                    : (n > 0 ? "\(n) variable\(n == 1 ? "" : "s") for tsh with this home" : ""),
                                 color: parsed.errors.isEmpty ? nil : p.red)
                            .frame(minHeight: 13, alignment: .topLeading)
                    }
                }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(start.isEmpty ? "Add" : "Save") {
                let pth = path.value.trimmed
                if pth.isEmpty { StatusBus.shared.toast("Which directory?", kind: .error); return }
                if let e = parsed.errors.first { StatusBus.shared.toast(e, kind: .error); return }
                done((pth, env.value.trimmed))
            }
            .buttonStyle(.primary)
        }
    }
}
