import AppKit
import SwiftUI

/// sshoptions.js (renderer): SSH options for a host — X11, forwards both
/// ways, a SOCKS proxy, a jump host, and Teleport's reason, invitations and
/// automatic access requests. Not everything wanted once is wanted every
/// time, so there are three ways to use a set: open once with it, keep it as
/// a named preset to open with when wanted, or make it the host's default,
/// used every time it is opened. The flags are built and checked by
/// `HostsSSHOpts` (the main-process half).
@MainActor
enum SSHOptionsUI {
    /// A few words for a set of options, for a menu line (`briefly`).
    nonisolated static func briefly(_ o: JSON?) -> String {
        guard let o, o.truthy else { return "" }
        func arr(_ k: String) -> [String] { o[k].items.compactMap(\.stringish) }
        func s(_ k: String) -> String { o[k].truthy ? (o[k].stringish ?? "") : "" }
        var bits: [String] = []
        if !s("x11").isEmpty && s("x11") != "off" { bits.append("X11 \(s("x11"))") }
        if !arr("localForwards").isEmpty { bits.append("-L \(arr("localForwards").joined(separator: " "))") }
        if !arr("remoteForwards").isEmpty { bits.append("-R \(arr("remoteForwards").joined(separator: " "))") }
        if !arr("dynamicForwards").isEmpty { bits.append("SOCKS \(arr("dynamicForwards").joined(separator: " "))") }
        if !s("jumpHost").isEmpty { bits.append("via \(s("jumpHost"))") }
        if !s("reason").isEmpty { bits.append("reason \"\(s("reason"))\"") }
        if !arr("invite").isEmpty { bits.append("invites \(arr("invite").joined(separator: ", "))") }
        if !s("requestMode").isEmpty { bits.append("auto request \(s("requestMode"))") }
        if o["noResume"].truthy { bits.append("no resume") }
        if o["noShell"].truthy { bits.append("no shell (-N)") }
        if !arr("extraOptions").isEmpty { bits.append("-o \(arr("extraOptions").joined(separator: " "))") }
        return bits.joined(separator: " · ")
    }

    /// `openWith`: open the host with these options (nil = plain, without the default).
    static func openWith(_ host: Host, login: String?, options: JSON?, label: String?, window: WindowModel?) {
        HStatus.show("Opening \(host.name.nilIfEmpty ?? host.alias ?? "")\(label.map { " (\($0))" } ?? "")…", sticky: true)
        // A forwarding-only (-N) opening is set up as a tunnel by open-host itself.
        var args: [String: Any] = ["sshOptions": options ?? JSON.null, "reuse": false]
        if let login { args["login"] = login }
        Actions.shared.perform("open-host", window: window, host: host, args: args)
        HStatus.show("")
    }

    /// The menu title: "SSH options", with what is saved in brackets.
    static func menuTitle(_ rec: HostsSSHOpts.Record) -> String {
        let hasDef = rec.defaultOptions != nil
        let n = rec.presets.count
        if !hasDef && n == 0 { return "SSH options" }
        var inner = hasDef ? "default set" : ""
        if hasDef && n > 0 { inner += ", " }
        if n > 0 { inner += "\(n) preset\(n == 1 ? "" : "s")" }
        return "SSH options (\(inner))"
    }

    /// `sshOptionsMenu`: the host menu's "SSH options" entry, replacing the X11
    /// one it grew from. `openX11` is the existing path, which checks for an X
    /// server first.
    static func menu(_ host: Host, login: String?, window: WindowModel?, openX11: (() -> Void)?) -> CtxItem {
        let saved = HostsSSHOpts.record(host)
        let teleport = host.isTeleport
        var items: [CtxItem] = []
        if let def = saved.defaultOptions {
            items.append(.heading("Default for this host"))
            items.append(CtxItem(briefly(def).nilIfEmpty ?? "(nothing)", disabled: true))
            items.append(CtxItem("Open plain, without the default", title: "Just this once: no saved options") {
                openWith(host, login: login, options: nil, label: "plain", window: window)
            })
        }
        if !saved.presets.isEmpty {
            items.append(.heading("Open as"))
            for p in saved.presets {
                items.append(CtxItem(p.name, sub: briefly(p.options), title: briefly(p.options)) {
                    openWith(host, login: login, options: p.options, label: p.name, window: window)
                })
            }
        }
        if !items.isEmpty { items.append(.sep) }
        items.append(CtxItem("Open with X11 forwarding", icon: "\u{2317}") {
            if let openX11 { openX11() } else {
                var args: [String: Any] = ["x11": "untrusted"]
                if let login { args["login"] = login }
                Actions.shared.perform("open-host", window: window, host: host, args: args)
            }
        })
        items.append(CtxItem("Remote forward (-R)…", icon: "↩", title: "Make a port on this machine reachable from the host") {
            openDialog(host, login: login, window: window, focus: .remoteForwards)
        })
        items.append(CtxItem("SOCKS proxy (-D)…", icon: "⦿", title: "Browse through the host, as if from where it is") {
            openDialog(host, login: login, window: window, focus: .dynamicForwards)
        })
        if teleport {
            items.append(CtxItem("Reason and invitations…", icon: "✉",
                                 title: "Say why, and invite people to watch or moderate the session") {
                openDialog(host, login: login, window: window, focus: .reason)
            })
        }
        items.append(.sep)
        items.append(CtxItem("All SSH options…", icon: "⚙",
                             title: "Every option in one place — open once, save as a preset, or make it the default") {
            openDialog(host, login: login, window: window)
        })
        if saved.defaultOptions != nil {
            items.append(CtxItem("Clear the default", icon: "✕") {
                do { try HostsSSHOpts.save(host, clearDefault: true) } catch { return HToast.error(hostsErrorText(error)) }
                HStatus.show("Default SSH options cleared for this host")
            })
        }
        if !saved.presets.isEmpty {
            items.append(CtxItem("Delete a preset", icon: "✕", submenu: saved.presets.map { p in
                CtxItem(p.name) {
                    do { try HostsSSHOpts.save(host, deletePreset: p.name) } catch { return HToast.error(hostsErrorText(error)) }
                    HStatus.show("Preset \"\(p.name)\" deleted")
                }
            }))
        }
        return CtxItem(menuTitle(saved), icon: "\u{2317}", submenu: items)
    }

    enum Focus: Hashable { case remoteForwards, dynamicForwards, reason }

    /// `openSshOptionsDialog`: every option in one dialog, opening on the
    /// host's default (or on `start`), checked as you type by the same code
    /// that builds the flags.
    static func openDialog(_ host: Host, login: String?, window: WindowModel?, focus: Focus? = nil, start: JSON? = nil) {
        let saved = HostsSSHOpts.record(host)
        let model = SSHOptionsModel(host: host, start: start ?? saved.defaultOptions ?? [:])
        let name = host.name.nilIfEmpty ?? host.alias ?? ""
        let subtitle = start != nil ? "Editing a preset"
            : (saved.defaultOptions != nil ? "Showing the default for this host" : "Nothing saved for this host yet")
        Modal.sheet(window, title: "SSH options — \(name)", width: 640) { handle in
            SSHOptionsView(model: model, title: "SSH options — \(name)", subtitle: subtitle, focus: focus,
                           window: window, copy: {
                let c = HostsSSHOpts.normalize(model.collect())
                if let e = c.errors.first { return HToast.error(e) }
                let who = login?.nilIfEmpty ?? Store.shared.settingJSON("hostUsers")[host.prefKey].string?.nilIfEmpty
                let cmd = HostsSSHOpts.commandLine(host: host.json, login: who, options: c.options.json)
                Clipboard.write(cmd)
                StatusBus.shared.show("Copied: " + cmd, seconds: 8)
            }) { res in
                handle.close()
                guard let res else { return }
                Task { @MainActor in await finish(res, model: model, host: host, login: login, window: window, focus: focus) }
            }
        }
    }

    private static func finish(_ res: String, model: SSHOptionsModel, host: Host, login: String?,
                               window: WindowModel?, focus: Focus?) async {
        let raw = model.collect()
        let c = HostsSSHOpts.normalize(raw)
        if let e = c.errors.first {
            HToast.error(e, seconds: 8)
            return openDialog(host, login: login, window: window, focus: focus, start: raw)
        }
        let options = c.options.json
        let name = host.name.nilIfEmpty ?? host.alias ?? ""
        if res == "once" { return openWith(host, login: login, options: options, label: "these options", window: window) }
        do {
            if res == "preset" {
                let suggested = String(briefly(options).prefix(40))
                guard let presetName = await MiscUI.prompt(window, title: "Name the preset",
                                                           label: "Opened from \(name)'s SSH options menu — never applied unless picked",
                                                           value: suggested.isEmpty ? "My options" : suggested,
                                                           confirmLabel: "Save preset",
                                                           validate: { $0.isEmpty ? "Give it a name" : nil }),
                      !presetName.isEmpty else { return }
                let errs = try HostsSSHOpts.save(host, presetName: presetName, options: options)
                if let e = errs.first { return HToast.error(e) }
                return HStatus.show("Preset \"\(presetName)\" saved for \(name)")
            }
            let errs = try HostsSSHOpts.save(host, asDefault: true, options: options)
            if let e = errs.first { return HToast.error(e) }
        } catch {
            return HToast.error(hostsErrorText(error))
        }
        let b = briefly(options)
        HStatus.show(b.isEmpty ? "\(name) has no default SSH options now" : "Default SSH options saved for \(name): \(b)")
    }
}

@MainActor
final class SSHOptionsModel: ObservableObject {
    let teleport: Bool
    @Published var x11: String
    @Published var local: String
    @Published var remote: String
    @Published var dynamic: String
    @Published var jump: String
    @Published var noShell: Bool
    @Published var extra: String
    @Published var reason: String
    @Published var invite: String
    @Published var reqMode: String
    @Published var reqReason: String
    @Published var noResume: Bool

    init(host: Host, start o: JSON) {
        teleport = host.isTeleport
        func lines(_ k: String, _ sep: String) -> String {
            if case .array(let a) = o[k] { return a.compactMap(\.stringish).joined(separator: sep) }
            return o[k].truthy ? (o[k].stringish ?? "") : ""
        }
        func s(_ k: String) -> String { o[k].truthy ? (o[k].stringish ?? "") : "" }
        x11 = HostsSSHOpts.x11Modes.contains(s("x11")) ? s("x11") : "off"
        local = lines("localForwards", "\n")
        remote = lines("remoteForwards", "\n")
        dynamic = lines("dynamicForwards", ", ")
        jump = s("jumpHost")
        noShell = o["noShell"].truthy
        extra = lines("extraOptions", "\n")
        reason = s("reason")
        invite = lines("invite", ", ")
        reqMode = HostsSSHOpts.requestModes.contains(s("requestMode")) ? s("requestMode") : ""
        reqReason = s("requestReason")
        noResume = o["noResume"].truthy
    }

    func collect() -> JSON {
        var j: JSON = ["x11": .string(x11), "localForwards": .string(local), "remoteForwards": .string(remote),
                       "dynamicForwards": .string(dynamic), "jumpHost": .string(jump), "extraOptions": .string(extra),
                       "noShell": .bool(noShell)]
        if teleport {
            j["reason"] = .string(reason)
            j["invite"] = .string(invite)
            j["requestMode"] = .string(reqMode)
            j["requestReason"] = .string(reqReason)
            j["noResume"] = .bool(noResume)
        }
        return j
    }
}

private struct SSHOptionsView: View {
    @ObservedObject var model: SSHOptionsModel
    let title: String
    let subtitle: String
    let focus: SSHOptionsUI.Focus?
    let window: WindowModel?
    let copy: () -> Void
    let done: (String?) -> Void
    @FocusState private var focused: SSHOptionsUI.Focus?

    private func sec(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Theme.shared.p.muted).padding(.top, 12).padding(.bottom, 4)
    }

    var body: some View {
        let p = Theme.shared.p
        let check = HostsSSHOpts.normalize(model.collect())
        let needsTsh = HostsSSHOpts.needsTsh(check.options.json)
        DialogScaffold(title: title, subtitle: subtitle, width: 640) {
            VStack(alignment: .leading, spacing: 0) {
                sec("Forwarding")
                MiscField(label: "X11") {
                    HSelect(options: [("off", "Off"), ("untrusted", "Untrusted (-X) — the safer one"),
                                      ("trusted", "Trusted (-Y) — for programs that need full access")],
                            selection: $model.x11)
                }
                MiscField(label: "Local forwards (-L)") {
                    HTextArea(text: $model.local, placeholder: "5432:db.internal:5432 — one per line", height: 44)
                }
                MiscField(label: "Remote forwards (-R)", hint: "A port on the host that reaches back to this machine") {
                    HTextArea(text: $model.remote, placeholder: "9000:localhost:3000 — port on the host : where it goes here", height: 44)
                        .focused($focused, equals: .remoteForwards)
                }
                HFieldRow {
                    MiscField(label: "SOCKS proxy port (-D)") {
                        HField(placeholder: "1080", text: $model.dynamic).focused($focused, equals: .dynamicForwards)
                    }
                    MiscField(label: "Jump host (-J)") {
                        HField(placeholder: "user@bastion, or a chain: bastion1,user@bastion2:22", text: $model.jump)
                    }
                }
                MiscCheck(label: "Forwarding only \u{2014} no shell (-N)", isOn: $model.noShell)
                Text("The pane holds the forwards open and runs nothing on the host \u{2014} a tunnel, not a shell.")
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .padding(.leading, 22).padding(.top, 2).padding(.bottom, 8)
                MiscField(label: "Other ssh options (-o)") {
                    VStack(alignment: .leading, spacing: 0) {
                        HTextArea(text: $model.extra, placeholder: "ServerAliveInterval=30 — any ssh -o option, one per line", height: 44)
                        SSHOptionPicker(text: $model.extra, window: window)
                    }
                }
                if model.teleport {
                    sec("Teleport")
                    MiscField(label: "Reason for the session (--reason)") {
                        HField(placeholder: "INC-1234: disk full on /var", text: $model.reason).focused($focused, equals: .reason)
                    }
                    MiscField(label: "Invite (--invite)", hint: "People to mark as invited to the session, to watch or moderate") {
                        HField(placeholder: "alice@example.com, bob", text: $model.invite)
                    }
                    HFieldRow {
                        MiscField(label: "If access is missing (--request-mode)") {
                            HSelect(options: [("", "Cluster default"), ("resource", "Request this node"),
                                              ("role", "Request a role"), ("off", "Never")], selection: $model.reqMode)
                        }
                        MiscField(label: "Request reason") {
                            HField(placeholder: "Why access is needed", text: $model.reqReason)
                        }
                    }
                    MiscCheck(label: "Do not resume the session after a network drop (--no-resume)", isOn: $model.noResume)
                }
                if model.teleport && needsTsh {
                    MiscHint(text: "A reason, invitations or automatic requests open this host over tsh ssh — OpenSSH has no flag for them.")
                        .padding(.top, 6)
                }
                if !check.errors.isEmpty {
                    Text(check.errors.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(p.red)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                if !check.warnings.isEmpty {
                    Text(check.warnings.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            // The same session as a command to paste into a terminal — the
            // options as they stand in the form, saved or not.
            Button("Copy command") { copy() }.buttonStyle(.ghost)
            Button("Save as a preset…") { done("preset") }.buttonStyle(.ghost)
            Button("Save as default") { done("default") }.buttonStyle(.ghost)
            Button("Open once") { done("once") }.buttonStyle(.primary)
        }
        .onAppear { if let focus { after(0.06) { focused = focus } } }
    }
}
