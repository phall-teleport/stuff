import SwiftUI

/// What the New Phase form collected (beams.js `newPhase` `collect()`).
struct PhaseAddRequest {
    var name: String?
    var from: String?
    var forkFrom: String?
    var commandsFile: String?
    var copies: [PhaseCopy]?
    var noConsole = false
    var roles: [String] = []
    var region: String?
}

@MainActor
final class PhaseNewModel: ObservableObject {
    let profile: TeleportProfile
    let can: BeamAddSupport
    let myRoles: [String]
    @Published var name = ""
    @Published var mode: String
    @Published var build = "console"
    @Published var commandsFile = ""
    @Published var region = ""
    @Published var roleOn: Set<String> = []
    @Published var preview = ""
    let copies = PhaseCopyRows(blank: true)
    let source: PhasePickerModel

    init(profile: TeleportProfile, can: BeamAddSupport, mode: String, source: String) {
        self.profile = profile; self.can = can
        self.mode = ["base", "from", "fork"].contains(mode) ? mode : "base"
        myRoles = can.roles ? profile.roles.sorted() : []
        // Typed as well as picked: --from takes an upstream image such as
        // default:v1, and either takes name@sha256:digest for one exact snapshot.
        self.source = PhasePickerModel(profile: profile, phases: PhaseRuns.phases(profile).filter { $0.state == "ready" },
                                       value: source, typed: true)
        self.source.onChange = { [weak self] _ in self?.sync() }
        sync()
    }

    var nameError: String { BeamsUI.phaseNameProblem(name.trimmed) }

    func collect() -> PhaseAddRequest {
        let src = source.value.trimmed.nilIfEmpty
        return PhaseAddRequest(
            name: name.trimmed.nilIfEmpty,
            from: mode == "from" ? src : nil,
            forkFrom: mode == "fork" ? src : nil,
            commandsFile: mode != "fork" && build == "file" ? commandsFile.trimmed.nilIfEmpty : nil,
            copies: mode != "fork" && build == "copy" ? copies.copies : nil,
            // Whenever tsh can skip its own console, it always does: this app joins
            // the build Beam as an ordinary session instead (see startHeadless).
            noConsole: can.noConsole,
            roles: myRoles.filter { roleOn.contains($0) },
            region: region.nilIfEmpty)
    }

    static func args(_ p: TeleportProfile, _ r: PhaseAddRequest) throws -> [String] {
        try Beams.phaseAddArgs(proxy: p.proxy, name: r.name, from: r.from, forkFrom: r.forkFrom, commandsFile: r.commandsFile,
                               copies: r.copies ?? [], noConsole: r.noConsole, roles: r.roles, region: r.region)
    }

    func sync() {
        // A fork is always a console; a command file only applies to the others.
        if mode == "fork" && build != "console" { build = "console" }
        do { preview = (["tsh"] + (try Self.args(profile, collect()))).joined(separator: " ") }
        catch { preview = error.localizedDescription }
    }

    /// "Start the build": the checks, in the original's order; nil when it may go.
    func problem() -> String? {
        let v = collect()
        let np = BeamsUI.phaseNameProblem(v.name ?? "")
        if !np.isEmpty { return np }
        if mode != "base" && v.from == nil && v.forkFrom == nil { return "Which Phase?" }
        if build == "file" && mode != "fork" && v.commandsFile == nil { return "Which command file?" }
        if build == "copy" && mode != "fork" && (v.copies ?? []).isEmpty { return "Which files?" }
        return nil
    }
}

struct PhaseNewView: View {
    @ObservedObject var m: PhaseNewModel
    let switchToBuilder: () -> Void

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 10) {
            /*
             * The other way to make one: tools, services and files picked as
             * setups and built with tsh phase apply — said here, where someone
             * about to install things by hand in a console would want to know.
             */
            if m.can.apply {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Installing tools or services? Pick them as setups — Go, Postgres, cloud CLIs, your dotfiles — and they are rebuilt for you.")
                        .font(.system(size: 11)).foregroundStyle(p.textDim).fixedSize(horizontal: false, vertical: true)
                    Button("Build it from setups instead\u{2026}", action: switchToBuilder)
                        .buttonStyle(.ghost).controlSize(.small).help("Build a Phase from setups (tsh phase apply)")
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }
            FormRow(label: "Name") {
                TextField("Leave empty and tsh picks a name", text: $m.name).textFieldStyle(.roundedBorder)
                    .onChange(of: m.name) { _, _ in m.sync() }
            }
            Text(m.nameError).font(.system(size: 11)).foregroundStyle(p.red).frame(minHeight: 12, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            FormRow(label: "Start from") {
                Picker("", selection: $m.mode) {
                    Text("The default base image").tag("base")
                    Text("Build on top of a Phase (--from)").tag("from")
                    Text("Fork a Phase\u{2019}s saved files (--fork-from)").tag("fork")
                }.labelsHidden().onChange(of: m.mode) { _, _ in m.sync() }
            }
            if m.mode != "base" {
                FormRow(label: "Phase", hint: "Pick one of yours — your folders, or search — or type any Phase, upstream image (default:v1) or exact snapshot.") {
                    PhasePickerView(m: m.source)
                }
            }
            FormRow(label: "Build it") {
                Picker("", selection: $m.build) {
                    Text("In an interactive build console").tag("console")
                    Text("From a command file (--commands-file)").tag("file")
                    if m.can.copy { Text("Copy files from this computer (--copy)").tag("copy") }
                }.labelsHidden().disabled(m.mode == "fork").onChange(of: m.build) { _, _ in m.sync() }
            }
            if m.build == "file" { commandFileRow }
            if m.build == "copy" {
                FormRow(label: "Files to copy", hint: "From this computer (left) to an absolute path in the image outside /home (right). A folder merges into its destination.") {
                    PhaseCopyRowsView(m: m.copies) { m.sync() }
                }
            }
            if !m.myRoles.isEmpty {
                FormRow(label: "Delegate roles", hint: "The roles its builds may act as. None ticked: your own delegation permissions.") {
                    PhaseFlow(items: m.myRoles) { r in
                        Toggle(r, isOn: Binding(get: { m.roleOn.contains(r) },
                                                set: { on in if on { m.roleOn.insert(r) } else { m.roleOn.remove(r) }; m.sync() }))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            FormRow(label: "Region", hint: "Where the build runs, and where the Phase is kept.") {
                Picker("", selection: $m.region) {
                    ForEach(BeamsUI.regions, id: \.value) { r in Text(r.label).tag(r.value) }
                }.labelsHidden().onChange(of: m.region) { _, _ in m.sync() }
            }
            Text(m.can.noConsole
                 ? "Opens straight into a session on its build Beam — file browser included. Install what the image needs there, then run tsh phase snapshot --final to save it and end the build. A command file runs on its own; join just to watch its log if you want to."
                 : "Runs in a new tab. In a console: install what the image needs, then run tsh phase snapshot --final to save it and end the build. From a file: the log streams there.")
                .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            Text(m.preview).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.textDim)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
        }
    }

    private var commandFileRow: some View {
        FormRow(label: "Command file", hint: "Commands run in order as root, outside /home. Each takes command and args (and optionally env, "
                + "workdir, comment) — e.g. command: /bin/sh, args: [-c, \"apt-get install -y git\"]. "
                + "shell: is only for tsh phase apply files.") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("/path/to/build.yaml", text: $m.commandsFile).textFieldStyle(.roundedBorder)
                    .onChange(of: m.commandsFile) { _, _ in m.sync() }
                Button("Browse\u{2026}") {
                    Task { @MainActor in
                        if let f = await Modal.openFiles(multiple: false, title: "Choose the command file (YAML)").first {
                            m.commandsFile = f.path; m.sync()
                        }
                    }
                }.buttonStyle(.ghost).controlSize(.small)
            }
        }
    }
}

/// Checkboxes that wrap (`display:flex;flex-wrap:wrap`).
struct PhaseFlow<Item: Hashable, V: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> V
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}
