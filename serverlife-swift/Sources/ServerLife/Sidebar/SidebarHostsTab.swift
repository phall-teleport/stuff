import SwiftUI

/// pinned.js: saved clusters pinned to the Hosts tab that `tsh status` does
/// not list. A logout deletes the profile, and with it the only thing the
/// list was drawn from; a pinned saved cluster stands in for it — shaped like
/// an expired one, under the group key the real profile used, so folders,
/// order and watches all still belong to it.
@MainActor
enum SBPinned {
    static func bareProxy(_ s: String?) -> String {
        (s ?? "").trimmed.lowercased().replacingOccurrences(of: ":443$", with: "", options: .regularExpression)
    }

    /// `savedOnlyProfiles()`: each with the saved record it stands for.
    static func profiles() -> [(profile: TeleportProfile, saved: JSON)] {
        let listed = Set(Inventory.shared.profiles.map { "\(bareProxy($0.proxy))|\($0.home ?? "")" })
        var seen = Set<String>()
        var out: [(TeleportProfile, JSON)] = []
        for t in Inventory.savedLogins() {
            guard t["showInHosts"].truthy, let proxy = t["proxy"].stringish?.nilIfEmpty else { continue }
            let home = t["home"].stringish ?? ""
            let id = "\(bareProxy(proxy))|\(home)"
            if listed.contains(id) || seen.contains(id) { continue }
            seen.insert(id)
            // Profiles always carry the port; a saved address may not.
            let full = proxy.range(of: ":\\d+$", options: .regularExpression) != nil ? proxy : proxy + ":443"
            var p = TeleportProfile(proxy: full, cluster: t["cluster"].stringish ?? "", username: t["user"].stringish ?? "",
                                    expired: true, home: home.nilIfEmpty,
                                    homeDir: home.nilIfEmpty ?? TeleportHomes.defaultHome)
            // Unnamed when saved: the watches remember what the cluster called itself.
            if p.cluster.isEmpty {
                p.cluster = HostWatch.watchedIn(FolderModel.groupKey(for: p)).compactMap { $0["cluster"].string?.nilIfEmpty }.first ?? ""
            }
            out.append((p, t))
        }
        return out
    }

    static func isSavedOnly(_ p: TeleportProfile) -> Bool {
        p.expired && !Inventory.shared.profiles.contains { $0.key == p.key }
    }

    /// `unpinSavedCluster`: every pinned record for the cluster, or another
    /// account's would keep it here.
    static func unpin(_ t: JSON, name: String) {
        let same = Inventory.savedLogins().filter {
            $0["showInHosts"].truthy && bareProxy($0["proxy"].stringish) == bareProxy(t["proxy"].stringish)
                && ($0["home"].stringish ?? "") == (t["home"].stringish ?? "")
        }
        for var s in (same.isEmpty ? [t] : same) {
            s["showInHosts"] = false
            _ = TeleportPanel.saveClusterLogin(s)
        }
        StatusBus.shared.show("\(name) is no longer kept on the Hosts tab")
    }
}

@MainActor
extension SB2 {
    /// Everything the Hosts tab draws (`renderHostsTab`), groups in the user's order.
    static func hostsTab(_ sw: SidebarWindow) -> [SBEntry] {
        let entries = hostsTabEntries(sw)
        // `drawnHosts`: what the rows drew, ghosts and requestable rows
        // included, so the ticked ids resolve back to hosts.
        var drawn: [String: Host] = [:]
        for case .group(let g) in entries {
            for case .host(let h) in g.items { drawn[h.host.id] = h.host }
        }
        sw.drawnHosts = drawn
        return entries
    }

    private static func hostsTabEntries(_ sw: SidebarWindow) -> [SBEntry] {
        var entries: [SBEntry] = []
        if inv.loading && inv.nodesByKey.isEmpty && inv.sshHosts.isEmpty {
            return [.note(id: "loading", lines: ["Loading inventory…"], kind: .loading)]
        }
        // A Teleport-sourced kube cluster nests inside its own cluster's group,
        // the same place beams do; only a context with no Teleport cluster
        // behind it shows up in its own flat group, at the end.
        let kindShown = sw.hostKindShown
        let filtering = !sw.filterText.isEmpty

        // Starred, gathered — skipped for "K8s only".
        if kindShown != "kube" && HostPrefs.starredMode == "group" {
            let starred = starredHosts().filter { visibleHost($0, sw) }
            if !starred.isEmpty {
                entries.append(.group(SBGroup(key: "starred", title: "Starred", count: starred.count, tags: [.gathered],
                    items: starred.map { h in .host(SBHostItem(host: h, label: h.type == Host.teleport ? labelSummary(h) : (h.viaTsh ? "tsh" : (h.user ?? "")), groupKey: "starred")) })))
            }
        }

        // Teleport clusters, then the saved ones pinned here.
        let beamNodes = inv.beamNodeNames()
        let pinned = SBPinned.profiles()
        let all: [(TeleportProfile, JSON?)] = inv.profiles.map { ($0, nil) } + pinned.map { ($0.profile, $0.saved) }
        for (p, saved) in all {
            let key = FolderModel.groupKey(for: p)
            let nodes = inv.nodesByKey[p.key] ?? []
            let reachable = nodes.filter { !beamNodes.contains($0.name) }
            let askable = kindShown == "kube" ? [] : SBRequestableCache.shared.hosts(for: p)
            var have = Set(reachable.compactMap(\.uuid))
            let held = Narrowed.heldBack(for: p, reachable: reachable)
            for h in held { if let u = h.uuid { have.insert(u) } }
            let kubeHosts = kindShown == "ssh" || p.expired ? [] : SBKube.hosts(for: p)
            let ssh = kindShown == "kube" ? [] : reachable + held + askable.filter { !have.contains($0.uuid ?? "") }
            let shown = (ssh + kubeHosts).filter { visibleHost($0, sw) }
            if p.expired {
                entries.append(.group(expiredGroup(p, saved: saved, key: key, sw)))
                continue
            }
            let beamRows = kindShown == "kube" ? [] : beamItems(p, sw)
            // "K8s only": a cluster with no kube clusters has nothing to show.
            if kindShown == "kube" && shown.isEmpty { continue }
            if shown.isEmpty && beamRows.isEmpty && filtering { continue }
            var rows = groupRows(key, shown, sw) { labelSummary($0) }
            if Narrowed.isNarrowed(p) { rows.insert(.narrowed(p, granted: reachable.count), at: 0) }
            if rows.isEmpty {
                rows = [.empty(id: key + "|none", lines: [kindShown == "kube" ? "No Kubernetes clusters visible." : "No nodes visible."],
                               kind: .noNodes)]
            }
            var tags: [SBGroupTag] = [.home(p), .leaf(p), .requests(p),
                                      .refresh(key: key, title: "Re-read this cluster: its nodes, its leaves and its beams", profile: p)]
            let beams = BeamsUI.visibleBeams(p.proxy).count
            if inv.beamsSupported(p.proxy) && beams > 0 { tags.append(.beams(beams)) }
            tags += [.vnet(p), .env(p)]
            if p.active { tags.append(.active) }
            if TeleportPanel.expiringSoon(p) { tags.append(.soon(p)) }
            entries.append(.group(SBGroup(key: key, title: p.cluster.nilIfEmpty ?? p.proxy, count: shown.count, profile: p,
                                          tags: tags, items: rows + beamRows)))
        }

        if filtering && inv.profiles.contains(where: { !$0.expired })
            && !inv.allNodes.contains(where: { visibleHost($0, sw) }) {
            entries.append(.note(id: "filtermiss", lines: [
                "No Teleport node matches \(sw.filterText).",
                "Tags match as key=value, key:partial, key=a,b for either, or -key=value to exclude.",
            ], kind: .filterMiss))
        }

        if let err = inv.teleportError, inv.profiles.isEmpty, tshMissing() || pinned.isEmpty {
            let missing = tshMissing()
            entries.append(.group(SBGroup(key: "tp:none", title: "Teleport", count: 0, items: [
                .empty(id: "tp:none", lines: [
                    missing ? "tsh was not found on this machine." : err,
                    missing ? "Clusters are read through tsh, so nothing can be listed until it is located."
                            : "Run tsh login, then Refresh.",
                ], kind: .tpError(missing: missing)),
            ])))
        }

        // ssh_config hosts are SSH-only, so "K8s only" leaves them out.
        if kindShown != "kube" { entries += sshGroups(sw) }

        // This machine: a local shell, the AI assistants and the network tools
        // are as much for working on a cluster as on a server. SSH keys are
        // the one row about SSH alone.
        var local: [SBItem] = [.local("shell"), .local("ai")]
        if kindShown != "kube" { local.append(.local("keys")) }
        local.append(.local("nettools"))
        entries.append(.group(SBGroup(key: "local", title: "Local", count: local.count, items: local)))

        // Watched hosts with nowhere left to be drawn: not in "K8s only" either.
        // A pinned saved cluster draws its own watches, in its own group.
        if kindShown != "kube" {
            let drawn = folderGroups().map(\.key) + pinned.map { FolderModel.groupKey(for: $0.profile) }
            let orphans = HostWatch.orphanGhosts(drawn).filter { sw.hostMatches($0) }
            if !orphans.isEmpty {
                let goneN = orphans.filter(\.watchMissing).count
                var tags: [SBGroupTag] = []
                if goneN > 0 { tags.append(.gone(goneN)) }
                if orphans.count - goneN > 0 { tags.append(.unchecked(orphans.count - goneN)) }
                entries.append(.group(SBGroup(key: "gone", title: "Watched", count: orphans.count, tags: tags,
                    items: orphans.map { .host(SBHostItem(host: $0, label: labelSummary($0), groupKey: $0.watchGroup ?? "gone")) })))
            }
        }

        // Contexts with no Teleport cluster behind them (raw EKS/GKE/kind).
        if kindShown != "ssh", SBKube.localCount > 0, Slots.sidebarSections["kube"] != nil {
            entries.append(.group(SBGroup(key: "kube-local", title: "☸ Local kubeconfigs", count: SBKube.localCount, items: [.kubeLocal])))
        }

        return applyGroupOrder(entries)
    }

    /// A lapsed or logged-out cluster: its watched hosts (still watched, and
    /// the gone ones still gone), the last known hosts when Settings says
    /// to, and the login buttons.
    static func expiredGroup(_ p: TeleportProfile, saved: JSON?, key: String, _ sw: SidebarWindow) -> SBGroup {
        let ghosts = (HostWatch.missingIn(key, []) + HostWatch.unconfirmedIn(key, []))
            .filter { visibleHost($0, sw) && sw.inKindShown($0) }
        // Everything else the last successful read had — Settings → "Show the
        // last known hosts" says whether to, and for how long. Off by default.
        let listMode = SB.store.setting("expiredListMode", "off")
        var lastKnown: [Host] = []
        if listMode != "off" && sw.hostKindShown != "kube" {
            let hours = SB.store.setting("expiredListHours", 1.0)
            let maxAge: Double? = listMode == "always" ? nil : (hours > 0 ? hours : 1) * 3_600_000
            if let read = Narrowed.lastFullRead(for: p.key, maxAgeMs: maxAge) {
                let already = Set(ghosts.compactMap(\.uuid))
                lastKnown = read.nodes.filter { ($0.uuid?.isEmpty == false) && !already.contains($0.uuid!) }.map { n in
                    var h = n
                    h.extra["unconfirmed"] = true
                    h.extra["lastSeen"] = .number(read.at)
                    return h
                }.filter { visibleHost($0, sw) }
            }
        }
        var items: [SBItem] = (ghosts + lastKnown).map { .host(SBHostItem(host: $0, label: labelSummary($0), groupKey: key)) }
        items.append(.expired(p, saved: saved))
        let title = p.cluster.nilIfEmpty ?? saved?["name"].stringish?.nilIfEmpty ?? p.proxy
        return SBGroup(key: key, title: title, count: 0, profile: p,
                       tags: [.home(p), .requests(p), saved != nil ? .loggedOut : .expired,
                              .refresh(key: key, title: "Re-read this cluster", profile: saved != nil ? nil : p)],
                       items: items)
    }

    /// ssh_config hosts, one group per config file, in the order configured.
    static func sshGroups(_ sw: SidebarWindow) -> [SBEntry] {
        var entries: [SBEntry] = []
        let sshShown = inv.sshHosts.filter { visibleHost($0, sw) }
        let noSsh = sshMissing()
        for root in configRoots() {
            let mine = sshHosts(of: root, sshShown)
            if !root.primary && !sw.filterText.isEmpty && mine.isEmpty { continue }
            let sshRows = groupRows(root.key, mine, sw) { sshLabel($0) }
            var rows: [SBItem] = []
            if root.primary && noSsh {
                rows.append(.empty(id: "nossh", lines: ["No ssh client on this machine.",
                                                         "These hosts need OpenSSH; Teleport nodes open with tsh ssh instead."], kind: .noSsh))
            }
            if sshRows.isEmpty {
                let line = !sw.filterText.isEmpty ? "No matches." : !root.exists ? "That file is not there." : "No hosts in \(root.label)."
                rows.append(.empty(id: root.key + "|none", lines: [line], kind: .sshEmpty(primary: root.primary, showButton: sw.filterText.isEmpty)))
            } else {
                rows += sshRows
            }
            var tags: [SBGroupTag] = []
            if !root.exists { tags.append(.missingFile(root.file)) }
            if !root.primary { tags.append(.extraFile(root.file)) }
            tags.append(.refresh(key: root.key, title: "Re-read the ssh config files", profile: nil))
            entries.append(.group(SBGroup(key: root.key, title: root.label, count: mine.count, tags: tags, items: rows)))
        }
        return entries
    }
}
