import Foundation

/// Keeps one long-lived command (a `tsh proxy app` or a `tsh ssh -N -R`
/// tunnel) running: restarts it with exponential backoff when it exits,
/// optionally restarts it after sustained health-probe failures, and pauses
/// while the Teleport login it needs has expired. Modeled on prism's
/// internal/tunnel supervisor (github.com/webvictim/prism, Apache-2.0).
///
/// Expiry matters beyond saving work: tsh started with an expired certificate
/// begins a login by itself (an SSO login opens the browser), so a naive
/// restart loop would open login pages over and over. `ready` is checked
/// before every start, and output that looks like a login prompt stops the
/// process and waits for `resume()` (called after a fresh login).
@MainActor
final class Supervisor {
    enum State: Equatable {
        case starting, running, backoff(Int), waiting(String), stopped
        var label: String {
            switch self {
            case .starting: return "starting"
            case .running: return "running"
            case .backoff(let s): return "exited, restarting in \(s)s"
            case .waiting(let why): return why
            case .stopped: return "stopped"
            }
        }
    }

    static let minBackoff: Double = 1, maxBackoff: Double = 30
    /// A run this long counts as healthy and resets the backoff.
    static let stableAfter: Double = 30
    static let healthInterval: Double = 10
    /// Consecutive failed probes before a restart (6 × 10s ≈ 60s, as prism).
    static let healthThreshold = 6

    let key: String
    /// The command to run, or a reason not to start now (e.g. login expired).
    let command: () -> Result<[String], WaitReason>
    /// Port on this Mac to probe over HTTP; nil = no health probing.
    let healthPort: Int?
    let onState: (State) -> Void
    let onStderr: (String) -> Void

    struct WaitReason: Error { var text: String }

    private(set) var state: State = .stopped { didSet { if state != oldValue { onState(state) } } }
    private var proc: RunningProcess?
    private var loop: Task<Void, Never>?
    private var health: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var stopping = false

    init(key: String, healthPort: Int? = nil,
         command: @escaping () -> Result<[String], WaitReason>,
         onState: @escaping (State) -> Void = { _ in }, onStderr: @escaping (String) -> Void = { _ in }) {
        self.key = key; self.healthPort = healthPort; self.command = command
        self.onState = onState; self.onStderr = onStderr
    }

    var isActive: Bool { loop != nil }
    var isRunning: Bool { proc?.process.isRunning ?? false }

    func start() {
        guard loop == nil else { return }
        stopping = false
        loop = Task { [weak self] in await self?.superviseLoop() }
        if healthPort != nil { health = Task { [weak self] in await self?.healthLoop() } }
    }

    func stop() {
        stopping = true
        loop?.cancel(); loop = nil
        health?.cancel(); health = nil
        proc?.closeStdin()   // the Supervised wrapper kills the command
        proc = nil
        wakeUp()
        state = .stopped
    }

    /// Kill the current process; the loop starts a new one right away (used
    /// after a fresh login so the command picks up the new certificate).
    func restart() {
        guard loop != nil else { return }
        proc?.closeStdin()
        wakeUp()
    }

    /// Leave a login wait early (a login just happened).
    func resume() { if case .waiting = state { wakeUp() } }

    // MARK: - loops

    private func superviseLoop() async {
        var backoff = Self.minBackoff
        while !stopping && !Task.isCancelled {
            let cmd: [String]
            switch command() {
            case .failure(let why):
                state = .waiting(why.text)
                await sleep(15)    // re-check readiness periodically; resume() wakes early
                continue
            case .success(let c):
                cmd = c
            }
            state = .starting
            let began = Date()
            var loginPrompt = false
            _ = try? await Shell.run(Supervised.argv(cmd), interactiveStdin: true, extraEnv: TshClient.env,
                onStdoutLine: { [weak self] line in
                    if Supervisor.looksLikeLoginPrompt(line) {
                        Task { @MainActor in loginPrompt = true; self?.proc?.closeStdin() }
                    }
                },
                onStderrLine: { [weak self] line in
                    Task { @MainActor in
                        guard let self else { return }
                        if Supervisor.looksLikeLoginPrompt(line) { loginPrompt = true; self.proc?.closeStdin() }
                        self.onStderr(line)
                    }
                },
                register: { [weak self] p in Task { @MainActor in
                    guard let self, !self.stopping else { p.closeStdin(); return }
                    self.proc = p
                    self.state = .running
                } },
                check: false)
            // The command exited on its own: release its watchdog subshell too.
            proc?.closeStdin()
            proc = nil
            if stopping || Task.isCancelled { break }
            if loginPrompt {
                state = .waiting("waiting for tsh login")
                await sleep(3600)  // until resume()/restart() after a login
                backoff = Self.minBackoff
                continue
            }
            if Date().timeIntervalSince(began) >= Self.stableAfter { backoff = Self.minBackoff }
            state = .backoff(Int(backoff.rounded()))
            await sleep(backoff)
            backoff = min(backoff * 2, Self.maxBackoff)
        }
        if !stopping { state = .stopped }
    }

    private func healthLoop() async {
        guard let port = healthPort else { return }
        var failures = 0
        while !stopping && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.healthInterval))
            guard isRunning, state == .running else { failures = 0; continue }
            if await Self.probe(port: port) {
                failures = 0
            } else {
                failures += 1
                if failures >= Self.healthThreshold {
                    onStderr("health: 127.0.0.1:\(port) failed \(failures) probes; restarting")
                    failures = 0
                    proc?.closeStdin()
                }
            }
        }
    }

    /// Any HTTP response counts as alive; only connection failures don't.
    static func probe(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "HEAD"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        return (try? await session.data(for: req)) != nil
    }

    /// tsh output that means it started a login instead of doing its job.
    nonisolated static func looksLikeLoginPrompt(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("if browser window does not open") || l.contains("enter password")
            || l.contains("/web/login") || (l.contains("http://127.0.0.1:") && l.contains("open it by clicking"))
    }

    // MARK: - interruptible sleep

    private var sleepGen = 0

    private func sleep(_ seconds: Double) async {
        sleepGen += 1
        let gen = sleepGen
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wake = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                // A timer from an earlier, already-woken sleep must not end this one.
                guard let self, self.sleepGen == gen else { return }
                self.wakeUp()
            }
        }
    }

    private func wakeUp() {
        let c = wake; wake = nil; c?.resume()
    }
}
