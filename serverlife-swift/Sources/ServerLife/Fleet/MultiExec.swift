import Foundation
import Observation

/// An earlier, failed try of one host in a run with retries.
struct MultiExecTry: Equatable {
    var status: String
    var exitCode: Int32?
    var durationMs: Double?
    var error: String
}

/// One host's part of a multi-exec run (`results` in multiexec.js).
struct MultiExecResult: Identifiable, Equatable {
    var connId: String
    var label: String
    /// pending | running | prompting | retrying | done | error | timeout | cancelled
    var status = "pending"
    var exitCode: Int32?
    var stdout = ""
    var stderr = ""
    var startedAt: Double?
    var endedAt: Double?
    var durationMs: Double?
    /// Which stage of a staged run it went in (1-based), nil otherwise.
    var stage: Int?
    var attempt = 0
    var attempts = 1
    /// Earlier tries, when retries are on.
    var tries: [MultiExecTry] = []
    var retryAt: Double?
    /// Set while status is "prompting" — see `runInteractive`.
    var promptText: String?
    var id: String { connId }
}

/// A staged run's plan and where it is (`view().staged`).
struct MultiExecStaged: Equatable {
    struct Paused: Equatable {
        /// "review" or "failed"
        var reason: String
        var failed: Int
        var ok: Int
    }
    var sizes: [Int]
    var index: Int
    var pause: Bool
    var stopOnFail: Bool
    var paused: Paused?
}

/// `run.view()`: what the panel draws and what is saved as results.
struct MultiExecView: Identifiable, Equatable {
    var id: String
    var command: String
    var startedAt: Double
    var endedAt: Double?
    var running: Bool { endedAt == nil }
    var retries = 0
    var retryDelay: Double = 10
    var staged: MultiExecStaged?
    var results: [MultiExecResult]
}

/// What a password, passphrase, MFA or host-key prompt looks like on a pty
/// (connections.js `PROMPT_RE`).
let mxPromptRegex = try! NSRegularExpression(
    pattern: #"(password:|passphrase for|passcode|verification code|otp|tap any security key|touch your|enter your |2fa|yubikey|\(yes/no|press any key)"#,
    options: [.caseInsensitive])

/**
 * The stages of a staged run: `first` hosts on their own — the canary — then
 * batches of `batch` until every host has had its turn. Sizes only; which
 * hosts go in each is the order they were given in.
 */
func mxPlanStages(_ n: Int, first: Int = 1, batch: Int = 5) -> [Int] {
    var out: [Int] = []
    if n <= 0 { return out }
    let f = max(1, min(n, first == 0 ? 1 : first))
    let b = max(1, batch == 0 ? 5 : batch)
    out.append(f)
    var left = n - f
    while left > 0 { out.append(min(b, left)); left -= b }
    return out
}

/// Multi-exec: run one command across many hosts at once (multiexec.js and
/// main.js `multiexec:*`).
///
/// Each host runs over its own ControlMaster, so a command fans out without
/// re-authenticating anywhere. Results stream back per host as they arrive
/// rather than all at the end, and one slow or dead host never blocks the rest.
@MainActor
@Observable
final class MultiExecService {
    static let shared = MultiExecService()

    struct Stages: Equatable {
        var first = 1
        var batch = 5
        var pause = true
        var stopOnFail = true
    }

    struct Options {
        var concurrency = 8
        /// Milliseconds.
        var timeout: Double = 120_000
        var stopOnError = false
        /*
         * Retries: a host that fails is tried again, up to `retries` more
         * times, `retryDelay` seconds apart — for the blip, the lock held a
         * moment too long, the service still coming up. Only its last try
         * counts: a stage, "stop on error" and the totals all see how it ended.
         */
        var retries = 0
        /// Seconds.
        var retryDelay: Double = 10
        /*
         * Staged: run on a few hosts first and look before going wider.
         * Between stages the run waits for a decision — the next stage, the
         * rest at once, or stop — and a stage with a failure stops it there
         * unless told to go on. nil for an ordinary run, which goes
         * everywhere at once.
         */
        var stages: Stages?
    }

    /// Every run this session, newest first (`state.multiRuns`).
    private(set) var runs: [MultiExecView] = []
    @ObservationIgnored private var live: [String: MXRunState] = [:]
    @ObservationIgnored private var seq = 0
    /// Called with the final view when a run finishes (`multiexec:done`).
    @ObservationIgnored var onDone: [(MultiExecView) -> Void] = []

    /// Above this much output a host's stream keeps only its tail.
    nonisolated static let outputCap = 400_000

    func view(_ id: String) -> MultiExecView? { runs.first { $0.id == id } }

    /// Changed in place: copying a view out and back would copy every
    /// host's output with it.
    private func update(_ id: String, _ body: (inout MultiExecView) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        body(&runs[i])
    }

    /// Output read on the pipes' threads (and the ptys'), handed to the view
    /// in batches (every 100 ms) rather than chunk by chunk, so a chatty
    /// fan-out does not redraw the panel thousands of times a second.
    @ObservationIgnored private let pending = MXOutputBuffer()
    @ObservationIgnored private let flusher = Repeater()

    private func flushOutput() {
        let batch = pending.drain()
        if batch.isEmpty {
            if live.isEmpty { flusher.stop() }
            return
        }
        for b in batch {
            updateResult(b.runId, b.connId) { r in
                if !b.out.isEmpty { r.stdout += b.out; r.stdout = MultiExecService.tail(r.stdout) }
                if !b.err.isEmpty { r.stderr += b.err; r.stderr = MultiExecService.tail(r.stderr) }
            }
        }
    }

    private func startFlusher() {
        if !flusher.isRunning { flusher.start(every: 0.1) { [weak self] in self?.flushOutput() } }
    }

    /// The last `outputCap` bytes of a stream, starting on a character.
    nonisolated static func tail(_ s: String, cap: Int = outputCap) -> String {
        let u = s.utf8
        guard u.count > cap else { return s }
        var start = u.index(u.endIndex, offsetBy: -cap)
        while start < u.endIndex, (u[start] & 0xC0) == 0x80 { start = u.index(after: start) }
        return String(s[start...])
    }

    private func updateResult(_ runId: String, _ connId: String, _ body: (inout MultiExecResult) -> Void) {
        update(runId) { v in
            if let j = v.results.firstIndex(where: { $0.connId == connId }) { body(&v.results[j]) }
        }
    }

    private func result(_ runId: String, _ connId: String) -> MultiExecResult? {
        view(runId)?.results.first { $0.connId == connId }
    }

    /// `multiexec:run`: `connIds` are already-created connections. Answers as
    /// soon as the run is under way.
    @discardableResult
    func run(_ connIds: [String], command: String, options: Options = Options()) async -> MultiExecView {
        let cm = ConnectionManager.shared
        let conns = connIds.compactMap { cm.connection($0) }
        // Ensure each master is up before fanning out; connecting in parallel
        // is fine because each connection has its own control socket.
        await withTaskGroup(of: Void.self) { g in
            for c in conns { g.addTask { @MainActor in try? await c.connect() } }
        }
        seq += 1
        let runId = "run\(seq)"
        let retries = max(0, min(10, options.retries))
        let retryDelay = max(0, min(3600, options.retryDelay.isFinite ? options.retryDelay : 10))
        var results: [MultiExecResult] = conns.map {
            MultiExecResult(connId: $0.id, label: $0.label, attempts: 1 + retries)
        }
        var targets = conns
        // With retries, a host that did not connect is tried again like any
        // other failure; without, it is reported now and left out.
        if retries == 0 {
            targets = []
            for (i, c) in conns.enumerated() {
                if c.state == .connected { targets.append(c); continue }
                results[i].status = "error"
                results[i].stderr = c.error ?? "not connected"
                results[i].endedAt = nowMs()
            }
        }
        let staged = options.stages.map {
            MultiExecStaged(sizes: [], index: 0, pause: $0.pause, stopOnFail: $0.stopOnFail, paused: nil)
        }
        let view = MultiExecView(id: runId, command: command, startedAt: nowMs(), endedAt: nil,
                                 retries: retries, retryDelay: retryDelay, staged: staged, results: results)
        runs.insert(view, at: 0)
        let st = MXRunState(id: runId, command: command, options: options, retries: retries, retryDelay: retryDelay)
        live[runId] = st
        startFlusher()
        Task { @MainActor in await self.start(st, targets) }
        return view
    }

    private func start(_ st: MXRunState, _ targets: [Connection]) async {
        if st.stages != nil { await runStaged(st, targets) } else { await runAll(st, targets) }
        flushOutput()
        update(st.id) { v in v.endedAt = nowMs(); v.staged?.paused = nil }
        live[st.id] = nil
        if let v = view(st.id) { onDone.forEach { $0(v) } }
    }

    private func runStaged(_ st: MXRunState, _ targets: [Connection]) async {
        guard let s0 = st.stages else { return }
        let sizes = mxPlanStages(targets.count, first: s0.first, batch: s0.batch)
        update(st.id) { $0.staged?.sizes = sizes }
        var at = 0
        for i in sizes.indices {
            if st.cancelled { return }
            let group = Array(targets[at..<(at + sizes[i])])
            at += sizes[i]
            update(st.id) { v in
                v.staged?.index = i
                for t in group { if let j = v.results.firstIndex(where: { $0.connId == t.id }) { v.results[j].stage = i + 1 } }
            }
            await runAll(st, group)
            if st.cancelled || i == sizes.count - 1 { return }
            let rs = group.compactMap { result(st.id, $0.id) }
            let failed = rs.filter { $0.status != "done" }.count
            let ok = rs.count - failed
            let stages = st.stages ?? s0
            let stop = failed > 0 && stages.stopOnFail
            if !stop && !stages.pause { continue }
            update(st.id) { $0.staged?.paused = .init(reason: stop ? "failed" : "review", failed: failed, ok: ok) }
            let choice = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in st.decide = c }
            update(st.id) { $0.staged?.paused = nil }
            if choice == "stop" { cancel(st.id); return }
            // The rest at once: no more pauses, and a failure no longer stops
            // it — that is what was asked for.
            if choice == "all" {
                st.stages?.pause = false
                st.stages?.stopOnFail = false
                update(st.id) { $0.staged?.pause = false; $0.staged?.stopOnFail = false }
            }
        }
    }

    private func runAll(_ st: MXRunState, _ list: [Connection]) async {
        guard !list.isEmpty else { return }
        let queue = MXQueue(list)
        let workers = min(max(1, st.options.concurrency), list.count)
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<workers {
                g.addTask { @MainActor in
                    while true {
                        if st.cancelled { return }
                        guard let t = queue.next() else { return }
                        await self.runWithRetries(st, t)
                        if st.options.stopOnError, self.result(st.id, t.id)?.status != "done" {
                            self.cancel(st.id)
                            return
                        }
                    }
                }
            }
        }
    }

    /// Run on one host, and again while it fails and tries are left.
    private func runWithRetries(_ st: MXRunState, _ conn: Connection) async {
        guard result(st.id, conn.id) != nil else { return }
        var attempt = 1
        while attempt <= 1 + st.retries {
            if st.cancelled { return }
            updateResult(st.id, conn.id) { $0.attempt = attempt }
            await runOne(st, conn)
            guard let r = result(st.id, conn.id) else { return }
            if r.status == "done" || r.status == "cancelled" || st.cancelled { return }
            if attempt > st.retries { return }
            // What this try said is kept; the next one starts with a clean slate.
            let lines = r.stderr.trimmed.components(separatedBy: "\n")
            let err = String(lines.suffix(3).joined(separator: "\n").prefix(400))
            updateResult(st.id, conn.id) { r in
                r.tries.append(MultiExecTry(status: r.status, exitCode: r.exitCode, durationMs: r.durationMs, error: err))
                r.status = "retrying"
                r.retryAt = nowMs() + st.retryDelay * 1000
            }
            await st.sleep(st.retryDelay)
            updateResult(st.id, conn.id) { $0.retryAt = nil }
            attempt += 1
        }
    }

    private func begin(_ runId: String, _ connId: String) {
        updateResult(runId, connId) { r in
            r.status = "running"
            r.startedAt = nowMs()
            r.stdout = ""; r.stderr = ""; r.exitCode = nil
            r.endedAt = nil; r.durationMs = nil
            r.promptText = nil
        }
    }

    private func runOne(_ st: MXRunState, _ conn: Connection) async {
        guard !st.cancelled else { return }
        /*
         * A host whose connection is down — it never came up, or it dropped —
         * is dialled again first: with retries on, a host that failed to
         * connect is the most worth trying again.
         */
        if conn.state != .connected {
            begin(st.id, conn.id)
            try? await conn.connect()
            if conn.state != .connected {
                updateResult(st.id, conn.id) { r in
                    r.status = "error"
                    r.stderr = conn.error ?? "not connected"
                    r.endedAt = nowMs()
                    r.durationMs = r.endedAt! - (r.startedAt ?? r.endedAt!)
                }
                return
            }
        }
        if conn.transport == .tsh { await runInteractive(st, conn) } else { await runPiped(st, conn) }
    }

    private func runPiped(_ st: MXRunState, _ conn: Connection) async {
        let runId = st.id, connId = conn.id
        begin(runId, connId)
        /*
         * No TTY (`ssh -T`), so stdout/stderr stay separate and the remote
         * command sees a clean non-interactive environment. A beam goes
         * through `tsh beams exec`. The environment carries the connection's
         * tsh home either way (ssh reaches a Teleport node through
         * `tsh proxy ssh`).
         */
        let inv = conn.execInvocation(st.command)
        let buffer = pending
        let cap: (Bool, Data) -> Void = { isOut, d in buffer.append(runId, connId, isOut: isOut, d) }
        startFlusher()
        let proc: RunningProcess
        do {
            proc = try RunningProcess(inv.exe, inv.args, env: inv.env,
                                      onStdout: { cap(true, $0) }, onStderr: { cap(false, $0) })
        } catch {
            let msg = (error as? AppError)?.message ?? error.localizedDescription
            updateResult(runId, connId) { r in
                r.stderr += msg
                r.exitCode = nil
                r.endedAt = nowMs()
                r.durationMs = r.endedAt! - (r.startedAt ?? r.endedAt!)
                r.status = st.cancelled ? "cancelled" : "error"
            }
            return
        }
        proc.closeStdin()
        st.procs[connId] = proc
        var killedBy: String?
        let timer = DispatchWorkItem { killedBy = "timeout"; proc.signal(SIGKILL) }
        DispatchQueue.main.asyncAfter(deadline: .now() + st.options.timeout / 1000, execute: timer)
        let code = await proc.wait()
        timer.cancel()
        // Let queued output callbacks land before the result is closed.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
        st.procs[connId] = nil
        flushOutput()
        updateResult(runId, connId) { r in
            // A process killed by a signal has no exit code (Node gives null).
            let signalled = proc.process.terminationReason == .uncaughtSignal
            r.exitCode = signalled ? nil : code
            r.endedAt = nowMs()
            r.durationMs = r.endedAt! - (r.startedAt ?? r.endedAt!)
            if killedBy == "timeout" { r.status = "timeout" }
            else if st.cancelled { r.status = "cancelled" }
            else { r.status = !signalled && code == 0 ? "done" : "error" }
        }
    }

    /**
     * The tsh-transport branch: per-session MFA, a leaf cluster, or no
     * OpenSSH client on this machine — none of which the plain,
     * non-interactive spawn above can get through, since a prompt has no pty
     * to appear on or be answered from. Runs `tsh ssh` on a pty
     * (connections.js `execInteractive`), the same path the interactive
     * master uses for MFA; `answer()` routes a typed response in from the
     * dock's per-host prompt. For a host that never actually prompts, the
     * prompt pattern just never matches and this behaves as a plain run.
     */
    private func runInteractive(_ st: MXRunState, _ conn: Connection) async {
        let runId = st.id, connId = conn.id
        begin(runId, connId)
        startFlusher()
        let pty: PTYProcess
        do {
            pty = try PTYProcess(exe: Tools.tsh, args: conn.tshArgs([], command: st.command), env: conn.procEnv(),
                                 cwd: NSHomeDirectory(), cols: 100, rows: 30)
        } catch {
            let msg = (error as? AppError)?.message ?? error.localizedDescription
            updateResult(runId, connId) { r in
                r.stderr += msg
                r.endedAt = nowMs()
                r.durationMs = r.endedAt! - (r.startedAt ?? r.endedAt!)
                r.status = st.cancelled ? "cancelled" : "error"
            }
            return
        }
        st.ptys[connId] = pty
        var out = ""
        var timedOut = false
        let buffer = pending
        let code: Int32 = await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            let timer = DispatchWorkItem { timedOut = true; pty.terminate(grace: 0.5) }
            DispatchQueue.main.asyncAfter(deadline: .now() + st.options.timeout / 1000, execute: timer)
            pty.onData = { [weak self] d in
                buffer.append(runId, connId, isOut: true, d)
                let text = String(decoding: d, as: UTF8.self)
                out += text
                if out.utf8.count > 2_000_000 { out = MultiExecService.tail(out, cap: 2_000_000) }
                let ns = text as NSString
                if mxPromptRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
                    MainActor.assumeIsolated {
                        self?.updateResult(runId, connId) { r in
                            r.status = "prompting"
                            r.promptText = String(text.trimmed.suffix(200))
                        }
                    }
                }
            }
            pty.onExit = { code in timer.cancel(); c.resume(returning: code) }
        }
        st.ptys[connId] = nil
        flushOutput()
        updateResult(runId, connId) { r in
            r.exitCode = timedOut ? nil : code
            r.endedAt = nowMs()
            r.durationMs = r.endedAt! - (r.startedAt ?? r.endedAt!)
            r.promptText = nil
            if st.cancelled { r.status = "cancelled" }
            else if timedOut { r.status = "timeout" }
            else {
                r.status = code == 0 ? "done" : "error"
                if code != 0 { r.stderr += ConnText.cleanupError(out) ?? "exited \(code)" }
            }
        }
    }

    /// `multiexec:answer`: a prompt on one host mid-run — the MFA code or tap
    /// it is waiting on.
    func answer(_ runId: String, _ connId: String, _ data: String) {
        live[runId]?.ptys[connId]?.write(data)
    }

    /// `multiexec:decide`: go on with a paused staged run — "next" stage,
    /// "all" the rest, or "stop".
    func decide(_ runId: String, _ choice: String) {
        guard let st = live[runId], let c = st.decide else { return }
        st.decide = nil
        c.resume(returning: choice)
    }

    /// `multiexec:cancel`.
    func cancel(_ runId: String) {
        guard let st = live[runId] else { return }
        st.cancelled = true
        for p in st.procs.values { p.signal(SIGKILL) }
        // A still-waiting interactive exec is not something the kill above reaches.
        for p in st.ptys.values { p.terminate(grace: 0.5) }
        update(runId) { v in
            for i in v.results.indices where ["pending", "running", "retrying", "prompting"].contains(v.results[i].status) {
                v.results[i].status = "cancelled"
            }
        }
        st.wakeAll()
        // A paused run waiting for a decision has been given one.
        decide(runId, "stop")
    }

    /// `multiexec:clear`: forget the finished runs.
    func clear() {
        runs.removeAll { !$0.running }
    }
}

/// What a live run needs besides its view: its processes, its pause and its waits.
@MainActor
private final class MXRunState {
    let id: String
    let command: String
    let options: MultiExecService.Options
    let retries: Int
    let retryDelay: Double
    var stages: MultiExecService.Stages?
    var cancelled = false
    var procs: [String: RunningProcess] = [:]
    var ptys: [String: PTYProcess] = [:]
    var decide: CheckedContinuation<String, Never>?
    private var wakers: [Int: CheckedContinuation<Void, Never>] = [:]
    private var wakeSeq = 0

    init(id: String, command: String, options: MultiExecService.Options, retries: Int, retryDelay: Double) {
        self.id = id
        self.command = command
        self.options = options
        self.retries = retries
        self.retryDelay = retryDelay
        self.stages = options.stages
    }

    /// A wait that a cancel cuts short.
    func sleep(_ seconds: Double) async {
        if cancelled { return }
        wakeSeq += 1
        let key = wakeSeq
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakers[key] = c
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated { self?.wake(key) }
            }
        }
    }

    private func wake(_ key: Int) { wakers.removeValue(forKey: key)?.resume() }

    func wakeAll() { for k in Array(wakers.keys) { wake(k) } }
}

/// The hosts still to run, shared by a run's workers (all on the main actor).
@MainActor
private final class MXQueue {
    private var items: [Connection]
    init(_ items: [Connection]) { self.items = items }
    func next() -> Connection? { items.isEmpty ? nil : items.removeFirst() }
}

/// Bytes from the children's pipes, per run and host, until the next flush.
/// A UTF-8 sequence split across reads is held back until it is whole.
final class MXOutputBuffer: @unchecked Sendable {
    struct Batch { var runId: String; var connId: String; var out: String; var err: String }
    private let lock = NSLock()
    private var order: [String] = []
    private var bufs: [String: (runId: String, connId: String, out: Data, err: Data)] = [:]

    func append(_ runId: String, _ connId: String, isOut: Bool, _ d: Data) {
        let key = runId + "\u{0}" + connId
        lock.lock(); defer { lock.unlock() }
        if bufs[key] == nil { bufs[key] = (runId, connId, Data(), Data()); order.append(key) }
        if isOut { bufs[key]!.out.append(d) } else { bufs[key]!.err.append(d) }
    }

    func drain() -> [Batch] {
        lock.lock(); defer { lock.unlock() }
        var out: [Batch] = []
        for key in order {
            guard var b = bufs[key] else { continue }
            let (o, oRest) = MXOutputBuffer.split(b.out)
            let (e, eRest) = MXOutputBuffer.split(b.err)
            b.out = oRest; b.err = eRest
            bufs[key] = b
            if !o.isEmpty || !e.isEmpty {
                out.append(Batch(runId: b.runId, connId: b.connId, out: String(decoding: o, as: UTF8.self),
                                 err: String(decoding: e, as: UTF8.self)))
            }
        }
        return out
    }

    /// Complete characters, and an incomplete trailing sequence to keep.
    static func split(_ d: Data) -> (Data, Data) {
        let n = d.count
        guard n > 0 else { return (d, Data()) }
        let bytes = [UInt8](d.suffix(4))
        var i = bytes.count - 1
        var back = 0
        while i >= 0 && back < 4 && (bytes[i] & 0xC0) == 0x80 { i -= 1; back += 1 }
        guard i >= 0 else { return (d, Data()) }
        let lead = bytes[i]
        let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        let have = bytes.count - i
        if have < need {
            let cut = n - have
            return (Data(d.prefix(cut)), Data(d.suffix(have)))
        }
        return (d, Data())
    }
}
