import SwiftUI

/// tshenv.js `editClusterEnv` / `clusterEnvTag`: the variables tsh runs with
/// for one cluster, from its heading's menu (action `tsh-env-edit`, args
/// `proxy`, `cluster`). Stored in `settings.clusterTshEnv[bareProxy]`, on top
/// of those for every cluster (Locate tsh / ssh…, the misc owner's box).
///
/// The case this is for: Teleport's client tools version, as its docs
/// describe it — TELEPORT_TOOLS_VERSION=18.11.9 for one cluster has tsh fetch
/// and run that version for it, and every other cluster keeps its own.
@MainActor
enum TshEnvUI {
    static func edit(proxy: String, cluster: String?, window: WindowModel?) {
        let label = cluster?.nilIfEmpty ?? proxy
        // The example is the docs' one, not the cluster's own version: a
        // cluster on a pre-release reports a version only its own CDN serves.
        let model = Local(MiscTshEnv.clusterText(proxy))
        _ = TUIModal.show(window, title: "tsh environment for this cluster", width: 600) { handle in
            TshEnvDialog(label: label, text: model, handle: handle) { text in
                save(proxy: proxy, label: label, text: text)
            }
        }
    }

    /// Stores (or removes) the cluster's text and reads the cluster again —
    /// what its tsh can do may have changed with them.
    static func save(proxy: String, label: String, text: String, store: Store = .shared) {
        var all = store.settings["clusterTshEnv"].object ?? [:]
        let key = MiscTshEnv.bareProxy(proxy)
        if text.isEmpty { all.removeValue(forKey: key) } else { all[key] = .string(text) }
        store.setSettingJSON("clusterTshEnv", .object(all))
        TshEnv.applySettings()
        TUIStatus.show(text.isEmpty ? "No tsh variables for \(label)" : "tsh variables set for \(label)")
        Task {
            await Inventory.shared.refreshBeams(refresh: true, proxy: proxy)
            if let p = Inventory.shared.profiles.first(where: { $0.proxy == proxy }) {
                await Inventory.shared.refreshProfile(p)
            }
        }
    }

    /// `clusterEnvTag`'s tooltip: the lines, secret-looking values masked;
    /// nil while the cluster has no variables of its own.
    static func tagTooltip(_ proxy: String?) -> String? {
        let text = MiscTshEnv.clusterText(proxy)
        if text.isEmpty { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmed }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.replacingOccurrences(of: #"^export\s+"#, with: "", options: .regularExpression) }
            .map { l -> String in
                guard let i = l.firstIndex(of: "="), i > l.startIndex else { return l }
                let name = String(l[..<i])
                let value = String(l[l.index(after: i)...])
                    .replacingOccurrences(of: #"^["']|["']$"#, with: "", options: .regularExpression)
                return "\(name)=\(MiscTshEnv.shown(name, value))"
            }
        return "tsh runs with, for this cluster:\n\(lines.joined(separator: "\n"))\nClick or right-click the heading to change."
    }
}

/// A heading's `env` tag, while a cluster has variables of its own. Click
/// to change them. For the sidebar's cluster headings: `TshEnvTag(proxy:cluster:window:)`.
struct TshEnvTag: View {
    let proxy: String
    var cluster: String? = nil
    var window: WindowModel? = nil
    var body: some View {
        if let tip = TshEnvUI.tagTooltip(proxy) {
            Button { TshEnvUI.edit(proxy: proxy, cluster: cluster, window: window) } label: {
                TUITag(text: "env", help: tip)
            }.buttonStyle(.plain)
        }
    }
}

private struct TshEnvDialog: View {
    let label: String
    @ObservedObject var text: Local<String>
    let handle: ModalHandle
    let onSave: (String) -> Void

    var body: some View {
        DialogScaffold(title: "tsh environment for this cluster", subtitle: label) {
            MiscField(label: "Variables",
                      hint: "One NAME=value per line, as in Teleport\u{2019}s docs (a pasted export NAME=value works too). "
                        + "Set for every tsh run against this cluster — its sessions, beams, Phases and logins — on top of those "
                        + "for every cluster in Locate tsh / ssh…. TELEPORT_TOOLS_VERSION runs this cluster on that version "
                        + "of tsh, fetched on first use.") {
                MiscEnvBox(text: $text.value)
            }
        } footer: {
            Spacer()
            Button("Cancel") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") {
                if MiscTshEnv.note(text.value).error { TUIStatus.toast("Some lines are not NAME=value", "error"); return }
                handle.close()
                onSave(text.value.trimmed)
            }.buttonStyle(.primary)
        }
        .frame(width: 600)
    }
}
