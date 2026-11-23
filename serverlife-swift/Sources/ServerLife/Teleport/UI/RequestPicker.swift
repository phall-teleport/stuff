import SwiftUI

/// A resource as the request dialogs carry it (requestpicker.js / teleportpanel.js
/// `{ id, kind, name, cluster, uuid, labels }`). `id` is what `--resource=` takes.
struct ReqResource: Hashable, Identifiable {
    var id: String
    var kind: String
    var name: String
    var cluster: String
    var uuid: String = ""
    var labels: [String: String] = [:]

    init(id: String, kind: String, name: String, cluster: String, uuid: String = "", labels: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.name = name; self.cluster = cluster; self.uuid = uuid; self.labels = labels
    }

    init(_ r: RequestableResource) {
        self.init(id: r.id, kind: r.kind, name: r.name, cluster: r.cluster, uuid: r.uuid, labels: r.labels)
    }

    init?(json j: JSON) {
        guard let id = j["id"].stringish, !id.isEmpty else { return nil }
        self.init(id: id, kind: j["kind"].stringish ?? "node", name: j["name"].stringish ?? "",
                  cluster: j["cluster"].stringish ?? "", uuid: j["uuid"].stringish ?? "",
                  labels: j["labels"].entries.compactMapValues(\.stringish))
    }

    var json: JSON {
        ["id": .string(id), "kind": .string(kind), "name": .string(name), "cluster": .string(cluster),
         "uuid": .string(uuid), "labels": .object(labels.mapValues { .string($0) })]
    }
}

/// tags.js `labelEntries`: sorted, Teleport's own bookkeeping labels dropped.
func tuiLabelEntries(_ labels: [String: String]) -> [(String, String)] {
    let internalPrefixes = ["teleport.internal/", "teleport.hidden/", "teleport.dev/"]
    return labels.filter { k, _ in !internalPrefixes.contains { k.hasPrefix($0) } }
        .map { ($0.key, $0.value) }
        .sorted { $0.0.localizedCompare($1.0) == .orderedAscending }
}

/// A `.chip` with `k` and `v`.
struct TUILabelChip: View {
    let k: String
    let v: String
    var on = false
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 0) {
            Text(k).foregroundStyle(p.muted)
            Text("=").foregroundStyle(p.muted.opacity(0.6))
            Text(v).foregroundStyle(on ? p.accent : p.textDim)
        }
        .font(.system(size: 10, design: .monospaced)).lineLimit(1)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(on ? p.accent.opacity(0.15) : p.panel3))
        .help("\(k) = \(v)")
    }
}

/// requestpicker.js: browse what this user can actually request.
@MainActor
enum RequestPicker {
    static let kindLabels: [String: String] = [
        "node": "Servers", "app": "Applications", "db": "Databases", "kube_cluster": "Kubernetes clusters",
        "kube_resource": "Kubernetes namespaces/pods", "windows_desktop": "Windows desktops", "linux_desktop": "Linux desktops", "user_group": "User groups",
        "saml_idp_service_provider": "SAML applications", "git_server": "Git servers",
        "aws_ic_account": "AWS accounts", "aws_ic_account_assignment": "AWS account assignments",
    ]

    static func kindLabel(_ k: String) -> String { kindLabels[k] ?? k.replacingOccurrences(of: "_", with: " ") }

    struct Options {
        var title: String?
        var subtitle: String?
        var confirmLabel: String?
        /// A caller that already knows which kind and cluster it means — the
        /// kube browser's "Request namespace/pod access…", a requestable kube
        /// cluster's "Request a namespace or pod…" — skips both dropdowns.
        var initialKind: String?
        var initialKubeCluster: String?
    }

    /// `pickRequestResources`: nil when cancelled.
    static func pickResources(_ profile: TeleportProfile, preselected: [ReqResource] = [], opts: Options = Options(),
                              window: WindowModel? = nil) async -> [ReqResource]? {
        let m = ResourcePickerModel(profile: profile, preselected: preselected,
                                    initialKind: opts.initialKind, initialKubeCluster: opts.initialKubeCluster)
        m.onKindChanged()
        return await TUIModal.ask(window, title: opts.title ?? "Request access to…", width: 820, height: 600,
                                  autosave: "requestpicker") { finish, _ in
            ResourcePickerView(m: m, opts: opts, finish: finish)
        }
    }

    /// `pickRequestRoles`: a checklist of requestable roles; nil when cancelled.
    static func pickRoles(_ profile: TeleportProfile, preselected: [String], window: WindowModel? = nil) async -> [String]? {
        let m = RolePickerModel(profile: profile, preselected: preselected)
        m.load()
        return await TUIModal.ask(window, title: "Requestable roles", width: 560, height: 480) { finish, _ in
            RolePickerView(m: m, finish: finish)
        }
    }
}

@MainActor
final class ResourcePickerModel: ObservableObject {
    let profile: TeleportProfile
    let kinds: [String]
    @Published var kind = "node" { didSet { if kind != oldValue { onKindChanged() } } }
    @Published var search = ""
    @Published var loading = false
    @Published var result: TshList<RequestableResource>?
    /// Insertion-ordered selection (a JS Map).
    @Published var chosen: [ReqResource]
    /// Search result id → the inventory id the resource will carry once
    /// granted, for the MFA mark (nodes and kube clusters only).
    @Published var hostIds: [String: String] = [:]
    /// Bumped when an MFA mark changes, so the rows redraw.
    @Published var mfaTick = 0

    // kind kube_resource scoping — meaningless without a kube cluster to
    // search inside, unlike every other kind here.
    let initialKubeCluster: String?
    @Published var kubeCluster = "" { didSet { if kubeCluster != oldValue && kind == "kube_resource" { load() } } }
    @Published var kubeClusterOptions: [String] = []
    @Published var kubeClustersLoading = false
    private var kubeClustersLoaded = false
    /// --kube-kind: "namespaces" | "pods".
    @Published var subKind = "namespaces" { didSet { if subKind != oldValue { load() } } }
    @Published var namespace = "default"
    @Published var allNamespaces = false { didSet { if allNamespaces != oldValue { load() } } }
    private var gen = 0

    init(profile: TeleportProfile, preselected: [ReqResource], initialKind: String? = nil, initialKubeCluster: String? = nil,
         kubeEnabled: Bool? = nil) {
        let kubeEnabled = kubeEnabled ?? Store.shared.setting("kubeEnabled", true)
        self.profile = profile
        var seen = Set<String>()
        chosen = preselected.filter { seen.insert($0.id).inserted }
        // A pure-SSH setup with KubeLife off never sees the Kubernetes kinds.
        var ks = Teleport.requestKinds
        if !kubeEnabled { ks = ks.filter { $0 != "kube_cluster" && $0 != "kube_resource" } }
        kinds = ks
        self.initialKubeCluster = initialKubeCluster
        var k = "node"
        if let i = initialKind, ks.contains(i) { k = i }
        if (k == "kube_cluster" || k == "kube_resource") && !ks.contains(k) { k = ks.first ?? "node" }
        kind = k
    }

    func onKindChanged() {
        if kind != "kube_resource" { load(); return }
        Task { @MainActor in
            await ensureKubeClusters()
            load()
        }
    }

    func ensureKubeClusters() async {
        if kubeClustersLoaded { return }
        kubeClustersLoaded = true
        kubeClustersLoading = true
        let r = await Teleport.searchRequestable(proxy: profile.proxy, kind: "kube_cluster", home: profile.homeDir)
        var names = r.ok ? r.items.map(\.name) : []
        // A caller's own cluster is routinely not among the "could additionally
        // request" results (standing access already covers it); it still needs
        // to be searchable for namespaces/pods, so it is added.
        if let c = initialKubeCluster?.nilIfEmpty, !names.contains(c) { names.insert(c, at: 0) }
        kubeClustersLoading = false
        kubeClusterOptions = names
        let pick = initialKubeCluster.flatMap { names.contains($0) ? $0 : nil } ?? names.first ?? ""
        // Set without the didSet's load: the caller loads next.
        suppressKubeLoad = true
        kubeCluster = pick
        suppressKubeLoad = false
    }

    private var suppressKubeLoad = false

    func setNamespace(_ v: String) {
        let n = v.trimmed.nilIfEmpty ?? "default"
        if n != namespace { namespace = n; load() }
    }

    func load() {
        if suppressKubeLoad { return }
        gen += 1
        let g = gen
        if kind == "kube_resource" && kubeCluster.isEmpty {
            if kubeClustersLoading { loading = true; return }
            result = .failed("No Kubernetes cluster to search within.")
            loading = false
            return
        }
        loading = true
        let p = profile, k = kind, kc = kubeCluster, sk = subKind, ns = namespace, allNs = allNamespaces
        Task { @MainActor in
            let r: TshList<RequestableResource>
            if k == "kube_resource" {
                r = await Teleport.searchRequestable(proxy: p.proxy, kind: k, kubeCluster: kc, kubeKind: sk,
                                                     namespace: sk == "pods" && !allNs ? ns : nil,
                                                     allNamespaces: sk == "pods" && allNs, home: p.homeDir)
            } else {
                r = await Teleport.searchRequestable(proxy: p.proxy, kind: k, home: p.homeDir)
            }
            guard g == self.gen else { return }
            // Servers and kube clusters only: the MFA list is a thing
            // per-session SSH and per-session kube both ask for.
            var ids: [String: String] = [:]
            if r.ok && k == "node" {
                ids = Teleport.inventoryNodeIds(r.items.map { ($0.id, $0.cluster, $0.uuid) }, home: p.homeDir)
            } else if r.ok && k == "kube_cluster" {
                ids = Teleport.inventoryKubeIds(r.items.map { ($0.id, $0.cluster, $0.name) }, home: p.homeDir)
            }
            self.hostIds = ids
            self.result = r
            self.loading = false
        }
    }

    /// `mfaToggle`: a server not yet granted can still be told it needs MFA —
    /// the flag waits in the same `mfaHosts` list, keyed by the id the node
    /// will carry once the grant lands.
    func isMfa(_ r: RequestableResource) -> Bool? {
        guard let id = hostIds[r.id], !id.isEmpty else { return nil }
        return HostPrefs.isMfaHost(id)
    }

    func toggleMfa(_ r: RequestableResource) {
        guard let id = hostIds[r.id], !id.isEmpty else { return }
        let h = Host(type: Host.teleport, id: id, name: r.name.nilIfEmpty ?? r.uuid)
        HostPrefs.setMfaHost(h, !HostPrefs.isMfaHost(id))
        mfaTick += 1
    }

    var visible: [RequestableResource] {
        let all = result?.items ?? []
        let q = search.trimmed.lowercased()
        if q.isEmpty { return all }
        return all.filter { r in
            ([r.name, r.uuid, r.cluster] + r.labels.map { "\($0.key)=\($0.value)" }).joined(separator: " ").lowercased().contains(q)
        }
    }

    func isOn(_ id: String) -> Bool { chosen.contains { $0.id == id } }

    func toggle(_ r: RequestableResource) {
        if let i = chosen.firstIndex(where: { $0.id == r.id }) { chosen.remove(at: i) } else { chosen.append(ReqResource(r)) }
    }
}

private struct ResourcePickerView: View {
    @ObservedObject var m: ResourcePickerModel
    let opts: RequestPicker.Options
    let finish: ([ReqResource]?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: opts.title ?? "Request access to…", subtitle: opts.subtitle ?? TUI.name(m.profile), scroll: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Kind").font(.system(size: 11.5)).foregroundStyle(p.muted)
                    Picker("", selection: $m.kind) {
                        ForEach(m.kinds, id: \.self) { Text(RequestPicker.kindLabel($0)).tag($0) }
                    }.labelsHidden().frame(width: 240)
                    Spacer()
                    if !m.chosen.isEmpty { Badge(text: "\(m.chosen.count) selected") }
                }
                if m.kind == "kube_resource" { kubeRow }
                SearchField(placeholder: "Filter by name or label…", text: $m.search).focused($focused)
                ScrollView { list.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Clear selection") { m.chosen = [] }.buttonStyle(.ghost)
            Button(opts.confirmLabel ?? "Use selected") {
                if m.chosen.isEmpty { TUIStatus.toast("Select at least one resource", "error"); return }
                finish(m.chosen)
            }.buttonStyle(.primary)
        }
        .onAppear { after(0.05) { focused = true } }
    }

    @StateObject private var nsText = Local("default")

    private var kubeRow: some View {
        let p = Theme.shared.p
        return HStack(spacing: 8) {
            Text("Cluster").font(.system(size: 11.5)).foregroundStyle(p.muted)
            Picker("", selection: $m.kubeCluster) {
                if m.kubeClustersLoading { Text("Loading…").tag("") }
                else if m.kubeClusterOptions.isEmpty { Text("No Kubernetes clusters found").tag("") }
                ForEach(m.kubeClusterOptions, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 200)
            Text("Kind").font(.system(size: 11.5)).foregroundStyle(p.muted)
            Picker("", selection: $m.subKind) {
                Text("Namespaces").tag("namespaces")
                Text("Pods").tag("pods")
            }.labelsHidden().frame(width: 120)
            if m.subKind == "pods" {
                Text("Namespace").font(.system(size: 11.5)).foregroundStyle(p.muted)
                TextField("default", text: $nsText.value)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                    .disabled(m.allNamespaces).opacity(m.allNamespaces ? 0.5 : 1)
                    .onSubmit { m.setNamespace(nsText.value) }
                Toggle("every namespace", isOn: $m.allNamespaces).toggleStyle(.checkbox)
                    .font(.system(size: 11.5)).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var list: some View {
        let p = Theme.shared.p
        let kl = RequestPicker.kindLabel(m.kind).lowercased()
        if m.loading {
            TUIEmpty(lines: ["Searching \(kl)…"])
        } else if let r = m.result, !r.ok {
            TUIEmpty(lines: [r.error ?? "Search failed", "Your roles may not allow requesting this kind of resource."], error: true)
        } else {
            let rows = m.visible
            if rows.isEmpty {
                TUIEmpty(lines: [m.search.trimmed.isEmpty ? "Nothing of this kind is requestable on \(TUI.name(m.profile))."
                                 : "No \(kl) matches \u{201C}\(m.search.trimmed)\u{201D}."])
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.id) { r in
                        let on = m.isOn(r.id)
                        let tags = tuiLabelEntries(r.labels)
                        Button { m.toggle(r) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(on ? p.accent : p.muted).font(.system(size: 13))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name.nilIfEmpty ?? r.uuid).font(.system(size: 12.5))
                                    // The id is what goes into the request: small and last.
                                    Text(r.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                                        .lineLimit(1).truncationMode(.middle).help(r.id)
                                    if !tags.isEmpty {
                                        TUIFlow(spacing: 4, lineSpacing: 3) {
                                            ForEach(Array(tags.prefix(6)), id: \.0) { TUILabelChip(k: $0.0, v: $0.1) }
                                            if tags.count > 6 { TUITag(text: "+\(tags.count - 6)") }
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                                if let mfa = m.isMfa(r) {
                                    let _ = m.mfaTick
                                    Button { m.toggleMfa(r) } label: {
                                        Text("mfa").font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(mfa ? p.amber : p.muted)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(RoundedRectangle(cornerRadius: 3).fill(mfa ? p.amber.opacity(0.15) : p.panel3))
                                    }
                                    .buttonStyle(.plain)
                                    .help(mfa ? "Marked to need MFA once granted — click to forget"
                                          : "Mark as needing MFA once granted, so it connects straight away")
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(on ? p.accent.opacity(0.1) : p.panel2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

@MainActor
final class RolePickerModel: ObservableObject {
    let profile: TeleportProfile
    @Published var chosen: [String]
    @Published var loading = true
    @Published var roles: [String] = []
    @Published var error: String?

    init(profile: TeleportProfile, preselected: [String]) {
        self.profile = profile
        chosen = preselected
    }

    func load() {
        let p = profile
        Task { @MainActor in
            let r = await Teleport.searchRequestableRoles(proxy: p.proxy, home: p.homeDir)
            self.loading = false
            self.roles = r.items.map(\.name)
            self.error = r.ok ? nil : r.error
        }
    }

    func toggle(_ role: String) {
        if let i = chosen.firstIndex(of: role) { chosen.remove(at: i) } else { chosen.append(role) }
    }
}

private struct RolePickerView: View {
    @ObservedObject var m: RolePickerModel
    let finish: ([String]?) -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Requestable roles", subtitle: TUI.name(m.profile)) {
            if m.loading {
                TUIEmpty(lines: ["Listing requestable roles…"])
            } else if let e = m.error {
                TUIEmpty(lines: [e], error: true)
            } else if m.roles.isEmpty {
                TUIEmpty(lines: ["No requestable roles on this cluster.",
                                 "Your roles may grant access by resource instead — use Browse… on the resources field."])
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(m.roles, id: \.self) { role in
                        let on = m.chosen.contains(role)
                        Button { m.toggle(role) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? p.accent : p.muted)
                                Text(role).font(.system(size: 12.5))
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(on ? p.accent.opacity(0.1) : p.panel2))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Use selected") { finish(m.chosen) }.buttonStyle(.primary)
        }
    }
}
