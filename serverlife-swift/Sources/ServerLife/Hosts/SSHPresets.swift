import AppKit
import SwiftUI

/// sshpresets.js: common ssh options, in one list used two ways — as
/// `Name=value` lines for a host's or profile's "extra ssh options" (passed
/// as `-o`), and as the indented `Name value` lines an ssh_config Host block
/// holds. `file` asks for a key file first; `warn` is said before it is added.
struct SSHOptionPreset: Sendable {
    let group: String
    let label: String
    var help: String = ""
    var file = false
    var warn: String? = nil
    let lines: @Sendable (String?) -> [(String, String)]
}

enum SSHPresets {
    static let all: [SSHOptionPreset] = [
        SSHOptionPreset(group: "Keys", label: "Use only this key file…",
                        help: "Offers just the one key (a .pem or id_* file) — not every key in the agent and ~/.ssh.",
                        file: true, lines: { f in [("IdentityFile", f ?? ""), ("IdentitiesOnly", "yes")] }),
        SSHOptionPreset(group: "Keys", label: "Offer only the keys named here (IdentitiesOnly)",
                        help: "Stops ssh trying every agent key first — the usual cure for \"Too many authentication failures\".",
                        lines: { _ in [("IdentitiesOnly", "yes")] }),
        SSHOptionPreset(group: "Keys", label: "Offer no SSH keys at all",
                        help: "Password or keyboard-interactive only; no public key is tried.",
                        lines: { _ in [("PubkeyAuthentication", "no")] }),
        SSHOptionPreset(group: "Keys", label: "Don't use the SSH agent",
                        help: "Ignores ssh-agent (and 1Password, Secretive…) for this host.",
                        lines: { _ in [("IdentityAgent", "none")] }),
        SSHOptionPreset(group: "Keys", label: "Password login only",
                        help: "Goes straight to a password prompt.",
                        lines: { _ in [("PreferredAuthentications", "password,keyboard-interactive"), ("PubkeyAuthentication", "no")] }),
        SSHOptionPreset(group: "Keys", label: "Forward my SSH agent",
                        help: "Lets the server use your local keys to hop on. Only for hosts you trust.",
                        warn: "Anyone with root on that host can use your agent while you are connected.",
                        lines: { _ in [("ForwardAgent", "yes")] }),
        SSHOptionPreset(group: "Connection", label: "Keep the connection alive",
                        help: "A keep-alive every 30 s; gives up after 3 missed — for idle links and NAT that drop quiet sessions.",
                        lines: { _ in [("ServerAliveInterval", "30"), ("ServerAliveCountMax", "3")] }),
        SSHOptionPreset(group: "Connection", label: "Give up connecting after 10 seconds",
                        lines: { _ in [("ConnectTimeout", "10")] }),
        SSHOptionPreset(group: "Connection", label: "Compress traffic",
                        help: "Helps on slow links; costs CPU on fast ones.",
                        lines: { _ in [("Compression", "yes")] }),
        SSHOptionPreset(group: "Host keys", label: "Accept a new host key, refuse a changed one",
                        help: "First connection needs no \"yes\"; a key that changes later is still refused.",
                        lines: { _ in [("StrictHostKeyChecking", "accept-new")] }),
        SSHOptionPreset(group: "Host keys", label: "Don't check host keys (throwaway lab hosts)",
                        help: "For containers and VMs rebuilt with a new key every time.",
                        warn: "Turns off protection against a man-in-the-middle for this host.",
                        lines: { _ in [("StrictHostKeyChecking", "no"), ("UserKnownHostsFile", "/dev/null")] }),
        SSHOptionPreset(group: "Compatibility", label: "Allow old ssh-rsa keys (legacy servers)",
                        help: "For servers that only offer RSA/SHA-1, which modern OpenSSH refuses by default.",
                        lines: { _ in [("HostKeyAlgorithms", "+ssh-rsa"), ("PubkeyAcceptedAlgorithms", "+ssh-rsa")] }),
    ]

    static var groups: [String] {
        var seen: [String] = []
        for p in all where !seen.contains(p.group) { seen.append(p.group) }
        return seen
    }

    /// A preset's lines, resolving a file pick first. nil if cancelled.
    @MainActor
    static func resolve(_ preset: SSHOptionPreset, window: WindowModel?) async -> [(String, String)]? {
        var file: String?
        if preset.file {
            file = await SSHConfig.pickKey(window: window)
            if file == nil { return nil }
        }
        if let warn = preset.warn {
            let ok = await MiscUI.confirm(window, title: preset.label, message: warn, confirmLabel: "Add it")
            if !ok { return nil }
        }
        return preset.lines(file)
    }

    /// `addOptionLines`: add option lines to the text, replacing a line for
    /// the same option — `Name=value`, or ssh_config's `Name value`.
    static func addOptionLines(_ text: String, _ pairs: [(String, String)], format: String = "option") -> String {
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (name, value) in pairs {
            let line = format == "config" ? "\(name) \(value)" : "\(name)=\(value)"
            let i = lines.firstIndex { l in
                (l.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "=" || $0 == " " }).first.map(String.init) ?? "")
                    .lowercased() == name.lowercased()
            }
            if let i { lines[i] = line } else { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// What a new host or profile's extra options start as (settings.defaultSshOptions).
    @MainActor
    static var defaultSshOptions: String { Store.shared.setting("defaultSshOptions", "") }
}

/// `sshOptionPicker`: beside an "extra ssh options" box — a list of common
/// options that adds them as lines (typing your own still works), and a way
/// to make what is in the box the default for every new host and profile.
struct SSHOptionPicker: View {
    @Binding var text: String
    var format = "option"
    var window: WindowModel?

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(SSHPresets.groups, id: \.self) { g in
                    Section(g) {
                        ForEach(Array(SSHPresets.all.enumerated()).filter { $0.element.group == g }, id: \.offset) { _, p in
                            Button(p.label) { pick(p) }.help(p.help)
                        }
                    }
                }
            } label: {
                Text("Add a common option…").font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a common ssh option — or type your own in the box")
            Button("Use for new hosts by default") {
                let value = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                Store.shared.updateSettings(["defaultSshOptions": .string(value)])
                HToast.info(value.isEmpty ? "No default ssh options any more" : "New hosts and profiles will start with these ssh options")
            }
            .buttonStyle(.ghostSmall)
            .help("Every new host and saved profile starts with these options")
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func pick(_ p: SSHOptionPreset) {
        let w = window
        let fmt = format
        Task { @MainActor in
            guard let pairs = await SSHPresets.resolve(p, window: w) else { return }
            text = SSHPresets.addOptionLines(text, pairs, format: fmt)
        }
    }
}
