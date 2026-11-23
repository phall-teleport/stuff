import AppKit
import SwiftUI

/// Folders, folder browser, hosts pane, saved profiles, add server, quick connect, history (folders.js …).
///
/// Owner: hosts (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens: register
/// actions, slots, status items and timers here.
@MainActor
enum HostsFeature {
    static func install() {
        let a = Actions.shared

        a.register("quick-connect") { ctx in
            var initial: [String: String] = [:]
            for k in ["target", "identityFile", "proxyJump", "command"] { if let v = ctx.arg(k, as: String.self) { initial[k] = v } }
            QuickConnect.openDialog(ctx.window, initial: initial)
        }

        a.register("add-server") { ctx in
            var i = AddServer.Initial()
            if let v = ctx.arg("name", as: String.self) { i.name = v }
            if let v = ctx.arg("hostname", as: String.self) { i.hostname = v }
            if let v = ctx.arg("user", as: String.self) { i.user = v }
            if let v = ctx.arg("port", as: Int.self) { i.port = v }
            if let v = ctx.arg("identityFile", as: String.self) { i.identityFile = v }
            if let v = ctx.arg("proxyJump", as: String.self) { i.proxyJump = v }
            if let v = ctx.arg("extraOptions", as: String.self) { i.extraOptions = v }
            if let v = ctx.arg("destination", as: String.self) { i.destination = v }
            if let v = ctx.arg("configFile", as: String.self) { i.configFile = v }
            if let v = ctx.arg("alias", as: String.self) { i.alias = v }
            AddServer.openDialog(ctx.window, initial: i)
        }

        // ⌘Y: Teleport → Session History… opened recordings.js's Sessions
        // dialog on its "Connection history" tab (index.js), which is
        // teleport-ui's. Forwarded there.
        a.register("history") { ctx in
            Actions.shared.perform("recordings", window: ctx.window, args: ["tab": "history"])
        }

        // history.js — the pane menu's "Command history on this host…".
        a.register("command-history") { ctx in
            CommandHistory.open(ctx.window, paneId: ctx.paneId, connId: ctx.connId)
        }

        a.register("edit-profile") { ctx in
            if let p = profileArg(ctx) { Profiles.openEditor(ctx.window, initial: p) }
            else { HToast.error("That profile is not there any more") }
        }
        a.register("new-profile") { ctx in
            Profiles.openEditor(ctx.window, initial: ctx.arg("profile", as: JSON.self) ?? [:])
        }
        a.register("launch-profile") { ctx in
            guard let p = profileArg(ctx) else { return }
            // args `forceTerminal` Bool (sftp with a terminal), `split` "right"/"down".
            let force = ctx.arg("forceTerminal", as: Bool.self) ?? false
            let split = ctx.arg("split", as: String.self)
            Task { @MainActor in await Profiles.launch(p, window: ctx.window, forceTerminal: force, split: split) }
        }

        // profiles.js `openNewSessionDialog`. sessions owns the menu id
        // `new-session`; it is filled here only when nobody registered it.
        a.register("new-session-dialog") { ctx in NewSession.open(ctx.window) }
        if !a.isRegistered("new-session") {
            a.register("new-session") { ctx in NewSession.open(ctx.window) }
        }

        // profiles.js `pickHost`: args `title`, `includeLocal` Bool, and
        // `reply: (HostPick?) -> Void` or (as sessions calls it)
        // `completion: ([String: Any]?) -> Void` with ["kind": "local"] or
        // ["kind": "host", "host": Host, "login": String?].
        a.register("pick-host") { ctx in
            let reply = ctx.arg("reply", as: ((HostPick?) -> Void).self)
            let completion = ctx.arg("completion", as: (([String: Any]?) -> Void).self)
            NewSession.pickHost(ctx.window, title: ctx.arg("title", as: String.self) ?? "Choose a host",
                                includeLocal: ctx.arg("includeLocal", as: Bool.self) ?? true) { pick in
                reply?(pick)
                guard let completion else { return }
                guard let pick else { return completion(nil) }
                if pick.kind == "local" || pick.host == nil { return completion(["kind": "local"]) }
                var d: [String: Any] = ["kind": "host", "host": pick.host!]
                if let l = pick.login { d["login"] = l }
                completion(d)
            }
        }

        // addserver.js `removeManagedHost`: `host` (its alias) or args `alias`.
        a.register("remove-managed-host") { ctx in
            guard let alias = ctx.arg("alias", as: String.self) ?? ctx.host?.alias else { return }
            Task { @MainActor in await AddServer.removeManagedHost(alias, window: ctx.window) }
        }

        // folderview.js: args `groupKey`, `folderId`.
        a.register("folders-browser") { ctx in
            FolderBrowser.open(ctx.window, groupKey: ctx.arg("groupKey", as: String.self), folderId: ctx.arg("folderId", as: String.self))
        }
        // hostspane.js: args `groupKey`, `split` "right"/"down" (also `dir`).
        a.register("hosts-pane") { ctx in
            HostsPane.open(ctx.window, groupKey: ctx.arg("groupKey", as: String.self),
                           split: ctx.arg("split", as: String.self) ?? ctx.arg("dir", as: String.self))
        }
        // hostspane.js `pickedHostsOf(paneId)`: args `reply: ([Host]) -> Void`;
        // the hosts picked in that hosts pane (empty for any other pane).
        a.register("hosts-pane-picked") { ctx in
            let hosts = ctx.paneId.map { HostsPane.pickedHostsOf($0) } ?? []
            ctx.arg("reply", as: (([Host]) -> Void).self)?(hosts)
        }
        // folders.js `openFolderDialog`: args `groupKey`, `parentId` (new
        // inside), `folderId` (edit), `hosts` [Host] (default: the group's),
        // `completion: (HostFolder?) -> Void` (the folder made/edited, nil when cancelled).
        a.register("folder-dialog") { ctx in
            guard let g = ctx.arg("groupKey", as: String.self) ?? ctx.arg("folderId", as: String.self).flatMap({ FolderModel.folder(id: $0)?.group })
            else { return }
            FolderDialogs.openFolderDialog(ctx.window, group: g, parent: ctx.arg("parentId", as: String.self),
                                           folder: ctx.arg("folderId", as: String.self).flatMap { FolderModel.folder(id: $0) },
                                           hosts: ctx.arg("hosts", as: [Host].self) ?? HostsHooks.hostsInGroup(g),
                                           done: ctx.arg("completion", as: ((HostFolder?) -> Void).self))
        }
        // folders.js `exportFoldersDialog(groupKey)` / `importFoldersDialog(groups)`.
        a.register("folders-export") { ctx in
            Task { @MainActor in await FolderDialogs.exportFolders(ctx.window, groupKey: ctx.arg("groupKey", as: String.self)) }
        }
        a.register("folders-import") { ctx in
            Task { @MainActor in await FolderDialogs.importFolders(ctx.window, groups: HostsHooks.folderGroups()) }
        }

        // sshoptions.js: the "All SSH options…" dialog for `host`; args
        // `login`, `focus` "remoteForwards"/"dynamicForwards"/"reason".
        a.register("ssh-options") { ctx in
            guard let h = ctx.host else { return }
            let focus: SSHOptionsUI.Focus? = switch ctx.arg("focus", as: String.self) {
            case "remoteForwards": .remoteForwards
            case "dynamicForwards": .dynamicForwards
            case "reason": .reason
            default: nil
            }
            SSHOptionsUI.openDialog(h, login: ctx.arg("login", as: String.self), window: ctx.window, focus: focus)
        }
        // `sshOptionsMenu`: appends the "SSH options" submenu for `host` to
        // args `menu` (NSMenu), or hands it to `reply: (Any?) -> Void` as a
        // CtxItem. Args `login`, `openX11: () -> Void`.
        a.register("ssh-options-menu") { ctx in
            guard let h = ctx.host else { return }
            let item = SSHOptionsUI.menu(h, login: ctx.arg("login", as: String.self), window: ctx.window,
                                         openX11: ctx.arg("openX11", as: (() -> Void).self))
            if let reply = ctx.arg("reply", as: ((Any?) -> Void).self) { reply(item) }
            if let menu = ctx.arg("menu", as: NSMenu.self) {
                for mi in CtxMenu.build([item]).items { mi.menu?.removeItem(mi); menu.addItem(mi) }
            }
        }
        // sshpresets.js `editSshConfig(file)`: args `path` (nil = ~/.ssh/config), or `host`'s file.
        a.register("ssh-config-edit") { ctx in
            SSHConfigEditor.open(ctx.window, file: ctx.arg("path", as: String.self) ?? ctx.host?.configFile)
        }
        // addserver.js `removeSshConfigHost`: delete or comment out `host`'s block in its file.
        // folders.js migrateKubeHostKeys — kube-ui calls it as cluster rows are drawn.
        a.register("hosts-migrate-kube-keys") { ctx in
            KubeHostKeys.migrate(ctx.arg("hosts", as: [JSON].self) ?? [])
        }
        a.register("ssh-config-remove-host") { ctx in
            guard let h = ctx.host else { return }
            Task { @MainActor in await SSHConfigEditor.removeHost(h, window: ctx.window) }
        }

        FolderDialogs.install()
    }

    /// The Saved tab's profiles list, for the sidebar to embed.
    static func savedList(_ window: WindowModel?, _ filter: String) -> AnyView {
        AnyView(SavedProfilesList(window: window, filter: filter))
    }

    private static func profileArg(_ ctx: ActionContext) -> JSON? {
        if let p = ctx.arg("profile", as: JSON.self) { return p }
        return HostsData.profile(ctx.arg("profileId", as: String.self))
    }
}
