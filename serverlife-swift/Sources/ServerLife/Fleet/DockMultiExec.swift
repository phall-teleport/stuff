import AppKit
import SwiftUI

/// The Multi-Exec panel: Command / Macros / Recent runs, the target choice
/// (ticks or a tag query), who it runs as, the hosts that could not be dialled,
/// and the runs streaming back per host.
struct DockMultiExecPanel: View {
    let window: WindowModel

    var body: some View {
        let fw = window.feature(FleetWindow.self)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let nSched = MXSchedules.all.count
                FleetTabs(tabs: [("command", "Command"), ("macros", "Macros"), ("history", "Recent runs"),
                                 ("scheduled", "Scheduled" + (nSched > 0 ? " (\(nSched))" : ""))],
                          selection: Binding(get: { fw.mxView }, set: { fw.mxView = $0 }))
                    .padding(.bottom, 8)
                /*
                 * Two ways to say what to run: type it, or pick a macro. They share
                 * the "run as" login and the host selection, so the tabs swap only
                 * the part that differs.
                 */
                switch fw.mxView {
                case "macros": MXMacroPicker(window: window, fw: fw)
                case "history": MXHistory(window: window, fw: fw)
                case "scheduled": MXSchedulesView(window: window, fw: fw).padding(.bottom, 8)
                default: MXCommandForm(window: window, fw: fw)
                }
                MXSelectorRow(window: window, fw: fw)
                MXTargetsView(fw: fw)
                MXAdvanced(fw: fw)
                if let f = fw.lastFailed, !f.hosts.isEmpty { MXFailedBox(fw: fw, failed: f) }
                ForEach(MultiExecService.shared.runs) { run in MXRunView(window: window, fw: fw, run: run) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The command line: command, run as, Run, Save YAML…, Load YAML…, Ansible….
private struct MXCommandForm: View {
    let window: WindowModel
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        HStack(alignment: .top, spacing: 7) {
            /*
             * The command: one line to start with, growing as lines are added —
             * a short script is as common a fan-out as a single command. Enter
             * runs it; Shift+Enter adds a line. The lines go to each host's shell
             * together, as one script.
             */
            TextField("Command to run on all selected hosts\u{2026}   Shift+Enter for another line",
                      text: $fw.lastCommand, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...14)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                .autocorrectionDisabled()
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { fw.lastCommand += "\n"; return .handled }
                    run()
                    return .handled
                }
            MXRunAsField(fw: fw)
            Button("Run") { run() }.buttonStyle(.primary)
            Button("Schedule\u{2026}") {
                let cmd = fw.lastCommand, who = fw.lastRunAs.trimmed
                Task { @MainActor in await fw.openScheduleDialog(nil, command: cmd, runAs: who) }
            }
            .buttonStyle(.ghost).help("Run this at a date and time, once or repeating")
            Button("Save YAML\u{2026}") { Task { @MainActor in await fw.saveRunYaml(fw.lastCommand) } }
                .buttonStyle(.ghost).help("Save this command and host selection as a reusable run")
            Button("Load YAML\u{2026}") { Task { @MainActor in await fw.loadRunYaml() } }
                .buttonStyle(.ghost).help("Open a saved run")
            Button("Ansible\u{2026}") { Task { @MainActor in await fw.exportAnsible(fw.lastCommand) } }
                .buttonStyle(.ghost).help("Turn this command and host selection into a playbook")
        }
        .padding(.bottom, 9)
    }

    private func run() {
        let cmd = fw.lastCommand
        let who = fw.lastRunAs.trimmed
        Task { @MainActor in await fw.runMulti(cmd, runAs: who.nilIfEmpty) }
    }
}

/**
 * Which account to run as. Teleport's ssh_config User is a cluster principal,
 * not necessarily a valid account on each node, so naming one here is often
 * the difference between working and "access denied".
 */
private struct MXRunAsField: View {
    @Bindable var fw: FleetWindow
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 2) {
            TextField("run as\u{2026}", text: $fw.lastRunAs)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
            let logins = fw.knownLogins()
            if !logins.isEmpty {
                Menu {
                    ForEach(logins, id: \.self) { l in Button(l) { fw.lastRunAs = l } }
                } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: 140)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
        .help("Login to use on every selected host")
    }
}

/**
 * Macros as multi-exec targets: the same commands the Saved tab runs on one
 * host, run across the whole selection. A macro that follows a log never ends,
 * one meant to be edited first cannot be edited on fifty hosts at once, and
 * one set to run only in the local shell has no server here — none are listed.
 */
private struct MXMacroPicker: View {
    let window: WindowModel
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let all = Macros.shared.all.filter { !$0.interactive && !$0.noEnter && Macros.runsOn($0, "remote") }
        let q = fw.mxMacroFilter.trimmed.lowercased()
        let shown = q.isEmpty ? all : all.filter { "\($0.name) \($0.description) \($0.command) \($0.category)".lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                FleetField(placeholder: "Filter macros\u{2026}", text: $fw.mxMacroFilter)
                MXRunAsField(fw: fw)
            }
            if shown.isEmpty {
                Text(q.isEmpty ? "No macros defined." : "No macro matches.").font(.system(size: 11)).foregroundStyle(p.muted)
                    .padding(.vertical, 6).padding(.horizontal, 2)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 5)], alignment: .leading, spacing: 5) {
                    ForEach(shown, id: \.id) { m in MXMacroButton(macro: m, fw: fw) }
                }
            }
            Text("Runs on every selected host. Macros that follow a log, or that are meant to be edited first, are not listed.")
                .font(.system(size: 11)).foregroundStyle(p.muted).padding(.vertical, 6).padding(.horizontal, 2)
        }
        .padding(.bottom, 4)
    }
}

private struct MXMacroButton: View {
    let macro: Macro
    let fw: FleetWindow
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        let m = macro
        Button {
            let who = fw.lastRunAs.trimmed.nilIfEmpty
            Task { @MainActor in await fw.runMacroMulti(m, login: who) }
        } label: {
            HStack(spacing: 6) {
                Text(m.category.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(p.muted)
                Text(m.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if m.confirm { FleetTag(text: "careful", color: p.amber) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(hover.on ? p.text : p.textDim)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover.on ? p.panel3 : p.panel2))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(hover.on ? p.accentDim : p.borderSoft))
            .overlay(alignment: .leading) { if m.confirm { p.amber.frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help((m.description.isEmpty ? "" : m.description + "\n\n") + m.command)
    }
}

/**
 * The runs made before, with the hosts each was made on. "The same thing
 * again" is the most common multi-exec, and the tedious part is never the
 * command, it is re-ticking eleven hosts.
 */
private struct MXHistory: View {
    let window: WindowModel
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let _ = fw.historyRevision
        let list = FleetStore.execRuns()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("A run is remembered by its command and the hosts it ran on, not its output.")
                    .font(.system(size: 11.5)).foregroundStyle(p.muted)
                Spacer()
                Button("Clear") { FleetStore.clearExecRuns() }.buttonStyle(.ghostSmall)
            }
            .padding(.bottom, 7)
            if list.isEmpty {
                FleetEmpty(text: "No runs yet.", detail: "Every multi-exec is remembered here with the hosts it ran on, so it can be run again.")
            }
            ForEach(list.indices, id: \.self) { i in
                let run = list[i]
                let hosts = run["hosts"].items.compactMap(\.stringish)
                let ok = run["ok"].int ?? 0, failed = run["failed"].int ?? 0
                let query = run["selector"]["query"]
                let byTag = run["selector"].object != nil && !query.isNull
                FleetRow {
                    FleetTag(text: failed > 0 ? "\(ok)/\(ok + failed)" : "\(ok)", color: failed > 0 ? p.red : p.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run["command"].stringish ?? "").font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                        Text([run["label"].stringish ?? "",
                              byTag && !(query.stringish ?? "").isEmpty ? "by tag: \(query.stringish ?? "")" : "\(hosts.count) host\(hosts.count == 1 ? "" : "s")",
                              run["runAs"].truthy ? "as " + (run["runAs"].stringish ?? "") : "",
                              Fmt.date(ms: run["at"].double)].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  "))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                        // The hosts it ran on, by name, as chips — every one of them in the tooltip.
                        if !hosts.isEmpty && !(byTag && !(query.stringish ?? "").isEmpty) {
                            FlowChips(hosts: hosts)
                                .help(hosts.joined(separator: "\n"))
                                .padding(.top, 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Run again") { Task { @MainActor in await fw.rerun(run) } }
                        .buttonStyle(GhostButtonStyle(small: true, prominent: true))
                        .help("Re-select those hosts and run the same command")
                    Button("Edit") { fw.editRun(run) }.buttonStyle(.ghostSmall)
                        .help("Put the command and its hosts back, without running it")
                    Button("\u{00D7}") { if let id = run["id"].string { FleetStore.deleteExecRun(id) } }
                        .buttonStyle(.icon).help("Forget this run")
                }
            }
        }
        .padding(.bottom, 8)
    }
}

/// Up to twelve host chips, then "+N more".
private struct FlowChips: View {
    let hosts: [String]
    var body: some View {
        let p = Theme.shared.p
        let shown = Array(hosts.prefix(12))
        FleetFlowLayout(spacing: 3) {
            ForEach(shown.indices, id: \.self) { FleetTag(text: shown[$0]).font(.system(size: 10.5)) }
            if hosts.count > 12 { Text("+\(hosts.count - 12) more").font(.system(size: 10.5)).foregroundStyle(p.muted) }
        }
    }
}

/// A simple wrapping layout for chips.
struct FleetFlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            widest = max(widest, x)
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: min(maxW, widest), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/**
 * How the targets are chosen: the ticks in the sidebar, or a cluster and a
 * tag query resolved at run time. The second is what "every prod web node"
 * means, and it does not go stale when a node is added.
 */
private struct MXSelectorRow: View {
    let window: WindowModel
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let sel = fw.tagSelector
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { fw.tagSelector.on }, set: { fw.mxExcluded = []; fw.tagSelector.on = $0 })) {
                Text("Choose by tag instead of ticking hosts").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                FleetPicker(options: [("", "Every logged-in cluster")]
                                + Inventory.shared.profiles.filter { !$0.expired }.map { ($0.proxy, $0.cluster.nilIfEmpty ?? $0.proxy) },
                            selection: Binding(get: { fw.tagSelector.proxy }, set: { fw.mxExcluded = []; fw.tagSelector.proxy = $0 }))
                    .frame(maxWidth: 220)
                TextField("env=prod role:web  \u{2014}  the same syntax as the host filter",
                          text: Binding(get: { fw.tagSelector.query }, set: { fw.mxExcluded = []; fw.tagSelector.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                    .autocorrectionDisabled()
                Button("Tags\u{2026}") { tags() }.buttonStyle(.ghostSmall).help("Browse the labels in the inventory")
            }
            .opacity(sel.on ? 1 : 0.45)
            .disabled(!sel.on)
        }
        .padding(.top, 2).padding(.bottom, 8)
    }

    private func tags() {
        let current = fw.tagSelector.query
        guard Actions.shared.isRegistered("tag-browser") else {
            StatusBus.shared.show("\u{201C}tag-browser\u{201D} is not available in this build", kind: .warn)
            return
        }
        let get: () -> String = { [weak fw] in fw?.tagSelector.query ?? current }
        let set: (String?) -> Void = { [weak fw] term in
            guard let fw else { return }
            fw.tagSelector.query = term == nil ? "" : "\(fw.tagSelector.query) \(term!)".trimmed
        }
        Actions.shared.perform("tag-browser", window: window, args: ["getFilter": get, "setFilter": set])
    }
}

/**
 * The hosts that never answered, with the way back. Above the results rather
 * than below, because a run that reached eighteen of twenty is read as a
 * success otherwise.
 */
private struct MXFailedBox: View {
    let fw: FleetWindow
    let failed: MXFailed
    var body: some View {
        let p = Theme.shared.p
        let n = failed.hosts.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(p.amber).monospacedDigit()
                Text("host\(n == 1 ? "" : "s") could not be connected" + (failed.runAs.map { " as \($0)" } ?? ""))
                    .font(.system(size: 12))
                Spacer()
                Button("Retry these") { Task { @MainActor in await fw.retryFailed() } }
                    .buttonStyle(GhostButtonStyle(small: true, prominent: true))
                    .help("Dial them again and run the same command \u{2014} only on these hosts")
                Button("Dismiss") { fw.lastFailed = nil }.buttonStyle(.ghostSmall)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .overlay(alignment: .bottom) { p.amber.opacity(0.3).frame(height: 1) }
            ForEach(failed.hosts.indices, id: \.self) { i in
                let h = failed.hosts[i]
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(h.target.label + (h.login.map { " (\($0))" } ?? ""))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.textDim).fixedSize()
                    Text(h.error).font(.system(size: 11.5)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(p.amber.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.amber))
        .padding(.top, 8).padding(.bottom, 4)
    }
}

/**
 * Each target with the account it will be reached as. A fan-out that runs as
 * the wrong user fails on every host at once; the name shown is the same one
 * the runner will use. One row a host: its name, who it runs as, its cluster
 * and its tags — the things that tell two web-03s apart — and a way to leave
 * it out of this run.
 */
private struct MXTargetsView: View {
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let targets = fw.resolveTargets()
        let who = fw.lastRunAs.trimmed.nilIfEmpty
        let removed = fw.mxExcluded.count
        let n = targets.count
        let head: String = fw.tagSelector.on
            ? (n > 0 ? "Matches now: \(n) host\(n == 1 ? "" : "s")"
                : "Nothing matches that query yet. It is resolved again every time you run, so this can be written before the hosts exist.")
            : (n > 0
                // With nothing ticked the run goes to the open sessions, which is
                // easy to forget once the ticks are gone — so it says so.
                ? "\(n) target\(n == 1 ? "" : "s")\(fw.nothingTicked ? " \u{2014} the open sessions, as nothing is ticked" : "")"
                : "No hosts selected. Tick hosts in the sidebar, or open sessions \u{2014} open sessions are used when nothing is ticked.")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(head).font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                if removed > 0 {
                    Button("\(removed) left out \u{2014} put back") { fw.mxExcluded = [] }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(p.accent)
                }
            }
            if !targets.isEmpty {
                let rows = VStack(alignment: .leading, spacing: 1) {
                    ForEach(targets.indices, id: \.self) { i in MXTargetRow(fw: fw, target: targets[i], who: who) }
                }
                if targets.count > 8 {
                    ScrollView { rows }.frame(height: 190)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.borderSoft))
                } else {
                    rows
                }
            }
            let plan = fw.staging().planText(n)
            if !plan.isEmpty {
                Text(plan).font(.system(size: 11)).foregroundStyle(p.accent)
            }
        }
        .padding(.bottom, 9)
    }
}

private struct MXTargetRow: View {
    let fw: FleetWindow
    let target: MXTarget
    let who: String?

    var body: some View {
        let p = Theme.shared.p
        let t = target
        let host = t.host ?? t.hostId.flatMap(FleetHooks.hostById)
        let as_ = fw.loginForTarget(t, who)
        let entries = host.map { Tags.labelEntries($0) } ?? []
        let tags = Array(entries.prefix(6))
        let extra = entries.count - tags.count
        HStack(spacing: 6) {
            Button("\u{00D7}") { fw.leaveOut(t) }
                .buttonStyle(.plain).foregroundStyle(p.muted)
                .help("Leave \(t.label) out of this run")
            Text(t.label).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.text).lineLimit(1)
            if let a = as_, !t.label.hasSuffix("(\(a))") {
                Text(a).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.accent)
            }
            if let cl = host?.cluster?.nilIfEmpty {
                Text(cl).font(.system(size: 10.5)).foregroundStyle(p.muted)
            }
            ForEach(tags.indices, id: \.self) { i in
                let e = tags[i]
                FleetTag(text: e.value.isEmpty ? e.key : "\(e.key)=\(e.value)").font(.system(size: 10))
            }
            if extra > 0 {
                FleetTag(text: "+\(extra)").font(.system(size: 10))
                    .help(entries.dropFirst(6).map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
    }
}

/**
 * The Advanced part of the form: how a run is staged, and whether a host that
 * fails is tried again. Kept in settings; a loaded file's own stages and
 * retries are used here until changed by hand.
 */
private struct MXAdvanced: View {
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let st = fw.staging()
        let rt = fw.retrySetting()
        let summary = "staged rollout, retries"
            + (rt.count > 0 ? " \u{2014} \(rt.count) retr\(rt.count == 1 ? "y" : "ies") on" : "")
            + (fw.stagingOverride != nil || fw.retryOverride != nil ? " (from the loaded file)" : "")
        DisclosureGroup(isExpanded: $fw.advOpen) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("Retry a host that fails")
                    MXNumField(value: rt.count, help: "More tries after a failure (0 for none)") { v in
                        var r = fw.retrySetting(); r.count = max(0, min(10, v)); fw.saveRetry(r)
                    }
                    Text("more time(s),")
                    MXNumField(value: Int(rt.delay), help: "Seconds between tries") { v in
                        var r = fw.retrySetting(); r.delay = Double(max(0, min(3600, v))); fw.saveRetry(r)
                    }
                    Text("seconds apart")
                }
                Text("A host that could not connect is dialled again too. Only how its last try ended counts \u{2014} for a stage, and in the totals.")
                    .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("Run in stages")
                    FleetPicker(options: [("auto", "Automatically above \(MXStaging.stageAbove) hosts"), ("on", "Always"),
                                          ("off", "Never \u{2014} every host at once")],
                                selection: Binding(get: { st.mode }, set: { v in var s = fw.staging(); s.mode = v; fw.saveStaging(s) }))
                        .frame(maxWidth: 260)
                }
                HStack(spacing: 6) {
                    Text("First stage")
                    MXNumField(value: st.first, help: "Hosts in the first stage") { v in
                        var s = fw.staging(); s.first = max(1, v); fw.saveStaging(s)
                    }
                    Text("host(s), then")
                    MXNumField(value: st.batch, help: "Hosts in each stage after the first") { v in
                        var s = fw.staging(); s.batch = max(1, v); fw.saveStaging(s)
                    }
                    Text("at a time")
                }
                Toggle("Pause after each stage, to look before going on",
                       isOn: Binding(get: { st.pause }, set: { v in var s = fw.staging(); s.pause = v; fw.saveStaging(s) }))
                    .toggleStyle(.checkbox)
                Toggle("Stop at a stage that has a failure",
                       isOn: Binding(get: { st.stopOnFail }, set: { v in var s = fw.staging(); s.stopOnFail = v; fw.saveStaging(s) }))
                    .toggleStyle(.checkbox)
            }
            .font(.system(size: 12))
            .foregroundStyle(p.textDim)
            .padding(.top, 6).padding(.leading, 4)
        } label: {
            Text("Advanced \u{2014} " + summary).font(.system(size: 11.5)).foregroundStyle(p.muted)
        }
        .padding(.bottom, 9)
    }
}

/// A small number box, saved when Return is pressed or focus leaves it.
private struct MXNumField: View {
    let value: Int
    let help: String
    let commit: (Int) -> Void
    @StateObject private var text = Local("")
    @FocusState private var focused: Bool

    var body: some View {
        let p = Theme.shared.p
        TextField("", text: $text.value)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
            .focused($focused)
            .help(help)
            .onAppear { text.value = String(value) }
            .onChange(of: value) { _, v in if !focused { text.value = String(v) } }
            .onSubmit { save() }
            .onChange(of: focused) { _, f in if !f { save() } }
    }

    private func save() {
        guard let v = Int(text.value.trimmed) else { text.value = String(value); return }
        if v != value { commit(v) }
    }
}

/// One run: the command, the counts, Cancel or Save results…, and a card per host.
private struct MXRunView: View {
    let window: WindowModel
    let fw: FleetWindow
    let run: MultiExecView

    var body: some View {
        let p = Theme.shared.p
        let ok = run.results.filter { $0.status == "done" }.count
        let failed = run.results.filter { ["error", "timeout"].contains($0.status) }.count
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text(run.command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer()
                if let sg = run.staged {
                    FleetTag(text: run.running ? "stage \(sg.index + 1) of \(sg.sizes.count)" : "\(sg.sizes.count) stages",
                             color: p.accent)
                }
                Text("\(ok) ok \u{00B7} \(failed) failed \u{00B7} \(run.results.count) total")
                    .font(.system(size: 11.5)).foregroundStyle(p.muted)
                if run.running {
                    Button("Cancel") { MultiExecService.shared.cancel(run.id) }.buttonStyle(.ghostSmall)
                } else {
                    Button("Save results\u{2026}") { Task { @MainActor in await fw.saveResults(run) } }
                        .buttonStyle(.ghostSmall).help("Write these results to a YAML file")
                }
            }
            /*
             * A staged run waiting between stages: what the stage did, and the
             * three ways on. Above the results, since it is the thing to answer.
             */
            if run.running, let sg = run.staged, let pz = sg.paused { MXPausedBox(run: run, staged: sg, paused: pz) }
            ForEach(run.results) { r in MXResultCard(fw: fw, runId: run.id, result: r) }
        }
        .padding(.bottom, 14)
    }
}

private struct MXPausedBox: View {
    let run: MultiExecView
    let staged: MultiExecStaged
    let paused: MultiExecStaged.Paused

    var body: some View {
        let p = Theme.shared.p
        let nextN = staged.index + 1 < staged.sizes.count ? staged.sizes[staged.index + 1] : 0
        let left = staged.sizes.dropFirst(staged.index + 1).reduce(0, +)
        let bad = paused.reason == "failed"
        let text = (bad
            ? "Stage \(staged.index + 1) had \(paused.failed) failure\(paused.failed == 1 ? "" : "s") \u{2014} stopped before going wider."
            : "Stage \(staged.index + 1) of \(staged.sizes.count) done: \(paused.ok) ok.")
            + " \(left) host\(left == 1 ? "" : "s") still to go."
        let c = bad ? p.red : p.accent
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12)).foregroundStyle(p.text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Next stage (\(nextN))") { MultiExecService.shared.decide(run.id, "next") }
                .buttonStyle(GhostButtonStyle(small: true, prominent: true))
            Button("All the rest (\(left))") { MultiExecService.shared.decide(run.id, "all") }
                .buttonStyle(.ghostSmall).help("No more pauses")
            Button("Stop here") { MultiExecService.shared.decide(run.id, "stop") }.buttonStyle(.ghostSmall)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(c))
    }
}

private struct MXResultCard: View {
    let fw: FleetWindow
    let runId: String
    let result: MultiExecResult
    @StateObject private var answer = Local("")

    var body: some View {
        let p = Theme.shared.p
        let r = result
        let key = runId + "/" + r.connId
        // A clean success starts folded; anything with stderr or a failure open.
        let expanded = fw.expanded[key] ?? !(r.status == "done" && r.stderr.isEmpty)
        // Who it ran as, first — a wall of "permission denied" is read very
        // differently once you can see which account produced it.
        let state: String = r.status == "retrying"
            ? "failed \u{2014} try \(r.attempt + 1) of \(r.attempts)" + (r.retryAt.map { " at " + Self.time($0) } ?? "")
            : r.status
        let meta = [ConnectionManager.shared.connection(r.connId)?.login ?? "",
                    r.stage.map { "stage \($0)" } ?? "",
                    state,
                    r.attempt > 1 ? "on try \(r.attempt) of \(r.attempts)" : "",
                    r.exitCode.map { "exit \($0)" } ?? "", r.durationMs.map { Fmt.duration(ms: $0) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MXStatusDot(status: r.status)
                Text(r.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.text)
                Spacer()
                Text(meta).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(p.panel2)
            .contentShape(Rectangle())
            .onTapGesture { fw.expanded[key] = !expanded }
            /*
             * Waiting on this one host — per-session MFA, which has no pty on a
             * plain spawn to prompt on. Answering it does not block the others.
             */
            if r.status == "prompting" {
                HStack(spacing: 8) {
                    Text(r.promptText ?? "Waiting for a response\u{2026}").font(.system(size: 11)).foregroundStyle(p.muted)
                    SecureField("MFA code, or press Enter after tapping your key", text: $answer.value)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                        .onSubmit {
                            MultiExecService.shared.answer(runId, r.connId, answer.value + "\n")
                            answer.value = ""
                        }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(p.panel2)
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // What the earlier tries said, before this one's output.
                        ForEach(r.tries.indices, id: \.self) { i in
                            let t = r.tries[i]
                            Text("try \(i + 1): \(t.status)\(t.exitCode.map { " \u{00B7} exit \($0)" } ?? "")\(t.error.isEmpty ? "" : " \u{2014} " + t.error)")
                                .foregroundStyle(p.muted)
                        }
                        if !r.stdout.isEmpty { Text(r.stdout).foregroundStyle(p.textDim) }
                        if !r.stderr.isEmpty { Text(r.stderr).foregroundStyle(p.red) }
                        if r.stdout.isEmpty && r.stderr.isEmpty { Text("(no output)").opacity(0.5) }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .background(p.panel2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.borderSoft))
    }

    static func time(_ ms: Double) -> String {
        let f = DateFormatter()
        f.timeStyle = .medium; f.dateStyle = .none
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

private struct MXStatusDot: View {
    let status: String
    @StateObject private var pulse = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        let c: Color = status == "done" ? p.green : ["running", "prompting", "retrying"].contains(status) ? p.amber
            : (status == "error" || status == "timeout") ? p.red : p.muted
        Circle().fill(c).frame(width: 7, height: 7)
            .opacity(status == "running" && pulse.on ? 0.35 : 1)
            .animation(status == "running" ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse.on)
            .onAppear { if status == "running" { pulse.on = true } }
    }
}
