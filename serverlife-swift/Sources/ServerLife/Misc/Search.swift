import AppKit
import Foundation

/// Search everything — the box at the top right of the window (search.js).
///
/// One place to type a name and get to it, whatever it is: a host, a saved
/// profile, a cluster or beam, an open tab, a macro or snippet, a layout, a
/// multi-exec run from the history, a saved AI prompt or response, something
/// from the menus, or a setting. Results are grouped by kind, best match first;
/// Enter opens the first, the arrows move, Escape leaves. ⌘P from anywhere.
enum MiscSearch {
    struct Item {
        var kind: String
        var name: String
        var extra = ""
        var meta = ""
        var open: @MainActor () -> Void = {}
        /// What an agent is told about it (see `searchData`).
        var data: [String: JSON] = [:]
        var score: Double = 0
    }

    struct Group {
        var kind: String
        var title: String
        var items: [Item]
        var more: Int
    }

    /// How well `q` matches an item: every word must be found somewhere in its
    /// text, and a name that starts with the query, or a word in it that does,
    /// ranks above a match in the middle of its details. 0 is no match.
    static func scoreMatch(_ q: String, _ name: String, _ extra: String = "") -> Double {
        let words = q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.isEmpty { return 0 }
        let n = name.lowercased()
        let all = "\(n) \(extra.lowercased())"
        var score = 0.0
        for w in words {
            if !all.contains(w) { return 0 }
            if n == w { score += 100 }
            else if n.hasPrefix(w) { score += 60 }
            else if n.range(of: "(^|[\\s._:/@=-])" + NSRegularExpression.escapedPattern(for: w), options: .regularExpression) != nil { score += 40 }
            else if n.contains(w) { score += 25 }
            else { score += 5 }
        }
        // Shorter names are closer matches for the same words.
        return score + max(0, 20 - Double(n.utf16.count) / 4)
    }

    /// The menus, as things to search for: what each is called, other words
    /// for it, and the action it runs.
    static let commands: [(String, String, String)] = [
        ("New session…", "connect open host", "new-session"),
        ("New local shell", "terminal local", "new-local"),
        ("Quick connect…", "ssh telnet vnc rdp serial address", "quick-connect"),
        ("Add a server…", "new server ssh config", "add-server"),
        ("New window", "", "new-window"),
        ("Multi-exec", "run command many hosts fleet staged", "multiexec"),
        ("Broadcast typing", "type all panes", "broadcast"),
        ("Command snippets…", "snippet saved commands", "snippets"),
        ("Run a macro…", "macro", "run-macro"),
        ("SSH keys…", "agent keys identity", "keys"),
        ("Network and certificate tools…", "ping port dns trace network certificate cert ssh jwt spiffe svid subnet cidr url decode", "nettools"),
        ("Cluster info", "teleport cluster network", "cluster-info"),
        ("S3 buckets…", "aws s3 bucket", "s3"),
        ("Teleport panel", "teleport clusters roles requests vnet", "teleport-panel"),
        ("Sign in to Teleport…", "tsh login", "tsh-login"),
        ("Access request monitor", "requests approve", "request-monitor"),
        ("Session history", "recent sessions", "history"),
        ("Session recordings", "recordings playback teleport", "recordings"),
        ("Toggle the session log", "log record output", "toggle-log"),
        ("Find in terminal", "search find text", "find"),
        ("Split right", "pane", "split-right"),
        ("Split down", "pane", "split-down"),
        ("Split right with another host…", "pane", "split-right-host"),
        ("Split down with another host…", "pane", "split-down-host"),
        ("Duplicate tab", "", "duplicate-tab"),
        ("Close pane", "", "close-pane"),
        ("Disconnect", "close end", "disconnect"),
        ("File browser", "files sftp explorer", "toggle-files"),
        ("Local files", "files local upload download", "local-files"),
        ("Transfers", "uploads downloads forwards tunnels", "toggle-transfers"),
        ("Sidebar", "hosts list", "toggle-sidebar"),
        ("AI assistant", "claude codex copilot gemini ai", "toggle-ai"),
        ("Save layout as…", "workspace layout", "save-layout-as"),
        ("Load layout…", "workspace layout", "load-layout"),
        ("Manage layouts…", "workspace layout", "manage-layouts"),
        ("Refresh hosts", "reload inventory", "refresh"),
        ("Settings…", "preferences options", "settings"),
        ("Take the tour", "tour help introduction", "tour"),
        ("Guide", "help manual", "guide"),
        ("What\u{2019}s new", "version history changelog", "version-history"),
        ("About ServerLife", "version", "about"),
        ("Zoom in", "font bigger", "zoom-in"),
        ("Zoom out", "font smaller", "zoom-out"),
    ]

    static let kinds: [(String, String)] = [
        ("tab", "Open tabs"), ("host", "Hosts"), ("profile", "Saved profiles"), ("beam", "Beams"), ("cluster", "Clusters"),
        ("macro", "Macros"), ("snippet", "Snippets"), ("layout", "Layouts"), ("run", "Multi-exec runs"),
        ("prompt", "AI prompts"), ("response", "AI responses"), ("command", "Actions"), ("setting", "Settings"),
    ]
    static func kindTitle(_ k: String) -> String { kinds.first { $0.0 == k }?.1 ?? k }
    static let perKind = 6

    /// What an agent does next with each kind of result.
    static let next: [String: String] = [
        "tab": "serverlife_read_output with tab = its index, or serverlife_close_session with index",
        "host": "serverlife_open_session with host = its name, cluster for a Teleport node, login if wanted",
        "profile": "serverlife_open_session with host = the profile name",
        "beam": "serverlife_open_session with host = the beam name",
        "cluster": "serverlife_list_hosts or serverlife_list_clusters",
        "macro": "serverlife_run_macro with its name",
        "snippet": "its command, for the user to run",
        "layout": "serverlife_load_layout with its name",
        "run": "the hosts and command it ran, for the user to run again from multi-exec",
        "prompt": "its text",
        "response": "the file at its path",
    ]

    /// The results for a query: grouped, best first, a few of each kind.
    static func rank(_ items: [Item], _ q: String, per: Int = perKind) -> [Group] {
        let scored: [Item] = items.compactMap { it in
            var it = it
            it.score = scoreMatch(q, it.name, it.extra)
            return it.score > 0 ? it : nil
        }
        var groups: [Group] = []
        for (kind, title) in kinds {
            // Stable, so equal scores keep the order they were gathered in.
            let list = scored.enumerated().filter { $0.element.kind == kind }
                .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
                .map(\.element)
            if !list.isEmpty { groups.append(Group(kind: kind, title: title, items: Array(list.prefix(per)), more: list.count - per)) }
        }
        // The kind with the best single match goes first.
        return groups.enumerated().sorted {
            $0.element.items[0].score != $1.element.items[0].score
                ? $0.element.items[0].score > $1.element.items[0].score : $0.offset < $1.offset
        }.map(\.element)
    }

    /// The search, for an agent (the MCP serverlife_search tool): the same
    /// matches as the box, as plain data — the actions and settings the box
    /// also offers are left out, as nothing an agent can use.
    @MainActor
    static func searchData(_ q: String, limit: Int = 8, kinds want: [String]? = nil, window: WindowModel?) -> JSON {
        let per = max(1, min(50, limit))
        let wantSet = (want?.isEmpty == false) ? Set(want!) : nil
        let items = everything(window).filter { $0.kind != "command" && (wantSet == nil || wantSet!.contains($0.kind)) }
        let groups = rank(items, q, per: per)
        let total = groups.reduce(0) { $0 + $1.items.count + max(0, $1.more) }
        return [
            "query": .string(q),
            "total": .number(Double(total)),
            "groups": .array(groups.map { g in
                [
                    "kind": .string(g.kind), "title": .string(g.title), "next": JSON(next[g.kind]),
                    "more": .number(Double(max(0, g.more))),
                    "results": .array(g.items.map { it in
                        var o: [String: JSON] = ["name": .string(it.name), "summary": .string(it.meta)]
                        for (k, v) in it.data { o[k] = v }
                        return .object(o)
                    }),
                ]
            }),
        ]
    }

    // MARK: Sources

    /// Everything searchable, as of now.
    @MainActor
    static func everything(_ window: WindowModel?) -> [Item] {
        var out: [Item] = []
        func add(_ kind: String, _ name: String, _ extra: String, _ meta: String,
                 _ data: [String: JSON] = [:], _ open: @escaping @MainActor () -> Void) {
            out.append(Item(kind: kind, name: name, extra: extra, meta: meta, open: open, data: data))
        }
        let sw = window?.feature(SessionsWindow.self)

        for (i, t) in (sw?.tabs ?? []).enumerated() {
            add("tab", t.title.isEmpty ? "Tab" : t.title, "", "open tab", ["index": .number(Double(i))]) {
                sw?.selectTab(index: i)
            }
        }

        let inv = Inventory.shared
        let beamNodes = inv.beamNodeNames()
        for key in inv.nodesByKey.keys.sorted() {
            for n in inv.nodesByKey[key] ?? [] where !beamNodes.contains(n.name) {
                let labels = n.labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                add("host", n.name,
                    "\(n.hostname ?? "") \(n.addr ?? "") \(n.cluster ?? "") \(labels.joined(separator: " ")) \(n.uuid ?? n.id)",
                    [n.cluster ?? "", labels.prefix(3).joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " · "),
                    ["type": "teleport", "cluster": JSON(n.cluster), "hostname": JSON(n.hostname), "addr": JSON(n.addr),
                     "uuid": JSON(n.uuid ?? n.id), "labels": .object(n.labels.mapValues { .string($0) })]) {
                    Actions.shared.perform("open-host-from-list", window: window, host: n)
                }
            }
        }
        for h in inv.sshHosts {
            let name = h.alias ?? h.name
            add("host", name, "\(h.hostname ?? "") \(h.user ?? "")", "\(h.user.map { $0 + "@" } ?? "")\(h.hostname ?? "") · ssh",
                ["type": "ssh", "alias": JSON(h.alias), "hostname": JSON(h.hostname), "user": JSON(h.user),
                 "port": h.port.map { .number(Double($0)) } ?? .null]) {
                Actions.shared.perform("open-host-from-list", window: window, host: h)
            }
        }
        for proxy in inv.beamsByProxy.keys.sorted() {
            for b in inv.beamsByProxy[proxy] ?? [] {
                add("beam", b.id, "\(b.proxy) beam", b.proxy.isEmpty ? "beam" : b.proxy, ["proxy": .string(b.proxy)]) {
                    Actions.shared.perform("beam-open", window: window, args: ["beam": b])
                }
            }
        }

        for p in Store.shared.listProfiles() {
            let s = { (k: String) in p[k].stringish ?? "" }
            let meta = [s("type"), s("node").isEmpty ? s("hostname") : "\(s("node")) @ \(s("cluster"))"].filter { !$0.isEmpty }
            add("profile", s("name"), "\(s("alias")) \(s("node")) \(s("cluster")) \(s("hostname")) \(s("type"))",
                meta.joined(separator: " · "),
                ["type": p["type"], "node": p["node"], "cluster": p["cluster"], "hostname": p["hostname"], "alias": p["alias"]]) {
                Actions.shared.perform("launch-profile", window: window, args: ["profile": p])
            }
        }

        var seen = Set<String>()
        for p in inv.profiles {
            let cluster = p.cluster.isEmpty ? p.proxy : p.cluster
            let key = "\(cluster)\u{0}\(p.home ?? "")"
            if !seen.insert(key).inserted { continue }
            add("cluster", cluster, "\(p.proxy) \(p.roles.joined(separator: " ")) teleport",
                "\(p.username)\(p.proxy.isEmpty ? "" : " · " + p.proxy)",
                ["proxy": .string(p.proxy), "user": .string(p.username), "roles": JSON(p.roles)]) {
                Actions.shared.perform("teleport-panel", window: window)
            }
        }

        for m in Macros.shared.all {
            add("macro", m.name, "\(m.category) \(m.command)", m.category.isEmpty ? "macro" : m.category,
                ["category": .string(m.category.isEmpty ? "Custom" : m.category), "command": .string(m.command)]) {
                guard sw?.activePane?.hasTerm == true else {
                    StatusBus.shared.toast("Open a session to run the macro in, then choose it again", kind: .info)
                    return
                }
                Task { @MainActor in await Macros.shared.send(m, window: window) }
            }
        }

        for sn in Store.shared.listSnippets() {
            let cmd = sn["command"].stringish ?? ""
            add("snippet", sn["name"].stringish ?? "", cmd, String(cmd.prefix(60)), ["command": .string(cmd)]) {
                if sw?.activePane?.hasTerm == true { Snippets.run(sn, all: false, window: window) }
                else { Actions.shared.perform("snippets", window: window) }
            }
        }
        for l in WorkspaceStore.listLayouts() {
            let n = l.workspace["tabs"].items.count
            add("layout", l.name, "layout workspace", "\(n) tab(s)", ["tabs": .number(Double(n))]) {
                Task { @MainActor in await sw?.loadLayout(l, detail: true) }
            }
        }
        for r in Store.shared.listExecRuns().prefix(200) {
            let hosts = r["hosts"].items.compactMap(\.stringish)
            let q = r["selector"]["query"].stringish ?? ""
            let runAs = r["runAs"].stringish ?? ""
            add("run", r["command"].stringish ?? "", "\(hosts.joined(separator: " ")) \(r["label"].stringish ?? "") \(q) \(runAs)",
                [q.isEmpty ? "\(hosts.count) host(s)" : "by tag \(q)", runAs.isEmpty ? "" : "as \(runAs)"].filter { !$0.isEmpty }.joined(separator: " · "),
                ["hosts": JSON(hosts), "tagQuery": JSON(q.nilIfEmpty), "runAs": JSON(runAs.nilIfEmpty),
                 "ok": r["ok"], "failed": r["failed"], "at": r["at"]]) {
                guard let window else { return }
                window.feature(FleetWindow.self).editRun(r)
                window.showDock("multiexec")
            }
        }

        // Saved AI prompts and responses belong to [ai]; asked for, and empty until it answers.
        for p in aiList("ai-saved-prompts", window) {
            let text = p["text"].stringish ?? ""
            add("prompt", p["name"].stringish ?? "", text, "send to the AI assistant", ["text": .string(text)]) {
                Actions.shared.perform("ai-ask", window: window, args: ["text": text, "send": true])
            }
        }
        for r in aiList("ai-saved-responses", window) {
            let when = r["mtime"].double.map {
                DateFormatter.localizedString(from: Date(timeIntervalSince1970: $0 / 1000), dateStyle: .short, timeStyle: .none)
            } ?? ""
            add("response", r["title"].stringish ?? "", r["file"].stringish ?? "", when,
                ["path": r["path"], "saved": r["mtime"]]) {
                Actions.shared.perform("ai-saved-open", window: window)
            }
        }

        for (name, extra, action) in commands {
            add("command", name, extra, "") { Actions.shared.perform(action, window: window) }
        }
        return out
    }

    @MainActor
    private static func aiList(_ id: String, _ window: WindowModel?) -> [JSON] {
        guard Actions.shared.isRegistered(id) else { return [] }
        var got: [JSON] = []
        let reply: (Any?) -> Void = { v in
            if let j = v as? [JSON] { got = j } else if let j = v as? JSON { got = j.items }
        }
        Actions.shared.perform(id, window: window, args: ["reply": reply])
        return got
    }
}
