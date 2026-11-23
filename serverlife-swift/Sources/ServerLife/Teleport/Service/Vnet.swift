import Foundation

/// Teleport VNet, started and stopped from the app (vnet.js, main.js
/// `vnet:start/stop/status`).
///
/// `tsh vnet` is a long-running foreground process: while it runs, TCP apps
/// (and SSH, where the cluster enables it) in the logged-in clusters answer by
/// name, with no `tsh proxy` per app. It serves every cluster logged in from
/// its tsh home, not one cluster — so it is pointed at a home holding just the
/// one cluster it was started for (`scopedHome`).
///
/// Stopping is Ctrl-C (SIGINT), which is how tsh is meant to be stopped: it
/// takes down the virtual interface and the DNS configuration it added. Only if
/// it is still there after a few seconds is it terminated outright.
@MainActor @Observable
final class VnetManager {
    static let shared = VnetManager()

    struct View: Equatable, Sendable {
        var cluster: String
        var home: String?
        var proxy: String?
        /// starting | running | stopping | stopped | error
        var state: String
        var startedAt: Double
        var error: String?
        var log: [String]

        var json: JSON {
            ["cluster": .string(cluster), "home": JSON(home), "proxy": JSON(proxy), "state": .string(state),
             "startedAt": .number(startedAt), "error": JSON(error), "log": JSON(log)]
        }
        var active: Bool { ["starting", "running", "stopping"].contains(state) }
    }

    private final class Record {
        var home: String?
        var proxy: String
        var state = "starting"
        var startedAt = nowMs()
        var error: String?
        var log: [String] = []
        var child: RunningProcess?
        var stopping = false
        var scopedHome: String?
        var pending = ""
        init(home: String?, proxy: String) { self.home = home; self.proxy = proxy }
    }

    /// Lines of output kept for the log view.
    static let tail = 60
    /// `READY`.
    static let ready = #"\b(vnet (is )?(running|ready|started)|ready|listening)\b"#
    /// VNet's own files, shared with the real home.
    static let sharedFiles = ["known_hosts", "id_vnet", "id_vnet.pub", "vnet_known_hosts", "config", "bin"]

    @ObservationIgnored private var byHome: [String: Record] = [:]
    /// Bumped on every change; observers read `status` / `view(for:)`.
    private(set) var generation = 0
    /// Where scoped homes go (tests point it elsewhere).
    @ObservationIgnored var scopeRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("serverlife-vnet")
    /// `vnet:state`, for anyone who wants each change as it happens.
    @ObservationIgnored var onState: [(View) -> Void] = []

    // MARK: - Pure helpers

    /// `profileName`: the profile name tsh files a proxy under — its host, without the port.
    nonisolated static func profileName(_ proxy: String?) -> String {
        (proxy ?? "").trimmed
            .replacingOccurrences(of: #"^[a-z][a-z0-9+.-]*://"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
    }

    /// `scopedHome`: a tsh home holding one cluster and nothing else.
    ///
    /// `tsh vnet` serves every profile in its home whatever --proxy says, and
    /// touching an expired one makes it log in again — it opened browser
    /// logins for clusters nobody asked about. Pointed at this home instead,
    /// it can see only the cluster it was started for. The profile and its
    /// keys are links to the real ones, so a certificate renewed anywhere is
    /// the one VNet uses, and VNet's own files are shared the same way.
    /// nil when the real home has no profile for the proxy.
    nonisolated static func scopedHome(_ realHome: String?, proxy: String?, root: String) throws -> String? {
        let name = profileName(proxy)
        let fm = FileManager.default
        var real = realHome?.nilIfEmpty ?? ProcessInfo.processInfo.environment["TELEPORT_HOME"]?.nilIfEmpty
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".tsh")
        real = (real as NSString).expandingTildeInPath
        func j(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }
        if name.isEmpty || !fm.fileExists(atPath: j(real, "\(name).yaml")) { return nil }
        let dir = j(root, name)
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: j(dir, "keys"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        func link(_ from: String, _ to: String) throws {
            if fm.fileExists(atPath: from) { try fm.createSymbolicLink(atPath: to, withDestinationPath: from) }
        }
        try link(j(real, "\(name).yaml"), j(dir, "\(name).yaml"))
        try link(j(j(real, "keys"), name), j(j(dir, "keys"), name))
        for f in sharedFiles { try link(j(real, f), j(dir, f)) }
        guard fm.createFile(atPath: j(dir, "current-profile"), contents: Data((name + "\n").utf8),
                            attributes: [.posixPermissions: 0o640]) else {
            throw AppError("could not write \(j(dir, "current-profile"))")
        }
        return dir
    }

    // MARK: - Reading

    private func view(_ r: Record) -> View {
        View(cluster: Self.profileName(r.proxy), home: r.home, proxy: r.proxy, state: r.state,
             startedAt: r.startedAt, error: r.error, log: Array(r.log.suffix(Self.tail)))
    }

    /// `vnet:status`.
    var status: [View] { _ = generation; return byHome.values.map(view).sorted { $0.cluster < $1.cluster } }

    /// The VNet for a cluster's proxy, if one was started.
    func view(for proxy: String?) -> View? {
        _ = generation
        return byHome[Self.profileName(proxy)].map(view)
    }

    func isActive(_ proxy: String?) -> Bool { view(for: proxy)?.active ?? false }

    private func emit(_ r: Record) {
        generation &+= 1
        let v = view(r)
        onState.forEach { $0(v) }
    }

    // MARK: - Start / stop

    /// `vnet:start`. One VNet at a time, for one cluster: a second `tsh vnet`
    /// would fight the first over the same virtual interface and resolver, so
    /// starting while another is up is refused with the name of the one that is.
    @discardableResult
    func start(proxy: String?, home: String? = nil) throws -> View {
        guard let proxy = proxy?.nilIfEmpty else { throw AppError("No cluster to start VNet for") }
        let home = home?.nilIfEmpty ?? Tools.home(forProxy: proxy)
        let k = Self.profileName(proxy)
        let existing = byHome[k]
        if let existing, ["starting", "running", "stopping"].contains(existing.state) { return view(existing) }
        if let other = byHome.values.first(where: { $0 !== existing && ["starting", "running", "stopping"].contains($0.state) }) {
            throw AppError("VNet is already running for \(Self.profileName(other.proxy)) \u{2014} stop it there first")
        }
        let rec = Record(home: home, proxy: proxy)
        byHome[k] = rec
        var scoped: String?
        do { scoped = try Self.scopedHome(home, proxy: proxy, root: scopeRoot) } catch {
            rec.log.append("Could not prepare a tsh home for this cluster alone: \(error.localizedDescription)")
        }
        guard let scoped else {
            rec.state = "error"
            rec.error = "No tsh profile for \(Self.profileName(proxy)) in \(home ?? "the tsh home") \u{2014} log in to it first"
            emit(rec)
            return view(rec)
        }
        rec.scopedHome = scoped
        let args = ["--proxy=" + proxy, "vnet"]
        let onData: @Sendable (Data) -> Void = { [weak self] d in
            let text = String(decoding: d, as: UTF8.self)
            Task { @MainActor in self?.onText(rec, text) }
        }
        do {
            let child = try RunningProcess(Tools.tsh, args, env: TshEnv.overrides(home: scoped, proxy: proxy),
                                           onStdout: onData, onStderr: onData)
            rec.child = child
            child.onExit { [weak self, weak child] code in
                let signalled = child?.process.terminationReason == .uncaughtSignal
                Task { @MainActor in self?.exited(rec, code: code, signalled: signalled) }
            }
        } catch {
            rec.state = "error"
            rec.error = error.localizedDescription
            emit(rec)
            return view(rec)
        }
        // tsh does not promise to print anything when it is up, so a process
        // that is still alive a few seconds in — past authentication, past the
        // admin prompt it may raise — is taken as running.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if rec.state == "starting", rec.child?.isRunning == true {
                rec.state = "running"
                self?.emit(rec)
            }
        }
        emit(rec)
        return view(rec)
    }

    private func onText(_ rec: Record, _ text: String) {
        let lines = (rec.pending + text).components(separatedBy: "\n")
        rec.pending = ""
        for raw in lines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.trimmed.isEmpty { continue }
            rec.log.append(line)
            if rec.log.count > Self.tail * 2 { rec.log.removeFirst(rec.log.count - Self.tail) }
            if rec.state == "starting", TPText.test(Self.ready, line, .caseInsensitive) { rec.state = "running" }
        }
        emit(rec)
    }

    private func exited(_ rec: Record, code: Int32, signalled: Bool) {
        rec.child = nil
        if rec.stopping || code == 0 || (signalled && code == SIGINT) {
            rec.state = "stopped"
        } else {
            rec.state = "error"
            let last = rec.log.last { TPText.test("error|fail|denied|not supported|requires", $0, .caseInsensitive) }
                ?? rec.log.last
            rec.error = last ?? "tsh vnet exited (\(signalled ? "signal \(code)" : String(code)))"
        }
        emit(rec)
    }

    /// `vnet:stop`.
    @discardableResult
    func stop(proxy: String?) -> View? {
        guard let rec = byHome[Self.profileName(proxy)] else { return nil }
        guard let child = rec.child else { return view(rec) }
        rec.stopping = true
        rec.state = "stopping"
        emit(rec)
        child.signal(SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak child] in
            if child?.isRunning == true { child?.signal(SIGTERM) }
        }
        return view(rec)
    }

    /// On quit: VNet changed this machine's network setup; Ctrl-C lets tsh undo it.
    func stopAll() {
        for rec in byHome.values {
            guard let child = rec.child else { continue }
            rec.stopping = true
            child.signal(SIGINT)
        }
    }
}
