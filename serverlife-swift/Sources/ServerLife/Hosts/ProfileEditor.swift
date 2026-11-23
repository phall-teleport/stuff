import AppKit
import SwiftUI

/// profiles.js: the editor for one saved profile — SSH, Teleport, serial,
/// telnet, VNC and RDP in one record and one list — and the helpers the
/// lists use to describe one.
@MainActor
enum Profiles {
    /// The port a protocol uses when nobody has said otherwise.
    static func defaultPort(for type: String, initial: JSON = [:]) -> Int {
        if let d = initial["devicePort"].int, d != 0, initial["type"].string == type { return d }
        switch type {
        case "telnet": return 23
        case "vnc": return 5900
        case "rdp": return 3389
        default: return 22
        }
    }

    /// What a saved connection says about itself in a list (`profileMeta`).
    static func meta(_ p: JSON) -> String {
        let type = p["type"].string
        if type == "teleport" { return "\(p["node"].stringish ?? "null") @ \(p["cluster"].stringish ?? "null")" }
        if type == "sftp" {
            let user = p["user"].truthy ? (p["user"].stringish ?? "") + "@" : ""
            let port = p["port"].truthy ? (p["port"].stringish ?? "22") : "22"
            return "\(user)\(p["hostname"].truthy ? p["hostname"].stringish ?? "" : ""):\(port)"
        }
        if type == "serial" { return "\(p["path"].stringish ?? "") · \(p["baudRate"].truthy ? p["baudRate"].stringish ?? "" : "115200")" }
        if type == "telnet" || type == "vnc" || type == "rdp" {
            let port = p["devicePort"].truthy ? (p["devicePort"].stringish ?? "") : String(defaultPort(for: type ?? "", initial: p))
            return "\(p["host"].stringish ?? ""):\(port)"
        }
        return hostsOr(p["alias"], hostsOr(p["hostname"], "")).stringish ?? ""
    }

    /// sidebar.js `profileKindLabel`.
    static func kindLabel(_ p: JSON) -> String {
        ["teleport": "tsh", "sftp": "sftp", "serial": "serial", "telnet": "telnet", "vnc": "vnc", "rdp": "rdp"][p["type"].string ?? ""] ?? "ssh"
    }

    /// `openProfileEditor(initial)`: `initial` is a stored profile (edit) or
    /// a partial one (new). Calls `onSaved` with the stored record.
    static func openEditor(_ window: WindowModel?, initial: JSON = [:], onSaved: ((JSON) -> Void)? = nil) {
        let model = ProfileEditorModel(window: window, initial: initial)
        Modal.sheet(window, title: model.isEdit ? "Edit profile" : "New profile", width: 600) { handle in
            ProfileEditorView(model: model) { result in
                handle.close()
                guard let result else { return }
                let saved = HostsData.upsertProfile(result)
                StatusBus.shared.show("Saved profile “\(saved["name"].stringish ?? "")”")
                onSaved?(saved)
            }
        }
        model.loadPorts()
    }
}

@MainActor
final class ProfileEditorModel: ObservableObject {
    weak var window: WindowModel?
    let initial: JSON
    var isEdit: Bool { initial["id"].truthy }

    @Published var name: String
    @Published var type: String { didSet { if type != oldValue { syncType() } } }
    // ssh
    @Published var alias: String
    @Published var user: String
    @Published var jump: String
    @Published var hostname: String
    @Published var port: String
    /// ssh -o lines for SSH and Teleport profiles, on top of the host's own options.
    @Published var sshExtra: String
    // sftp: a standalone server, dialled directly — never an ssh_config alias.
    @Published var sftpHost: String
    @Published var sftpUser: String
    @Published var sftpPort: String
    @Published var sftpJump: String
    @Published var sftpKey: String
    @Published var sftpExtra: String
    // kube: a kubeconfig context, the namespace to start in, the view to open on.
    @Published var kubeContext: String
    @Published var kubeContexts: [JSON] = []
    @Published var kubeLoaded = false
    @Published var kubeNamespace: String
    @Published var kubeView: String
    // teleport
    @Published var clusterKey: String
    @Published var node: String
    @Published var login: String
    // serial
    @Published var devPath: String
    @Published var portPick = "" { didSet { if !portPick.isEmpty { devPath = portPick } } }
    @Published var ports: [SerialPortInfo] = []
    @Published var baud: String
    @Published var dataBits: String
    @Published var parity: String
    @Published var stopBits: String
    @Published var flow: String
    // telnet / vnc / rdp
    @Published var devHost: String
    @Published var devPort: String
    var devPortAuto = true
    var lastAutoPort: String?
    @Published var newline: String { didSet { if !settingNewline { newlineAuto = false } } }
    var newlineAuto = true
    var settingNewline = false
    @Published var localEcho: Bool
    @Published var viewOnly: Bool
    @Published var scaling: String
    @Published var quality: String
    @Published var rdpUser: String
    @Published var rdpDomain: String
    @Published var rdpFull: Bool
    @Published var rdpWidth: String
    @Published var rdpHeight: String
    @Published var rdpClip: Bool
    @Published var rdpDrives: Bool
    @Published var rdpGateway: String
    // shared
    @Published var folderId: String
    @Published var startCmd: String
    @Published var remotePath: String
    @Published var localPath: String

    let clusterOptions: [(value: String, label: String)]
    let folderOptions: [(value: String, label: String)]

    init(window: WindowModel?, initial i: JSON) {
        self.window = window
        self.initial = i
        func s(_ k: String) -> String { i[k].truthy ? (i[k].stringish ?? "") : "" }
        let t = i["type"].string ?? "ssh"
        name = s("name")
        type = t
        alias = s("alias")
        user = s("user")
        jump = i["proxyJump"].truthy ? s("proxyJump") : (i["direct"]["proxyJump"].stringish ?? "")
        hostname = i["hostname"].truthy ? s("hostname") : (i["direct"]["hostname"].stringish ?? "")
        port = String(i["port"].int.flatMap { $0 != 0 ? $0 : nil } ?? i["direct"]["port"].int.flatMap { $0 != 0 ? $0 : nil } ?? 22)
        // A new profile starts with the defaults any picker set ("Use for new
        // hosts by default"), written Name=value as -o wants.
        let defaults = SSHPresets.defaultSshOptions
        if let v = i["sshExtraOptions"].string { sshExtra = v }
        else if i["id"].truthy { sshExtra = "" }
        else {
            sshExtra = defaults.replacingOccurrences(of: #"(?m)^(\S+)\s+(.*)$"#, with: "$1=$2", options: .regularExpression)
        }
        let d = i["direct"]
        func ds(_ k: String) -> String { d[k].truthy ? (d[k].stringish ?? "") : "" }
        sftpHost = ds("hostname")
        sftpUser = ds("user")
        sftpPort = String(d["port"].int.flatMap { $0 != 0 ? $0 : nil } ?? 22)
        sftpJump = ds("proxyJump")
        sftpKey = ds("identityFile")
        sftpExtra = d["extraOptions"].string ?? (i["id"].truthy ? "" : defaults)
        kubeContext = i["kube"]["spec"]["contextName"].string ?? ""
        kubeNamespace = i["kube"]["namespace"].truthy ? (i["kube"]["namespace"].stringish ?? "") : ""
        if let v = i["kube"]["view"].string { kubeView = v }
        else if let k = i["kube"]["view"]["kind"].string, !k.isEmpty { kubeView = "kind:" + k }
        else { kubeView = "" }

        let profiles = Inventory.shared.profiles
        clusterOptions = profiles.map { p in
            (p.key, "\(p.cluster)\(p.homeName.isEmpty ? "" : " · " + p.homeName)\(p.expired ? " (expired)" : "")")
        }
        let wanted = TeleportProfile.key(cluster: i["cluster"].string, proxy: nil, home: i["home"].string)
        let fallback = profiles.first?.key ?? ""
        let pick = wanted.isEmpty ? fallback : wanted
        clusterKey = profiles.contains { $0.key == pick } ? pick : fallback
        node = s("node")
        login = s("login")

        devPath = s("path")
        baud = i["baudRate"].truthy ? s("baudRate") : "115200"
        dataBits = i["dataBits"].truthy ? s("dataBits") : "8"
        parity = i["parity"].truthy ? s("parity") : "none"
        stopBits = i["stopBits"].truthy ? s("stopBits") : "1"
        flow = i["rtscts"].truthy ? "rtscts" : (i["xon"].truthy ? "xonxoff" : "none")

        devHost = s("host")
        devPort = i["devicePort"].truthy ? s("devicePort") : String(Profiles.defaultPort(for: t, initial: i))
        newline = i["newline"].truthy ? s("newline") : (t == "telnet" ? "crlf" : "cr")
        localEcho = i["localEcho"].truthy
        viewOnly = i["viewOnly"].truthy
        scaling = i["scaling"].truthy ? s("scaling") : "scale"
        quality = i["quality"].isNull ? "6" : (i["quality"].stringish ?? "6")
        rdpUser = s("username")
        rdpDomain = s("domain")
        rdpFull = i["fullscreen"].truthy
        rdpWidth = i["width"].truthy ? s("width") : "1440"
        rdpHeight = i["height"].truthy ? s("height") : "900"
        rdpClip = i["clipboard"] != .bool(false)
        rdpDrives = i["drives"].truthy
        rdpGateway = s("gateway")

        folderOptions = [("", "Ungrouped")] + HostsData.profileFolders.map { ($0["id"].stringish ?? "", $0["name"].stringish ?? "") }
        let fid = s("folderId")
        folderId = folderOptions.contains { $0.value == fid } ? fid : ""
        startCmd = i["startupCommand"].string ?? ""
        remotePath = s("remoteStartPath")
        localPath = s("localStartPath")
        syncType()
    }

    func loadPorts() {
        Task { @MainActor in ports = await DeviceSessions.shared.listPorts() }
        Task { @MainActor in
            let extra: [String] = Store.shared.setting("kubeconfigPaths", [String]())
            let r = await Kube.listContexts(extraPaths: extra)
            kubeContexts = r["contexts"].items
            kubeLoaded = true
        }
    }

    /// Opened through the same check a restored kube tab gets: the context
    /// list as kubeconfig has it now, plus the saved one if it went away.
    var kubeContextOptions: [(value: String, label: String)] {
        if !kubeLoaded { return [("", "Reading the kubeconfig…")] }
        var out: [(value: String, label: String)] = [("", kubeContexts.isEmpty ? "No contexts in the kubeconfig" : "Pick a context…")]
        for c in kubeContexts {
            let name = c["contextName"].stringish ?? ""
            let label = c["source"].string == "teleport"
                ? "\(c["kubeClusterName"].string?.nilIfEmpty ?? c["name"].stringish ?? "")  —  Teleport \(c["teleportCluster"].string?.nilIfEmpty ?? c["teleportProxy"].stringish ?? "")"
                : name
            out.append((name, label))
        }
        let want = initial["kube"]["spec"]["contextName"].string ?? ""
        if !want.isEmpty && !kubeContexts.contains(where: { $0["contextName"].string == want }) {
            out.append((want, "\(want) (not in the kubeconfig now)"))
        }
        return out
    }

    func browseSftpKey() {
        Task { @MainActor in if let p = await SSHConfig.pickKey(window: window) { sftpKey = p } }
    }

    var portOptions: [(value: String, label: String)] {
        [("", "Ports found now…")] + ports.map { ($0.path, $0.label.isEmpty ? $0.path : "\($0.path) — \($0.label)") }
    }

    /// A port typed into stops following the protocol.
    func devPortEdited() {
        if devPort != lastAutoPort { devPortAuto = false }
    }

    /// What follows the type: a port nobody has typed into, and what Enter
    /// sends until someone says otherwise.
    func syncType() {
        if devPortAuto {
            let v = String(Profiles.defaultPort(for: type, initial: initial))
            lastAutoPort = v
            devPort = v
        }
        if newlineAuto {
            settingNewline = true
            newline = initial["newline"].truthy ? (initial["newline"].string ?? "cr") : (type == "telnet" ? "crlf" : "cr")
            settingNewline = false
        }
    }

    var clusterProfile: TeleportProfile? { Inventory.shared.profiles.first { $0.key == clusterKey } }

    var showSsh: Bool { type == "ssh" }
    var showTeleport: Bool { type == "teleport" }
    var showSerial: Bool { type == "serial" }
    var showNet: Bool { ["telnet", "vnc", "rdp"].contains(type) }
    var showLine: Bool { type == "serial" || type == "telnet" }
    /// A startup command belongs to a shell, not a screen or a files-only sftp profile.
    var showStartCmd: Bool { !["vnc", "rdp", "sftp", "kube"].contains(type) }
    /// A start folder is relevant to anything with a filesystem.
    var showPaths: Bool { ["ssh", "teleport", "sftp"].contains(type) }
    var showSshOpts: Bool { type == "ssh" || type == "teleport" }

    /// Validate and build the record, or toast why not.
    func result() -> JSON? {
        let t = type
        func trimmedOrNull(_ s: String) -> JSON { s.trimmed.isEmpty ? .null : .string(s.trimmed) }
        func int(_ s: String) -> JSON { QuickConnect.parseInt(s).map { JSON($0) } ?? .null }
        if name.trimmed.isEmpty { HToast.error("Name is required"); return nil }
        // An alias or a hostname: one of the two has to say where to connect.
        if t == "ssh" && alias.trimmed.isEmpty && hostname.trimmed.isEmpty {
            HToast.error("Give an ssh_config alias, or a hostname to dial directly"); return nil
        }
        if t == "teleport" && node.trimmed.isEmpty { HToast.error("Node hostname is required"); return nil }
        if t == "sftp" && sftpHost.trimmed.isEmpty { HToast.error("Hostname is required for an SFTP profile"); return nil }
        if t == "serial" && devPath.trimmed.isEmpty { HToast.error("Name the serial port"); return nil }
        if t == "kube" && kubeContext.isEmpty { HToast.error("Pick a kubeconfig context"); return nil }
        if ["telnet", "vnc", "rdp"].contains(t) && devHost.trimmed.isEmpty { HToast.error("Host is required"); return nil }

        let sshPort = QuickConnect.parseInt(port).flatMap { $0 != 0 ? $0 : nil } ?? 22
        let net = ["telnet", "vnc", "rdp"].contains(t)
        let line = ["serial", "telnet"].contains(t)
        let cp = clusterProfile
        var r: JSON = [:]
        r["id"] = initial["id"].truthy ? initial["id"] : .null
        if r["id"].isNull { r.removeKey("id") }
        r["name"] = .string(name.trimmed)
        r["type"] = .string(t)
        r["folderId"] = folderId.isEmpty ? .null : .string(folderId)
        r["alias"] = trimmedOrNull(alias)
        let sftpP = QuickConnect.parseInt(sftpPort).flatMap { $0 != 0 ? $0 : nil } ?? 22
        r["user"] = t == "sftp" ? trimmedOrNull(sftpUser) : trimmedOrNull(user)
        r["hostname"] = t == "ssh" ? trimmedOrNull(hostname) : t == "sftp" ? .string(sftpHost.trimmed) : .null
        r["port"] = t == "ssh" ? JSON(sshPort) : t == "sftp" ? JSON(sftpP) : .null
        r["proxyJump"] = t == "ssh" ? trimmedOrNull(jump) : t == "sftp" ? trimmedOrNull(sftpJump) : .null
        r["sshExtraOptions"] = t == "ssh" || t == "teleport" ? trimmedOrNull(sshExtra) : .null
        // A profile with a hostname of its own needs no ssh_config entry, so
        // it carries what a connection needs; one with only an alias lets
        // ssh_config answer (the jump host goes as -J either way).
        r["direct"] = t == "ssh" && !hostname.trimmed.isEmpty ? [
            "hostname": .string(hostname.trimmed),
            "user": trimmedOrNull(user),
            "port": JSON(sshPort),
            "identityFile": hostsOr(initial["direct"]["identityFile"], .null),
            "proxyJump": trimmedOrNull(jump),
            "extraOptions": hostsOr(initial["direct"]["extraOptions"], ""),
        ] : t == "sftp" ? [
            "hostname": .string(sftpHost.trimmed),
            "user": trimmedOrNull(sftpUser),
            "port": JSON(sftpP),
            "identityFile": trimmedOrNull(sftpKey),
            "proxyJump": trimmedOrNull(sftpJump),
            "extraOptions": .string(sftpExtra),
            // No key given means this is meant to be reached by password —
            // see directArgs() in connections.js. Without this, a loaded
            // ssh-agent's keys get offered first, and a dedicated SFTP
            // account's sshd commonly disconnects with "Too many
            // authentication failures" before ssh ever reaches the
            // password prompt.
            "identitiesOnly": .bool(sftpKey.trimmed.isEmpty),
        ] : .null
        r["cluster"] = t == "teleport" ? JSON(cp?.cluster.nilIfEmpty) : .null
        r["proxy"] = t == "teleport" ? JSON(cp?.proxy.nilIfEmpty) : .null
        r["home"] = t == "teleport" ? JSON(cp?.home) : .null
        r["node"] = trimmedOrNull(node)
        r["login"] = trimmedOrNull(login)
        r["startupCommand"] = .string(startCmd)
        r["remoteStartPath"] = .string(remotePath.trimmed)
        r["localStartPath"] = .string(localPath.trimmed)

        r["path"] = t == "serial" ? .string(devPath.trimmed) : .null
        r["baudRate"] = t == "serial" ? int(baud) : .null
        r["dataBits"] = t == "serial" ? int(dataBits) : .null
        r["parity"] = t == "serial" ? .string(parity) : .null
        r["stopBits"] = t == "serial" ? int(stopBits) : .null
        r["rtscts"] = t == "serial" ? .bool(flow == "rtscts") : .null
        r["xon"] = t == "serial" ? .bool(flow == "xonxoff") : .null
        r["xoff"] = t == "serial" ? .bool(flow == "xonxoff") : .null

        r["host"] = net ? .string(devHost.trimmed) : .null
        r["devicePort"] = net ? JSON(QuickConnect.parseInt(devPort).flatMap { $0 != 0 ? $0 : nil }
                                     ?? Profiles.defaultPort(for: t)) : .null
        r["newline"] = line ? .string(newline) : .null
        r["localEcho"] = line ? .bool(localEcho) : .null

        r["viewOnly"] = t == "vnc" ? .bool(viewOnly) : .null
        r["scaling"] = t == "vnc" ? .string(scaling) : .null
        r["quality"] = t == "vnc" ? int(quality) : .null

        r["username"] = t == "rdp" ? trimmedOrNull(rdpUser) : .null
        r["domain"] = t == "rdp" ? trimmedOrNull(rdpDomain) : .null
        r["fullscreen"] = t == "rdp" ? .bool(rdpFull) : .null
        r["width"] = t == "rdp" ? int(rdpWidth) : .null
        r["height"] = t == "rdp" ? int(rdpHeight) : .null
        r["clipboard"] = t == "rdp" ? .bool(rdpClip) : .null
        r["drives"] = t == "rdp" ? .bool(rdpDrives) : .null
        r["gateway"] = t == "rdp" ? trimmedOrNull(rdpGateway) : .null
        if t == "kube" {
            // Everything needed to find the cluster again, not just the
            // context name — which a tsh logout deletes.
            let spec: JSON
            if let c = kubeContexts.first(where: { $0["contextName"].string == kubeContext }) {
                spec = ["kubeconfigPaths": c["kubeconfigPaths"].truthy ? c["kubeconfigPaths"] : .array([]),
                        "contextName": .string(kubeContext),
                        "teleportProxy": hostsOr(c["teleportProxy"], .null),
                        "kubeClusterName": hostsOr(c["kubeClusterName"], .null),
                        "teleportCluster": hostsOr(c["teleportCluster"], .null)]
            } else {
                var s0 = initial["kube"]["spec"].object.map { JSON.object($0) } ?? [:]
                s0["contextName"] = .string(kubeContext)
                spec = s0
            }
            let v = kubeView
            r["kube"] = ["spec": spec, "namespace": trimmedOrNull(kubeNamespace),
                         "view": v.hasPrefix("kind:") ? ["kind": .string(String(v.dropFirst(5)))] : (v.isEmpty ? .null : .string(v))]
        } else {
            r["kube"] = .null
        }
        return r
    }
}

private struct ProfileEditorView: View {
    @ObservedObject var model: ProfileEditorModel
    let done: (JSON?) -> Void

    var body: some View {
        DialogScaffold(title: model.isEdit ? "Edit profile" : "New profile", width: 600) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Name") { HField(placeholder: "My server", text: $model.name) }
                MiscField(label: "Type") {
                    HSelect(options: [
                        ("ssh", "SSH (ssh_config host)"), ("teleport", "Teleport node"), ("sftp", "SFTP (standalone server)"),
                        ("serial", "Serial console"), ("telnet", "Telnet"), ("vnc", "VNC screen"), ("rdp", "Remote Desktop (RDP)"),
                        ("kube", "Kubernetes cluster (kubeconfig context)"),
                    ], selection: $model.type)
                }
                if model.showSsh { sshBlock }
                if model.showTeleport { tpBlock }
                if model.showSshOpts {
                    MiscField(label: "SSH options",
                              hint: "Passed as ssh -o, one per line — pick a common one (only one key file, no keys, no agent…) or type your own") {
                        VStack(alignment: .leading, spacing: 0) {
                            HTextArea(text: $model.sshExtra, placeholder: "IdentitiesOnly=yes\nServerAliveInterval=30")
                            SSHOptionPicker(text: $model.sshExtra, window: model.window)
                        }
                    }
                }
                if model.type == "kube" { kubeBlock }
                if model.type == "sftp" { sftpBlock }
                if model.showSerial { serialBlock }
                if model.showNet {
                    HFieldRow {
                        MiscField(label: "Host") { HField(placeholder: "10.0.0.5 or console.example.com", text: $model.devHost) }
                        MiscField(label: "Port") { HNumberField(text: $model.devPort) { model.devPortEdited() } }
                    }
                }
                if model.type == "vnc" { vncBlock }
                if model.type == "rdp" { rdpBlock }
                if model.showLine {
                    MiscField(label: "Enter sends") {
                        HSelect(options: [
                            ("cr", "CR — most network gear"), ("lf", "LF — most Unix consoles"),
                            ("crlf", "CRLF — telnet default, and some appliances"),
                        ], selection: $model.newline)
                    }
                    MiscCheck(label: "Show what I type (local echo)", isOn: $model.localEcho)
                }
                MiscField(label: "Folder") { HSelect(options: model.folderOptions, selection: $model.folderId) }
                if model.showStartCmd {
                    MiscRule().padding(.top, 4)
                    MiscField(label: "Startup command", hint: "Sent to the session once it is open") {
                        HTextArea(text: $model.startCmd, placeholder: "e.g. sudo -i\ntail -f /var/log/syslog", height: 58)
                    }
                }
                if model.showPaths {
                    HFieldRow {
                        MiscField(label: "Remote start folder") { HField(placeholder: "/var/log", text: $model.remotePath) }
                        MiscField(label: "Local start folder") { HField(placeholder: "~/Downloads", text: $model.localPath) }
                    }
                }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(model.isEdit ? "Save" : "Create") { if let r = model.result() { done(r) } }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .frame(maxHeight: 760)
    }

    private var sshBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "SSH host alias", hint: "Must match a Host entry in ~/.ssh/config, unless a hostname is given below") {
                HField(placeholder: "host alias from ~/.ssh/config", text: $model.alias)
            }
            HFieldRow {
                MiscField(label: "Login user (optional)") { HField(placeholder: "optional override", text: $model.user) }
                MiscField(label: "Jump host (ProxyJump, optional)") {
                    HField(placeholder: "bastion.example.com, or user@bastion:2222", text: $model.jump)
                }
            }
            HFieldRow {
                MiscField(label: "Hostname (optional)") { HField(placeholder: "optional — dial this directly", text: $model.hostname) }
                MiscField(label: "Port") { HNumberField(text: $model.port) }
            }
        }
    }

    private var kubeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "Context", hint: "From your kubeconfig — Add a kubeconfig… in the sidebar reads more files") {
                HSelect(options: model.kubeContextOptions, selection: $model.kubeContext)
            }
            HFieldRow {
                MiscField(label: "Start in namespace") { HField(placeholder: "all namespaces", text: $model.kubeNamespace) }
                MiscField(label: "Open on") {
                    HSelect(options: [("", "Overview"), ("kind:pods", "Pods"), ("kind:deployments", "Deployments"),
                                      ("helm", "Helm releases"), ("3d", "3D view"), ("starred", "Starred")],
                            selection: $model.kubeView)
                }
            }
        }
    }

    // No password field, on purpose: ServerLife keeps its settings in a plain
    // file, and a stored password in one is a password in every backup of it.
    private var sftpBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HFieldRow {
                MiscField(label: "Hostname or IP") { HField(placeholder: "sftp.example.com or 10.0.0.5", text: $model.sftpHost) }
                MiscField(label: "Port") { HNumberField(text: $model.sftpPort) }
            }
            HFieldRow {
                MiscField(label: "User") { HField(placeholder: "ubuntu", text: $model.sftpUser) }
                MiscField(label: "Jump host (ProxyJump, optional)") {
                    HField(placeholder: "bastion.example.com (optional)", text: $model.sftpJump)
                }
            }
            MiscField(label: "Private key", hint: "Optional — leave it blank to connect by password instead") {
                HStack(spacing: 6) {
                    HField(placeholder: "~/.ssh/id_ed25519 (optional)", text: $model.sftpKey)
                    Button("Browse…") { model.browseSftpKey() }.buttonStyle(.ghostSmall)
                }
            }
            MiscField(label: "Extra ssh options", hint: "One per line, as they appear in ssh_config — pick a common one, or type your own") {
                VStack(alignment: .leading, spacing: 0) {
                    HTextArea(text: $model.sftpExtra, placeholder: "ServerAliveInterval 30\nForwardAgent yes")
                    SSHOptionPicker(text: $model.sftpExtra, format: "config", window: model.window)
                }
            }
            MiscHint(text: "The password, if this server needs one, is asked for when you connect "
                     + "and is not saved here \u{2014} ServerLife keeps its settings in a plain "
                     + "file, and a stored password in one is a password in every backup of "
                     + "it. With no private key given, your other ssh keys are skipped too, "
                     + "so a dedicated SFTP account does not refuse the connection before "
                     + "the password prompt is even reached.").padding(.top, 8).padding(.bottom, 10)
        }
    }

    private var tpBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "Cluster") { HSelect(options: model.clusterOptions, selection: $model.clusterKey) }
            MiscField(label: "Node hostname") { HField(placeholder: "node hostname", text: $model.node) }
            MiscField(label: "Login") { HField(placeholder: "ubuntu", text: $model.login) }
        }
    }

    private var serialBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "Serial port", hint: "The device file for the adapter — it does not have to be plugged in to save this") {
                HField(placeholder: "/dev/tty.usbserial-1410 or COM3", text: $model.devPath)
            }
            MiscField(label: "Ports on this machine now") { HSelect(options: model.portOptions, selection: $model.portPick) }
            HFieldRow {
                MiscField(label: "Speed") {
                    HSelect(options: [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600].map { (String($0), String($0)) },
                            selection: $model.baud)
                }
                MiscField(label: "Data bits") { HSelect(options: ["8", "7", "6", "5"].map { ($0, $0) }, selection: $model.dataBits) }
                MiscField(label: "Parity") {
                    HSelect(options: [("none", "None"), ("even", "Even"), ("odd", "Odd")], selection: $model.parity)
                }
                MiscField(label: "Stop bits") { HSelect(options: [("1", "1"), ("2", "2")], selection: $model.stopBits) }
            }
            MiscField(label: "Flow control", hint: "Hardware flow control on a console cable that has no CTS wire looks exactly "
                      + "like a dead port — leave it off unless the device asks for it") {
                HSelect(options: [("none", "None"), ("rtscts", "Hardware (RTS/CTS)"), ("xonxoff", "Software (XON/XOFF)")],
                        selection: $model.flow)
            }
        }
    }

    private var vncBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "Display") {
                HSelect(options: [("scale", "Scale the screen to fit the pane"), ("resize", "Ask the server to match the pane"),
                                  ("none", "Full size, scroll to see the rest")], selection: $model.scaling)
            }
            MiscField(label: "Picture quality") {
                HSelect(options: ["9", "8", "6", "4", "2", "0"].map { v in
                    (v, v + (v == "9" ? " — best picture" : v == "0" ? " — smallest" : ""))
                }, selection: $model.quality)
            }
            MiscCheck(label: "View only — watch without touching anything", isOn: $model.viewOnly)
            MiscHint(text: "The password is asked for when you connect and is not saved here \u{2014} "
                     + "ServerLife keeps its settings in a plain file, and a VNC password in one "
                     + "is a VNC password in every backup of it.").padding(.top, 8).padding(.bottom, 10)
        }
    }

    private var rdpBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HFieldRow {
                MiscField(label: "User") { HField(placeholder: "Administrator", text: $model.rdpUser) }
                MiscField(label: "Domain") { HField(placeholder: "CORP (optional)", text: $model.rdpDomain) }
            }
            MiscCheck(label: "Open full screen", isOn: $model.rdpFull)
            HFieldRow {
                MiscField(label: "Width") { HNumberField(text: $model.rdpWidth) }
                MiscField(label: "Height") { HNumberField(text: $model.rdpHeight) }
            }
            MiscCheck(label: "Share the clipboard", isOn: $model.rdpClip)
            MiscCheck(label: "Share my home folder as a drive", isOn: $model.rdpDrives)
            MiscField(label: "RD Gateway") { HField(placeholder: "rdgateway.example.com (optional)", text: $model.rdpGateway) }
            MiscHint(text: "Opens in this machine\u{2019}s own Remote Desktop client with these settings. "
                     + "RDP is not drawn inside ServerLife: it is a bundle of virtual channels \u{2014} "
                     + "drives, printers, smart cards, audio \u{2014} and half an implementation of it "
                     + "would be worse than the client the platform already has.").padding(.top, 8).padding(.bottom, 10)
        }
    }
}
