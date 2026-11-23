import Foundation

/// The window's half of the control socket (automation.js).
///
/// Tabs, panes and the live inventory belong to a window, so the verbs that
/// touch them are answered here, in the focused window. A throw becomes an
/// error the caller can read, which is the whole point of an interface
/// something else drives.
///
/// Nothing in here types into a session or runs a command of the caller's
/// choosing. Opening, closing, arranging and running a *saved* macro is the
/// extent of it — and reading back what a session shows, so an assistant that
/// ran a macro can see what it printed. (`type_text` is the exception, and it
/// asks the person first: it is answered by the AI feature's `ai-type-request`.)
@MainActor
enum AutomationWindow {
    nonisolated static let verbs: Set<String> = ["list_sessions", "list_macros", "open_session", "list_tmux", "open_sessions",
                                     "close_session", "load_layout", "save_layout", "run_macro", "focus_window",
                                     "get_settings", "set_settings", "search", "type_text", "read_output"]

    /// main.js `askRenderer` timeouts, per verb.
    static func timeout(_ verb: String) -> Double {
        switch verb {
        case "open_session", "list_tmux", "run_macro": return 120
        case "open_sessions", "load_layout", "type_text": return 300
        case "search": return 30
        default: return 60
        }
    }

    /// `askRenderer`: ask the window the user is looking at, and give up
    /// after a while — a window that never answers must not leave the caller hanging.
    static func ask(_ verb: String, _ params: JSON) async throws -> JSON {
        guard let w = WindowManager.shared.focused ?? WindowManager.shared.windows.first else {
            throw AppError("No ServerLife window is open.")
        }
        let limit = timeout(verb)
        // Whichever comes first answers; the window's work is left to finish
        // either way (it was asked to open things, and may yet).
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var cont: CheckedContinuation<JSON, Error>?
            func resume(_ r: Result<JSON, Error>) {
                let c: CheckedContinuation<JSON, Error>? = lock.withLock { let c = cont; cont = nil; return c }
                c?.resume(with: r)
            }
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            once.cont = c
            Task { @MainActor in
                do { once.resume(.success(try await handle(verb, params, window: w))) } catch { once.resume(.failure(error)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                once.resume(.failure(AppError("The window did not answer \"\(verb)\" in time.")))
            }
        }
    }

    static func handle(_ verb: String, _ p: JSON, window w: WindowModel) async throws -> JSON {
        switch verb {
        case "list_sessions": return try listSessions(w)
        case "open_session":
            let opened = try await openOne(p, window: w)
            return ["opened": opened["label"], "transport": .string(opened["transport"].string?.nilIfEmpty ?? "mux")]
        case "open_sessions": return try await openSessions(p, window: w)
        case "list_tmux": return try await listTmux(p)
        case "close_session": return try await closeSession(p, window: w)
        case "get_settings": return ["settings": Store.shared.settings]
        case "set_settings": return try setSettings(p, window: w)
        case "search": return try search(p, window: w)
        case "type_text", "read_output": return try await typing(verb, p, window: w)
        case "load_layout": return try await loadLayout(p, window: w)
        case "save_layout": return try saveLayout(p, window: w)
        case "list_macros": return try listMacros(w)
        case "run_macro": return try await runMacro(p, window: w)
        case "focus_window": return ["slot": .string(w.id), "tabs": .number(Double(w.feature(SessionsWindow.self).tabs.count))]
        default: throw AppError("Unknown action \"\(verb)\"")
        }
    }

    // MARK: verbs

    static func listSessions(_ w: WindowModel) throws -> JSON {
        let s = w.feature(SessionsWindow.self)
        return ["tabs": .array(s.tabs.enumerated().map { i, t in
            let panes: [JSON] = s.panesOf(t.id).enumerated().map { j, id in
                let p = s.pane(id)
                let conn = p?.connId.flatMap { ConnectionManager.shared.connection($0) }
                let local = p?.kind == .local
                // A VNC screen is a view pane here; the original called it "vnc".
                let kind = p.map { $0.kind == .view ? "vnc" : $0.kind.rawValue } ?? "unknown"
                // Where it is, for read_output: { tab, pane }.
                return ["index": .number(Double(j)), "focused": .bool(id == s.activePaneId),
                        "kind": .string(kind),
                        "host": conn.map { .string($0.label) } ?? (local ? "local" : .null),
                        "state": .string(conn?.state.rawValue ?? (local ? "connected" : "idle")),
                        "filesOnly": .bool(p?.filesOnly ?? false)]
            }
            return ["index": .number(Double(i)), "title": .string(t.title), "active": .bool(t.id == s.activeTabId),
                    "panes": .array(panes)]
        })]
    }

    /// Open several at once — the reason this interface exists. Failures are
    /// reported per entry rather than aborting the rest: a set of sessions
    /// where one host is down should still give you the others.
    static func openSessions(_ p: JSON, window w: WindowModel) async throws -> JSON {
        guard let sessions = p["sessions"].array, !sessions.isEmpty else { throw AppError("Give a \"sessions\" array.") }
        let stopOnError = p["stopOnError"].truthy
        var results: [JSON] = []
        for spec in sessions {
            do {
                let opened = try await openOne(spec, window: w)
                results.append(["ok": true, "host": opened["label"]])
            } catch {
                let host = spec["host"].string?.nilIfEmpty ?? "(unnamed)"
                results.append(["ok": false, "host": .string(host), "error": .string(s3Message(error))])
                if stopOnError { break }
            }
        }
        let good = results.filter { $0["ok"].bool == true }.count
        StatusBus.shared.show("Automation opened \(good) of \(results.count) session(s)")
        return ["opened": .number(Double(good)), "failed": .number(Double(results.count - good)), "results": .array(results)]
    }

    /// What tmux has running on a host, so a caller can decide whether to
    /// resume rather than start. Dials the host to ask.
    static func listTmux(_ p: JSON) async throws -> JSON {
        var name = p["host"].stringish?.nilIfEmpty
        var beam = beamFlag(p["beam"])
        if let b = p["beam"].string?.trimmed.nilIfEmpty { name = name ?? b; beam = true }
        guard let raw = name else { throw AppError("Give a \"host\", or a \"beam\" by name.") }
        try await ensureInventory()
        guard let host = try await findHost(raw.trimmed, cluster: p["cluster"].string?.nilIfEmpty, beam: beam) else {
            throw AppError("No host matching \"\(raw)\".")
        }
        /*
         * The same account the app would use, unless one is named.
         *
         * tmux sessions belong to the user that started them, and connecting
         * as the Teleport principal rather than the login the host is actually
         * opened with answers "nothing is running there" about an account
         * nobody uses — while the sessions sit under the other one.
         */
        let login = host.isBeam ? p["login"].string?.nilIfEmpty
            : p["login"].string?.nilIfEmpty ?? AutoHostPrefs.preferredLogin(host)
        let conn = try await ensureConnection(host, login: login)
        let probe = await TmuxService.shared.probe(conn)
        let label = host.name.nilIfEmpty ?? host.alias ?? ""
        if !probe.ok { return ["host": .string(label), "available": false, "reason": JSON(probe.reason)] }
        let sessions = await TmuxService.shared.listSessions(conn)
        return [
            "host": .string(label), "available": true, "version": JSON(probe.version),
            "sessions": .array(sessions.map { s in
                ["name": .string(s.name), "windows": .number(Double(s.windows)), "attached": .bool(s.attached),
                 "created": s.created.map { .string(isoString(ms: $0)) } ?? .null]
            }),
        ]
    }

    /*
     * Asks first, the same way the tab's own × does — but only when a
     * session is actually still running in it. A tab that has already exited
     * closes straight away, and "do not ask again" in that dialog (or Settings)
     * is remembered for this path too.
     */
    static func closeSession(_ p: JSON, window w: WindowModel) async throws -> JSON {
        let s = w.feature(SessionsWindow.self)
        if p["all"].truthy {
            let tabs = s.tabs
            if !(await s.confirmClosing(tabIds: tabs.map(\.id), paneIds: [])) {
                throw AppError("The user declined to close the session(s).")
            }
            for t in tabs { s.closeTab(t.id) }
            return ["closed": .number(Double(tabs.count))]
        }
        let tab: SessionTab?
        if case .number(let n) = p["index"] {
            // Only a whole number that names a tab; anything else is no such tab.
            tab = n.isFinite && n >= 0 && n < Double(s.tabs.count) && n == n.rounded() ? s.tabs[Int(n)] : nil
        } else {
            tab = s.tabs.first { $0.title == p["title"].string }
        }
        guard let tab else { throw AppError("No such session.") }
        let title = tab.title
        if !(await s.confirmClosing(tabIds: [tab.id], paneIds: [])) {
            throw AppError("The user declined to close the session.")
        }
        s.closeTab(tab.id)
        return ["closed": 1, "title": .string(title)]
    }

    static func loadLayout(_ p: JSON, window w: WindowModel) async throws -> JSON {
        let layouts = Store.shared.autoListLayouts()
        let id = p["id"].string?.nilIfEmpty
        let name = p["name"].string
        let layout = id != nil ? layouts.first { $0["id"].string == id } : layouts.first { $0["name"].string == name }
        guard let layout else {
            let have = layouts.compactMap { $0["name"].string }.joined(separator: ", ")
            throw AppError("No layout named \"\(name?.nilIfEmpty ?? id ?? "undefined")\". Have: \(have.isEmpty ? "none" : have)")
        }
        let s = w.feature(SessionsWindow.self)
        // Replaces what is open, exactly as loading it from the menu does.
        for t in s.tabs { s.closeTab(t.id) }
        await s.restoreWorkspace(layout["workspace"])
        return ["loaded": layout["name"], "tabs": .number(Double(layout["workspace"]["tabs"].items.count))]
    }

    static func saveLayout(_ p: JSON, window w: WindowModel) throws -> JSON {
        guard let name = p["name"].stringish?.nilIfEmpty else { throw AppError("Give a \"name\" for the layout.") }
        let ws = w.feature(SessionsWindow.self).captureWorkspace()
        if ws["tabs"].items.isEmpty { throw AppError("Nothing is open to save.") }
        let saved = Store.shared.autoSaveLayout(name: name, workspace: ws)
        return ["saved": saved["name"], "tabs": .number(Double(ws["tabs"].items.count))]
    }

    static func listMacros(_ w: WindowModel) throws -> JSON {
        guard let list = AutomationHooks.listMacros else { throw notYet("Listing macros") }
        return ["macros": .array(list(w).map { m in
            ["name": m["name"], "category": .string(m["category"].string?.nilIfEmpty ?? "Custom"),
             "description": .string(m["description"].string ?? ""), "command": m["command"],
             "builtin": .bool(m["builtin"].truthy), "confirm": .bool(m["confirm"].truthy),
             "interactive": .bool(m["interactive"].truthy),
             "repeatSeconds": .number(m["repeatSeconds"].double ?? 0)]
        })]
    }

    static func runMacro(_ p: JSON, window w: WindowModel) async throws -> JSON {
        guard let list = AutomationHooks.listMacros, let run = AutomationHooks.runMacro else { throw notYet("Running a macro") }
        let macros = list(w)
        let name = p["name"].stringish ?? ""
        guard let macro = macros.first(where: { $0["name"].string == name || ($0["name"].string ?? "").lowercased() == name.lowercased() }) else {
            throw AppError("No macro named \"\(p["name"].stringish ?? "undefined")\". Have: \(macros.compactMap { $0["name"].string }.joined(separator: ", "))")
        }
        guard let pane = w.feature(SessionsWindow.self).activePane, pane.hasTerm else {
            throw AppError("No session is focused to run it in.")
        }
        let before = pane.term?.allText() ?? ""
        try await run(w, macro, p["allPanes"].truthy)
        /*
         * Asked to wait: give the command that long, then hand back what it
         * printed — so running a macro and reading its result is one call. The
         * new text is what came after the screen as it was; if scrollback was
         * trimmed in between, the last lines stand in for it.
         */
        let wait = waitSeconds(p["waitSeconds"])
        if wait == 0 { return ["ran": macro["name"], "command": macro["command"]] }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        let after = pane.term?.allText() ?? ""
        let added = after.hasPrefix(before) ? String(after.dropFirst(before.count)) : lastLines(after, 80)
        return ["ran": macro["name"], "command": macro["command"], "waitedSeconds": .number(wait),
                "output": .string(lastLines(added, 400))]
    }

    /// `Math.max(0, Math.min(60, Number(waitSeconds) || 0))`.
    nonisolated static func waitSeconds(_ j: JSON) -> Double {
        let n: Double
        switch j {
        case .number(let d): n = d
        case .string(let t): n = Double(t.trimmingCharacters(in: .whitespaces)) ?? (t.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : .nan)
        case .bool(let b): n = b ? 1 : 0
        default: n = 0
        }
        return n.isNaN ? 0 : max(0, min(60, n))
    }

    /// The last `n` non-trailing-blank lines of a pane's text.
    nonisolated static func lastLines(_ text: String, _ n: Int) -> String {
        var s = Substring(text)
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return s.components(separatedBy: "\n").suffix(n).joined(separator: "\n")
    }

    /*
     * Change one or more settings — the same patch the Settings dialog's own
     * Save button sends, so anything it can set, this can set. A cursor
     * setting also applies live to every open terminal, the same as Save
     * does; other settings take effect the way they always have, the next
     * time they are read. KubeLife's group in the sidebar follows at once too.
     */
    static func setSettings(_ p: JSON, window w: WindowModel) throws -> JSON {
        guard let patch = p["patch"].object else {
            throw AppError("Give a \"patch\" object of settings to change, e.g. { cursorStyle: \"block\" }.")
        }
        let before = Store.shared.settings
        SettingsDialog.apply(patch)
        let after = Store.shared.settings
        for hook in MiscHooks.settingsSaved { hook(before, after) }
        return ["settings": after]
    }

    /*
     * The search box at the top of the window, for an agent: everything in
     * ServerLife whose name or details match, grouped by kind. It finds; it
     * does not open — each kind says which tool takes it from there.
     */
    static func search(_ p: JSON, window w: WindowModel) throws -> JSON {
        let q = (p["query"].stringish ?? "").trimmed
        if q.isEmpty { throw AppError("Give a \"query\" to search for.") }
        guard Actions.shared.isRegistered("search-data") else { throw notYet("Searching") }
        var limit = 8
        if case .number(let d) = p["limit"], d.isFinite, d != 0 { limit = Int(d) }
        var args: [String: Any] = ["query": q, "limit": limit]
        if let k = p["kinds"].array { args["kinds"] = k.compactMap(\.string) }
        var out: JSON = .null
        args["reply"] = { (r: Any?) in out = (r as? JSON) ?? .null } as (Any?) -> Void
        Actions.shared.perform("search-data", window: w, args: args)
        return out
    }

    /// `type_text` and `read_output`, answered by the AI feature (aiwaiting.js
    /// shares its typing dialog with automation.js in the original).
    static func typing(_ verb: String, _ p: JSON, window w: WindowModel) async throws -> JSON {
        guard Actions.shared.isRegistered("ai-type-request") else {
            throw notYet(verb == "read_output" ? "Reading a session" : "Typing into a session")
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            var done = false
            let reply: (Result<JSON, Error>) -> Void = { r in
                if done { return }
                done = true
                c.resume(with: r)
            }
            Actions.shared.perform("ai-type-request", window: w, args: ["verb": verb, "params": p, "reply": reply])
        }
    }

    // MARK: opening one

    /// Resolve one session spec and open it. A host is named the way a person
    /// would name it — the node's hostname, an ssh_config alias, a saved
    /// profile's name, or "local" — and matched against the inventory rather
    /// than requiring an internal id.
    static func openOne(_ specIn: JSON, window w: WindowModel) async throws -> JSON {
        var spec = specIn
        // `beam` is a flag, or — as sync_apply takes it — the beam's name.
        if let beamName = spec["beam"].string?.trimmed.nilIfEmpty {
            if !spec["host"].truthy { spec["host"] = .string(beamName) }
            spec["beam"] = true
        }
        let name = (spec["host"].truthy ? spec["host"].stringish : spec["name"].stringish)?.trimmed ?? ""
        if name.isEmpty { throw AppError("Each session needs a \"host\", or a \"beam\" by name.") }
        let split = spec["split"].truthy ? spec["split"].stringish : nil
        let cluster = spec["cluster"].string?.nilIfEmpty

        let sw = w.feature(SessionsWindow.self)
        if name == "local" || name == "local shell" {
            if let split { _ = await sw.splitActivePane(split == "down" ? .col : .row, SplitOptions(local: true)) }
            else { sw.openLocalShell() }
            return ["label": "local shell", "transport": "local"]
        }

        // A kube cluster dials nothing (openHost below is terminal-only) —
        // checked ahead of the SSH/beam/profile resolution, the same way the
        // local-shell case above is.
        if let kube = try await kubeClusterNamed(name, cluster: cluster) {
            if split != nil {
                throw AppError("A kube cluster browser opens in a tab of its own, not a split, through this interface.")
            }
            if let c = kube.context {
                let label = ControlKube.nameOf(c)
                guard Actions.shared.isRegistered("kube-browser") else { throw notYet("Opening a kube cluster browser") }
                Actions.shared.perform("kube-browser", window: w,
                                       args: ["context": c, "contextName": c["contextName"].string ?? "", "title": label])
                return ["label": .string(label), "transport": "kube"]
            }
            // kubepanel.js `connectAvailableCluster`: `tsh kube login` it, then re-read the contexts.
            let r = await Kube.loginKubeCluster(proxy: kube.profile.proxy, home: kube.profile.homeDir.nilIfEmpty, cluster: kube.name)
            if !r["ok"].truthy { throw AppError(r["error"].string?.nilIfEmpty ?? "Could not log in to \(kube.name)") }
            KubeContexts.shared.reload()
            return ["label": .string(kube.name), "transport": "kube"]
        }

        try await ensureInventory()
        guard let host = try await findHost(name, cluster: cluster, beam: beamFlag(spec["beam"])) else {
            throw AppError("No host matching \"\(name)\". Try list_hosts or list_beams to see what is available.")
        }
        let label = host.name.nilIfEmpty ?? host.alias ?? name

        // Same reasoning as list_tmux: automation opens a host as the app would.
        // A beam is reached through `tsh beams`, which takes no login — the same
        // as opening one from the Beams list.
        let login = host.isBeam ? spec["login"].string?.nilIfEmpty
            : spec["login"].string?.nilIfEmpty ?? AutoHostPrefs.preferredLogin(host)
        /*
         * An sftp profile defaults to the file browser, same as double-clicking
         * it — many dedicated SFTP accounts have no shell at all (`ForceCommand
         * internal-sftp`), so a terminal on one does not just look wrong, it
         * does not work. The caller can still ask for a terminal with
         * `filesOnly: false`.
         */
        let profileType = host.extra["profileType"]?.string
        let profileId = host.extra["profileId"]?.string
        let filesOnly = spec.object?["filesOnly"] == nil ? profileType == "sftp" : spec["filesOnly"].truthy
        var args: [String: Any] = ["filesOnly": filesOnly]
        if let login { args["login"] = login }
        if let profileId { args["profileId"] = profileId }

        /*
         * In tmux, if asked — or if this host is set to open that way.
         *
         * Reading the preference matters more here than the flag does: a host
         * the user has told the app to always open in tmux should not become
         * an ordinary session because something else opened it. Automation
         * that opens a set of hosts to work on is exactly when losing the
         * session to a dropped connection costs the most.
         */
        // Only a missing `tmux` defers to the host's setting; null is "no".
        let wantsTmux = spec.object?["tmux"] == nil ? AutoHostPrefs.opensInTmux(host) : spec["tmux"].truthy
        if wantsTmux && !filesOnly {
            if ConnPrefs.isMfaHost(host) { throw AppError("\(label) asks for MFA per session, so it cannot run in tmux.") }
            if split != nil { throw AppError("A tmux session opens in a tab of its own, not a split.") }
            let session = spec["tmuxSession"].string?.nilIfEmpty ?? AutoHostPrefs.tmuxName(host)
            guard Actions.shared.isRegistered("tmux-open") else { throw AppError("Could not open tmux on \(label).") }
            args["session"] = session
            args["tmuxSession"] = session
            Actions.shared.perform("tmux-open", window: w, host: host, args: args)
            return ["label": .string(label), "transport": "tmux", "session": .string(session)]
        }
        if let split {
            /*
             * "Split the tab I just opened" cannot lean on whatever happens to
             * be focused right now — a caller stringing tool calls together has
             * no way to be sure that is still true, and no handle on a tab at
             * all otherwise. `tab`, the same index `list_sessions` reports,
             * lets it say exactly which one rather than hope the focus held.
             */
            if let t = spec.object?["tab"], t != .null {
                guard case .number(let d) = t, d == d.rounded(), d >= 0, d < Double(sw.tabs.count) else {
                    throw AppError("No tab \(t.stringish ?? "undefined").")
                }
                sw.setActiveTab(sw.tabs[Int(d)].id)
            }
            // (SplitOptions carries no profile id, so a split is not tagged
            // with the saved profile the way upstream's is.)
            let o = SplitOptions(host: host, login: login, filesOnly: filesOnly)
            guard await sw.splitActivePane(split == "down" ? .col : .row, o) != nil else {
                throw AppError("Nothing is focused to split.")
            }
            return ["label": .string(label)]
        }
        /*
         * `splitActivePane`, just above, already skips straight to the `tsh`
         * transport for a host known to need per-session MFA before ever
         * calling `openHost` — this plain path has to do the same, or opening
         * MFA-flagged hosts through this tool tries the shared connection and
         * fails every time.
         */
        var o = OpenHostOptions()
        o.login = login
        o.filesOnly = filesOnly
        o.profileId = profileId
        if host.isTeleport && ConnPrefs.isMfaHost(host) { o.transport = "tsh" }
        guard let pane = await sw.openHost(host, o) else { throw AppError("Could not open \(label).") }
        let conn = pane.connId.flatMap { ConnectionManager.shared.connection($0) }
        return ["label": .string(conn?.label ?? label), "transport": JSON(conn?.transportKind)]
    }

    /// `beam` as findHost takes it: true, false, or unset (anything else).
    nonisolated static func beamFlag(_ j: JSON) -> Bool? {
        if case .bool(let b) = j { return b }
        return nil
    }

    // MARK: kube clusters by name

    struct KubeTarget { let name: String; let profile: TeleportProfile; let context: JSON? }

    /**
     * A kube cluster, named like a host — kubepanel.js `kubeHostsForProfile`
     * (logged-in contexts the cluster still offers, then available ones not
     * yet logged in), searched across every Teleport profile. Exact match
     * first, then one unambiguous partial match. Requestable-only clusters
     * are skipped: opening one needs an access request first, a mutating
     * action this interface does not offer.
     */
    static func kubeClusterNamed(_ name: String, cluster: String?) async throws -> KubeTarget? {
        if !Store.shared.kubeSettingEnabled { return nil }
        let profiles = Inventory.shared.profiles.filter { cluster == nil || $0.cluster == cluster }
        if profiles.isEmpty { return nil }
        let r = await Kube.listContexts(extraPaths: Store.shared.kubeSettingConfigPaths)
        let all = r["ok"].truthy ? r["contexts"].items : []
        var candidates: [KubeTarget] = []
        for p in profiles where !p.expired {
            let avail = await Kube.listKubeClusters(proxy: p.proxy, home: p.homeDir.nilIfEmpty)
            let offered: Set<String>? = avail["ok"].truthy ? Set(avail["clusters"].items.compactMap { $0["name"].string }) : nil
            let ctxs = ControlKube.contexts(all, cluster: p.cluster, proxy: p.proxy)
            let mine = offered.map { o in ctxs.filter { o.contains(ControlKube.nameOf($0)) } } ?? ctxs
            let mineNames = Set(mine.map(ControlKube.nameOf))
            candidates += mine.map { KubeTarget(name: ControlKube.nameOf($0), profile: p, context: $0) }
            for cl in avail["clusters"].items {
                guard let n = cl["name"].string, !mineNames.contains(n) else { continue }
                candidates.append(KubeTarget(name: n, profile: p, context: nil))
            }
        }
        return try pickKube(name, candidates.map(\.name)).map { candidates[$0] }
    }

    /// Exact first, then one unambiguous partial match: the index into `names`.
    nonisolated static func pickKube(_ name: String, _ names: [String]) throws -> Int? {
        if let i = names.firstIndex(of: name) { return i }
        let lower = name.lowercased()
        let partial = names.indices.filter { names[$0].lowercased().contains(lower) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 {
            throw AppError("\"\(name)\" matches \(partial.count) kube clusters: " + partial.map { names[$0] }.joined(separator: ", "))
        }
        return nil
    }

    // MARK: finding a host

    /// Does a beam's proxy belong to the cluster a caller named?
    static func beamInCluster(_ b: Beam, _ cluster: String?) -> Bool {
        guard let cluster else { return true }
        if b.proxy == cluster || b.proxy.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression) == cluster { return true }
        return Inventory.shared.profiles.first { $0.proxy == b.proxy }?.cluster == cluster
    }

    /**
     * Beams named exactly: by alias, by UUID, or by the `beam-<uuid>` node it
     * registers as.
     *
     * Exact only, never partial. A beam's alias is made up by the service and
     * can sit next to an ordinary server with a similar name in the same
     * cluster, and the two are reached in different ways — a beam through
     * `tsh beams`, a node through ssh — so a near miss would open the wrong
     * kind of session on the wrong machine.
     */
    static func findBeams(_ name: String, _ cluster: String?) -> [Beam] {
        var out: [Beam] = []
        for list in Inventory.shared.beamsByProxy.values {
            for b in list where beamInCluster(b, cluster) {
                if b.id == name || (!b.uuid.isEmpty && (b.uuid == name || "beam-" + b.uuid == name)) { out.append(b) }
            }
        }
        return out
    }

    /**
     * Match a name against beams, Teleport nodes, ssh_config aliases and saved
     * profiles.
     *
     * `beam` narrows it: true for beams only, false for anything but. Left
     * unset, a name that is exactly both a beam and another host is refused
     * rather than guessed, and the error says how to choose.
     */
    static func findHost(_ name: String, cluster: String?, beam: Bool? = nil) async throws -> Host? {
        if beam != false {
            // Load the beams once if nothing has asked for them yet.
            if Inventory.shared.beamsByProxy.isEmpty { await Inventory.shared.refreshBeams() }
            let beams = findBeams(name, cluster)
            if beams.count > 1 {
                throw AppError("\"\(name)\" matches \(beams.count) beams: "
                    + beams.map { "\($0.id) (\($0.proxy))" }.joined(separator: ", ") + ". Give a \"cluster\".")
            }
            if let b = beams.first {
                // A beam's own node name is that beam, not a namesake.
                if beam == true || name == "beam-" + b.uuid { return BeamsUI.host(b) }
                if let other = findExact(name, cluster: cluster) {
                    throw AppError("\"\(name)\" is both a beam (\(b.proxy)) and a \(other.type) host "
                        + "(\(other.cluster?.nilIfEmpty ?? other.alias?.nilIfEmpty ?? other.name)). Say \"beam\": true for the beam, or false for the other.")
                }
                return BeamsUI.host(b)
            }
            if beam == true { throw AppError("No beam called \"\(name)\". Try list_beams to see what is available.") }
        }
        if let exact = findExact(name, cluster: cluster) { return exact }
        return try findPartial(name.lowercased(), cluster: cluster)
    }

    /// A Teleport node, ssh_config alias or saved profile with exactly this name.
    static func findExact(_ name: String, cluster: String?) -> Host? {
        let inv = Inventory.shared
        for n in inv.allNodes where cluster == nil || n.cluster == cluster {
            if n.name == name || n.hostname == name || n.uuid == name { return n }
        }
        if let ssh = inv.sshHosts.first(where: { $0.alias == name }) { return ssh }

        guard let profile = Store.shared.autoListProfiles().first(where: { $0["name"].string == name }) else { return nil }
        if profile["type"].string == "teleport" {
            let node = profile["node"].string ?? ""
            var h = Host(type: Host.teleport, id: "tsh:\(profile["cluster"].string ?? ""):\(node)", name: node)
            h.hostname = node
            h.cluster = profile["cluster"].string
            h.proxy = profile["proxy"].string
            h.home = profile["home"].string?.nilIfEmpty
            return h
        }
        /*
         * A profile with its own connection details (any ssh profile that
         * named a hostname rather than only an alias, and every sftp profile —
         * those are always a standalone direct host) needs no ssh_config
         * entry, same as `launchProfile` building a host from one.
         */
        func str(_ k: String) -> String? { profile[k].truthy ? profile[k].stringish : nil }
        if profile["direct"].truthy {
            var h = Host(type: Host.ssh, id: "app:" + (str("id") ?? ""), name: str("name") ?? "")
            h.alias = str("name")
            h.direct = profile["direct"].decode(DirectSpec.self)
            h.user = str("user"); h.hostname = str("hostname"); h.port = profile["port"].int
            // Read back by openOne to default filesOnly and to tag the
            // connection so it can be found again (Hosts pane "Saved").
            h.extra["profileType"] = profile["type"]
            h.extra["profileId"] = profile["id"]
            return h
        }
        let alias = profile["alias"].string ?? ""
        var h = Host(type: Host.ssh, id: "ssh:" + alias, name: profile["name"].string ?? alias)
        h.alias = alias
        h.configFile = profile["configFile"].string?.nilIfEmpty
        return h
    }

    /// Nothing exact: one unambiguous partial match is still a clear intent.
    ///
    /// Beams' `beam-<uuid>` nodes are left out — reached as plain nodes they
    /// fail, and a beam is only ever opened when it is named exactly.
    static func findPartial(_ lower: String, cluster: String?) throws -> Host? {
        let inv = Inventory.shared
        let beamNodes = inv.beamNodeNames()
        var partial: [Host] = inv.allNodes.filter { n in
            (cluster == nil || n.cluster == cluster) && !beamNodes.contains(n.name) && !isBeamNodeName(n.name)
                && n.name.lowercased().contains(lower)
        }
        partial += inv.sshHosts.filter { ($0.alias ?? "").lowercased().contains(lower) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 {
            throw AppError("\"\(lower)\" matches \(partial.count) hosts: "
                + partial.prefix(8).map { $0.name.nilIfEmpty ?? $0.alias ?? "" }.joined(separator: ", "))
        }
        return nil
    }

    /// `/^beam-[0-9a-f-]{36}$/`
    nonisolated static func isBeamNodeName(_ n: String) -> Bool {
        n.range(of: "^beam-[0-9a-f-]{36}$", options: .regularExpression) != nil
    }

    /// The inventory, read once if nothing has been read yet.
    static func ensureInventory() async throws {
        let inv = Inventory.shared
        if inv.allNodes.isEmpty && inv.sshHosts.isEmpty { await inv.refresh() }
    }

    /// `ensureConnection`: an open connection to this host as this login, or a new one.
    static func ensureConnection(_ host: Host, login: String?) async throws -> Connection {
        let mgr = ConnectionManager.shared
        let c = try await mgr.create(host: host, options: ConnectOptions(login: login, reuse: true))
        if c.state != .connected { try await mgr.connect(c.id) }
        return c
    }

    static func notYet(_ what: String) -> AppError {
        AppError("\(what) is not available to automation in this build yet.")
    }

    nonisolated static func isoString(ms: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

/// The per-host preferences the sidebar resolves (sidebar.js
/// `preferredLogin`, `loginOptionsFor`, `tmuxState`, `tmuxNameFor`), read
/// straight from settings with the same keys.
@MainActor
enum AutoHostPrefs {
    static func loginOptions(_ host: Host) -> [String] {
        if host.isTeleport {
            // The certificate that carries the logins belongs to a profile in
            // one tsh home; with the same cluster in two homes those sets can differ.
            let profiles = Inventory.shared.profiles
            let p = profiles.first { $0.cluster == host.cluster && ($0.home ?? "") == (host.home ?? "") }
                ?? profiles.first { $0.cluster == host.cluster }
            return p?.logins ?? []
        }
        return host.user.map { [$0] } ?? []
    }

    /// Said deliberately for this host wins; then whatever last worked (if
    /// the cluster still grants it); then the first login the cluster grants.
    static func preferredLogin(_ host: Host) -> String? {
        let s = Store.shared.settings
        if let explicit = s["hostUsers"][host.prefKey].string?.nilIfEmpty { return explicit }
        let options = loginOptions(host)
        if let remembered = s["hostLogins"][host.id].string?.nilIfEmpty, options.isEmpty || options.contains(remembered) {
            return remembered
        }
        return options.first
    }

    /// `tmuxState(host).on`: never on an MFA host; else host, cluster, default.
    static func opensInTmux(_ host: Host) -> Bool {
        if ConnPrefs.isMfaHost(host) { return false }
        let s = Store.shared.settings
        let hk = host.prefKey
        if !hk.isEmpty, let v = s["tmuxHosts"].object?[hk] { return v.truthy }
        let ck = host.clusterPrefKey
        if !ck.isEmpty, let v = s["tmuxClusters"].object?[ck] { return v.truthy }
        return s["tmuxDefault"].bool == true
    }

    static func tmuxName(_ host: Host) -> String {
        let s = Store.shared.settings
        let hk = host.prefKey
        if !hk.isEmpty, let n = s["tmuxSessionNames"][hk].string?.nilIfEmpty { return n }
        return s["tmuxSessionName"].string?.nilIfEmpty ?? "serverlife"
    }
}
