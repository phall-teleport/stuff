import Foundation

/// What the live monitor says (connections.js `parseMonitorLine` and the
/// `ended` push; localmonitor.js sends the same shapes for "local").
enum MonitorEvent: Sendable, Equatable {
    case hello(cpus: Int, interval: Int)
    case unsupported(os: String)
    case sample(MonitorSample)
    /// The command ended: a drop, an error (`error`, empty when stopped on purpose).
    case ended(code: Int32, error: String)

    var json: JSON {
        switch self {
        case .hello(let c, let i): return ["kind": "hello", "cpus": .number(Double(c)), "interval": .number(Double(i))]
        case .unsupported(let os): return ["kind": "unsupported", "os": .string(os)]
        case .sample(let s): return s.json
        case .ended(let c, let e): return ["kind": "ended", "code": .number(Double(c)), "error": .string(e)]
        }
    }
}

/// One reading. Bytes for memory, percent for cpu and disk, bytes/s for the network.
struct MonitorSample: Sendable, Equatable {
    var at: Double
    var cpu: Double
    var memTotal: Double
    var memUsed: Double
    var swapTotal: Double
    var swapUsed: Double
    var load: Double
    var disk: Double
    var rx: Double
    var tx: Double
    var uptime: Double

    var json: JSON {
        ["kind": "sample", "at": .number(at), "cpu": .number(cpu), "memTotal": .number(memTotal),
         "memUsed": .number(memUsed), "swapTotal": .number(swapTotal), "swapUsed": .number(swapUsed),
         "load": .number(load), "disk": .number(disk), "rx": .number(rx), "tx": .number(tx), "uptime": .number(uptime)]
    }
}

enum ConnMonitorText {
    /// `MONITOR_SCRIPT(interval)`: one long-running command per host that
    /// prints a line every few seconds. On a Teleport node every exec is a
    /// session in the audit log, and one session that stays open is one
    /// entry, where a poll every five seconds would be seventeen thousand a
    /// day. CPU and network are rates, so the script keeps the previous
    /// reading and prints the difference. Linux reads /proc; a host without
    /// it says so once and stops, rather than printing zeros.
    static func script(interval: Double) -> String {
        let r = interval.isFinite ? Int(interval.rounded()) : 0
        let i = max(2, min(60, r == 0 ? 5 : r))
        return """
        i=\(i)
        if [ ! -r /proc/stat ] || [ ! -r /proc/meminfo ]; then echo "SLMON unsupported=$(uname -s 2>/dev/null)"; exit 0; fi
        cpu() { awk '/^cpu /{t=0; for(k=2;k<=NF;k++) t+=$k; print t, $5+$6; exit}' /proc/stat; }
        net() { awk -F'[: ]+' 'NR>2 && $2!="lo" {rx+=$3; tx+=$11} END{print rx+0, tx+0}' /proc/net/dev 2>/dev/null || echo "0 0"; }
        n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
        set -- $(cpu); pt=$1; pi=$2
        set -- $(net); prx=$1; ptx=$2
        echo "SLMON hello cpus=$n interval=$i"
        while :; do
          sleep $i
          set -- $(cpu); t=$1; idle=$2
          set -- $(net); rx=$1; tx=$2
          dt=$((t-pt)); di=$((idle-pi)); c=0
          [ "$dt" -gt 0 ] && c=$(( (1000*(dt-di)) / dt ))
          set -- $(awk '/^MemTotal:/{a=$2} /^MemAvailable:/{b=$2} /^SwapTotal:/{c=$2} /^SwapFree:/{d=$2} END{print a+0, b+0, c+0, d+0}' /proc/meminfo)
          mt=$1; ma=$2; st=$3; sf=$4
          l=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
          d=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
          u=$(cut -d. -f1 /proc/uptime 2>/dev/null)
          echo "SLMON cpu=$c memt=$mt mema=$ma swapt=$st swapf=$sf load=${l:-0} disk=${d:-0} rx=$(( (rx-prx)/i )) tx=$(( (tx-ptx)/i )) up=${u:-0}"
          pt=$t; pi=$idle; prx=$rx; ptx=$tx
        done
        """
    }

    /// `parseMonitorLine`: one line as numbers, or nil for anything else.
    /// CPU arrives in tenths of a percent so the shell never needs floating point.
    static func parse(_ line: String, at: Double = nowMs()) -> MonitorEvent? {
        guard line.hasPrefix("SLMON ") else { return nil }
        var kv: [String: String] = [:]
        var flags = Set<String>()
        for part in line.dropFirst(6).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let i = part.firstIndex(of: "="), i != part.startIndex {
                kv[String(part[..<i])] = String(part[part.index(after: i)...])
            } else {
                flags.insert(String(part))
            }
        }
        if let os = kv["unsupported"] { return .unsupported(os: os) }
        if flags.contains("unsupported") { return .unsupported(os: "") }
        func num(_ k: String) -> Double {
            guard let s = kv[k], let v = Double(s.trimmed.isEmpty ? "0" : s), v.isFinite else { return 0 }
            return v
        }
        if flags.contains("hello") || kv["hello"] != nil {
            let c = Int(num("cpus")), i = Int(num("interval"))
            return .hello(cpus: c == 0 ? 1 : c, interval: i == 0 ? 5 : i)
        }
        let memTotal = num("memt") * 1024, memAvail = num("mema") * 1024, swapTotal = num("swapt") * 1024
        return .sample(MonitorSample(
            at: at, cpu: max(0, min(100, num("cpu") / 10)), memTotal: memTotal,
            memUsed: max(0, memTotal - memAvail), swapTotal: swapTotal,
            swapUsed: max(0, swapTotal - num("swapf") * 1024), load: num("load"),
            disk: max(0, min(100, num("disk"))), rx: max(0, num("rx")), tx: max(0, num("tx")), uptime: num("up")))
    }
}

/// The monitor's running command and what it has said so far.
final class ConnMonitorProc {
    let proc: RunningProcess
    var buf = ""
    var err = ""
    var stopped = false
    init(_ p: RunningProcess) { proc = p }
}

/// `startMonitor`'s answer.
struct MonitorStart: Sendable {
    var ok: Bool
    /// Already running: this caller joined it.
    var running = false
    /// "mfa" or "quiet" when refused.
    var reason: String?
    var error: String?

    var json: JSON {
        var o: [String: JSON] = ["ok": .bool(ok)]
        if running { o["running"] = true }
        if let reason { o["reason"] = .string(reason) }
        if let error { o["error"] = .string(error) }
        return .object(o)
    }
}

extension Connection {
    /// `startMonitor`: the live monitor, shared by every pane on this
    /// connection — the second caller is told it is already running.
    ///
    /// Refused where serverInfo is, and for the same reason: on a host whose
    /// tsh transport was chosen for per-session MFA, a command session is one
    /// more approval nobody asked for.
    func startMonitor(interval: Double = 5) async -> MonitorStart {
        if transport == .tsh && !tshByNecessity {
            return MonitorStart(ok: false, reason: "mfa",
                                error: "Live stats need a command session, which on a per-session-MFA host means another approval.")
        }
        if monitor != nil { return MonitorStart(ok: true, running: true) }
        do { try await connect() } catch {
            return MonitorStart(ok: false, error: (error as? AppError)?.message ?? error.localizedDescription)
        }
        if monitor != nil { return MonitorStart(ok: true, running: true) }
        let script = ConnMonitorText.script(interval: interval)
        let inv: (exe: String, args: [String])
        switch transport {
        case .beam: inv = (Tools.tsh, beamArgs(command: script))
        case .tsh: inv = (Tools.tsh, tshArgs([], command: script))
        case .mux: inv = (Tools.ssh, sshArgs(["-T", target, script]))
        }
        let box = ConnMonitorBox()
        let p: RunningProcess
        do {
            p = try RunningProcess(inv.exe, inv.args, env: procEnv(), onStdout: { [weak self] d in
                let s = String(decoding: d, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.monitorOut(box, s) } }
            }, onStderr: { d in
                let s = String(decoding: d, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { if let m = box.mon { m.err = String((m.err + s).suffix(2000)) } } }
            })
        } catch {
            let msg = (error as? AppError)?.message ?? error.localizedDescription
            onEvent?(.monitor(id: id, event: .ended(code: 1, error: msg)))
            return MonitorStart(ok: true)
        }
        p.closeStdin()
        let mon = ConnMonitorProc(p)
        box.mon = mon
        monitor = mon
        p.onExit { [weak self] code in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.monitorEnded(mon, code: code) } }
        }
        return MonitorStart(ok: true)
    }

    /// `stopMonitor`: false when none was running.
    @discardableResult
    func stopMonitor() -> Bool {
        guard let mon = monitor else { return false }
        mon.stopped = true
        mon.proc.terminate()
        return true
    }

    fileprivate func monitorOut(_ box: ConnMonitorBox, _ s: String) {
        guard let mon = box.mon, monitor === mon else { return }
        mon.buf += s
        while let nl = mon.buf.firstIndex(of: "\n") {
            let line = String(mon.buf[..<nl]).trimmed
            mon.buf = String(mon.buf[mon.buf.index(after: nl)...])
            if let ev = ConnMonitorText.parse(line) { onEvent?(.monitor(id: id, event: ev)) }
        }
    }

    fileprivate func monitorEnded(_ mon: ConnMonitorProc, code: Int32) {
        guard monitor === mon else { return }
        monitor = nil
        let err = mon.stopped ? "" : (ConnText.firstProblem(mon.err).nilIfEmpty ?? String(mon.err.trimmed.prefix(300)))
        onEvent?(.monitor(id: id, event: .ended(code: code, error: err)))
    }
}

/// Lets the output callbacks find the monitor they belong to once it exists.
fileprivate final class ConnMonitorBox: @unchecked Sendable { var mon: ConnMonitorProc? }
