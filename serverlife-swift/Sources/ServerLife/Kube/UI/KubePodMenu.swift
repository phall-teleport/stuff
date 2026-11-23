import SwiftUI

/// kubepanel.js `openPodContextMenu`, `startPortForward`,
/// `portForwardMenuItem`, `confirmStopForward`, `showActivePortForwards`.
@MainActor
enum KubePodMenu {
    /// The pod's right-click menu. `afterDelete` re-reads the pod list.
    static func items(_ k: KubeUISpec, _ pod: KubePodRef, afterDelete: (() -> Void)? = nil) -> [CtxItem] {
        let containers = pod.containers.isEmpty ? [""] : pod.containers
        func suffix(_ n: String) -> String { n.isEmpty ? "" : " (\(n))" }
        var items: [CtxItem] = [.heading(pod.name)]
        for n in containers {
            items.append(CtxItem("Exec into \(n.isEmpty ? "pod" : n)",
                                 submenu: KubePanes.whereMenu { KubePanes.exec(k, pod, n, $0) }) { KubePanes.exec(k, pod, n, .right) })
        }
        for n in containers {
            items.append(CtxItem("Run a command\(suffix(n))…", title: "One command, run once — no shell session opened") {
                KubeRunCommand.open(k, pod, n)
            })
        }
        for n in containers {
            var sub = KubePanes.whereMenu { KubePanes.logs(k, pod, n, $0) }
            if pod.restarts > 0 { sub.append(CtxItem("Previous container’s logs") { KubePanes.logs(k, pod, n, .right, previous: true) }) }
            items.append(CtxItem("View logs\(suffix(n))", submenu: sub) { KubePanes.logs(k, pod, n, .right) })
        }
        items.append(CtxItem("Open log viewer…") {
            KubeLogViewer.open(k.spec, namespace: pod.namespace, pod: pod.name, container: containers[0].nilIfEmpty,
                               title: KubePanes.label(pod, containers[0]) + " logs")
        })
        for n in containers {
            items.append(CtxItem("Attach\(suffix(n))", submenu: KubePanes.whereMenu { KubePanes.attach(k, pod, n, $0) }) {
                KubePanes.attach(k, pod, n, .right)
            })
        }
        for n in containers {
            items.append(CtxItem("Debug container\(suffix(n))…",
                                 submenu: KubePanes.whereMenu { w in Task { await KubePanes.debug(k, pod, n, w) } }) {
                Task { await KubePanes.debug(k, pod, n, .right) }
            })
        }
        items.append(forwardItem(k.spec, resource: "pod", name: pod.name, namespace: pod.namespace))
        items.append(CtxItem("View YAML") { Task { await viewYaml(k.spec, kind: "Pod", resource: "pods", name: pod.name, namespace: pod.namespace) } })
        items.append(CtxItem("Export YAML…") { Task { await exportYaml(k.spec, kind: "Pod", resource: "pods", name: pod.name, namespace: pod.namespace) } })
        items.append(CtxItem("Delete pod…") {
            Task {
                guard await Modal.confirm(title: "Delete pod", message: "Delete \"\(pod.name)\"?", ok: "Delete", destructive: true) else { return }
                let r = await KubeResources.deleteResource(k.spec, name: pod.name, resource: "pods", namespace: pod.namespace)
                if r["ok"].bool != true { StatusBus.shared.toast(r["error"].string ?? "Delete failed", kind: .error); return }
                StatusBus.shared.toast("Deleted \(pod.name)")
                afterDelete?()
            }
        })
        return items
    }

    /// "View YAML" — editable, the diff opt-in.
    static func viewYaml(_ spec: KubeSpec, kind: String, resource: String, name: String, namespace: String?) async {
        let label = "\(kind)/\(name)"
        let r = await KubeResources.getYaml(spec, name: name, resource: resource, namespace: namespace)
        guard r["ok"].bool == true else { KubeTextModal.show(label, r["error"].string ?? "Could not read YAML"); return }
        KubeTextModal.show(label, r["yaml"].string ?? "", editable: true, spec: spec,
                           onApply: KubeTextModal.applyFlow(spec, label: label, name: name))
    }

    static func exportYaml(_ spec: KubeSpec, kind: String, resource: String, name: String, namespace: String?) async {
        let r = await KubeResources.getYaml(spec, name: name, resource: resource, namespace: namespace)
        guard r["ok"].bool == true else { StatusBus.shared.toast(r["error"].string ?? "Could not read YAML", kind: .error); return }
        if let u = await Modal.saveText(nil, r["yaml"].string ?? "", defaultName: "\(kind.lowercased())-\(name).yaml", title: "Export \(kind)/\(name)") {
            StatusBus.shared.toast("Saved \(u.path)")
        }
    }

    // MARK: Port-forwards

    /// `portForwardMenuItem`: "Port-forward…", or "running on :PORT" with
    /// copy / start another / stop once one is.
    static func forwardItem(_ spec: KubeSpec, resource: String, name: String, namespace: String?, remotePortHint: String? = nil) -> CtxItem {
        let mine = KubeForward.shared.forwards.filter {
            $0["resource"].string == resource && $0["name"].string == name && $0["namespace"].string == namespace
        }
        guard let f = mine.first else {
            return CtxItem("Port-forward…") { startForward(spec, resource: resource, name: name, namespace: namespace, remotePortHint: remotePortHint) }
        }
        let port = Int(f["port"].double ?? 0)
        return CtxItem("Port-forward — running on :\(port)", submenu: [
            CtxItem("Copy local address") { Clipboard.write("localhost:\(port)"); StatusBus.shared.toast("Copied") },
            CtxItem("Start another…") { startForward(spec, resource: resource, name: name, namespace: namespace, remotePortHint: remotePortHint) },
            CtxItem("Stop") { Task { await confirmStop(f) } },
        ])
    }

    static func confirmStop(_ f: JSON) async {
        let ns = f["namespace"].string?.nilIfEmpty.map { " (\($0))" } ?? ""
        let sure = await Modal.confirm(title: "Stop port-forward",
            message: "Stop forwarding \(f["resource"].string ?? "")/\(f["name"].string ?? "")\(ns) — localhost:\(Int(f["port"].double ?? 0))?",
            ok: "Stop", destructive: true)
        guard sure, let id = f["id"].string else { return }
        KubeForward.shared.stop(id)
        StatusBus.shared.toast("Port-forward stopped")
    }

    /// `startPortForward`: the two ports, then kube:forwardStart.
    static func startForward(_ spec: KubeSpec, resource: String, name: String, namespace: String?, remotePortHint: String? = nil) {
        Modal.sheet(title: "Port-forward", width: 460) { h in
            KubeForwardDialog(subtitle: "\(resource)/\(name)", remote: remotePortHint ?? "", close: { h.close() }) { remote, local in
                let id = "\(spec.contextName ?? ""):\(resource)/\(namespace ?? "")/\(name):\(remote)"
                do {
                    let i = try await KubeForward.shared.start(id: id, spec: spec, resource: resource, name: name, namespace: namespace,
                                                               localPort: local.nilIfEmpty, remotePort: remote)
                    let addr = "localhost:\(i.port)"
                    Clipboard.write(addr)
                    StatusBus.shared.toast("Forwarding \(addr) → \(resource)/\(name):\(remote) — address copied")
                } catch {
                    StatusBus.shared.toast(error.localizedDescription.nilIfEmpty ?? "Could not start the port-forward", kind: .error)
                }
            }
        }
    }

    /// `showActivePortForwards` — one context's, or all.
    static func showActive(contextName: String? = nil) {
        Modal.sheet(title: contextName != nil ? "Active port-forwards" : "All active port-forwards", width: 640) { h in
            KubeActiveForwards(contextName: contextName, close: { h.close() })
        }
    }
}

private struct KubeForwardDialog: View {
    let subtitle: String
    let close: () -> Void
    let start: (String, String) async -> Void
    @StateObject private var remote: Local<String>
    @StateObject private var local = Local("")
    init(subtitle: String, remote: String, close: @escaping () -> Void, start: @escaping (String, String) async -> Void) {
        self.subtitle = subtitle; self.close = close; self.start = start
        _remote = StateObject(wrappedValue: Local(remote))
    }
    var body: some View {
        DialogScaffold(title: "Port-forward", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 10) {
                FormRow(label: "Remote port (on the pod/service)") { TextField("e.g. 80", text: $remote.value) }
                FormRow(label: "Local port", hint: "Leave blank to let kubectl pick an open port.") { TextField("auto", text: $local.value) }
            }
        } footer: {
            Button("Cancel") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Start") {
                let r = remote.value.trimmed, l = local.value.trimmed
                if r.isEmpty { StatusBus.shared.toast("Give it a remote port", kind: .error); return }
                close()
                Task { await start(r, l) }
            }.buttonStyle(.primary)
        }
    }
}

private struct KubeActiveForwards: View {
    let contextName: String?
    let close: () -> Void
    var body: some View {
        let all = KubeForward.shared.forwards
        let mine = contextName.map { c in all.filter { $0["contextName"].string == c } } ?? all
        DialogScaffold(title: contextName != nil ? "Active port-forwards" : "All active port-forwards") {
            VStack(alignment: .leading, spacing: 6) {
                if mine.isEmpty { Text("Nothing is being forwarded right now.").foregroundStyle(Theme.shared.p.muted) }
                ForEach(Array(mine.enumerated()), id: \.offset) { _, f in
                    let port = Int(f["port"].double ?? 0)
                    let ns = f["namespace"].string?.nilIfEmpty.map { " (\($0))" } ?? ""
                    HStack {
                        Text("\(f["resource"].string ?? "")/\(f["name"].string ?? "")\(ns) — localhost:\(port) → :\(f["remotePort"].stringish ?? "")")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Copy") { Clipboard.write("localhost:\(port)"); StatusBus.shared.toast("Copied") }.buttonStyle(.ghostSmall)
                        Button("Stop") { Task { await KubePodMenu.confirmStop(f) } }.buttonStyle(.ghostSmall)
                    }
                }
            }
        } footer: {
            Button("Close") { close() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
        }
    }
}
