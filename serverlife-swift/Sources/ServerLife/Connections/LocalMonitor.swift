import Foundation
import Darwin

/// localmonitor.js: live stats for this computer, under a local shell — the
/// same bar a server session has, fed the same samples, but read here rather
/// than by a command on a host: on macOS what stands in for /proc (the VM
/// statistics vm_stat prints, vm.swapusage, netstat), with the processor
/// ticks, load and uptime. One sampler however many local shells are open;
/// sessions starts it with the first and stops it with the last (events
/// arrive as `.monitor(id: "local", …)`).
@MainActor
final class LocalMonitor {
    static let shared = LocalMonitor()
    static let key = "local"

    private var timer: Timer?
    private var first: DispatchWorkItem?
    private var prevCpu: (idle: Double, total: Double)?
    private var prevNet: (rx: Double, tx: Double)?
    private var prevAt: Double = 0
    private var sampling = false
    private var emit: ((MonitorEvent) -> Void)?

    var running: Bool { timer != nil }

    /// Start sampling every `interval` seconds; `emit` gets hello, then samples.
    @discardableResult
    func start(interval: Double = 5, emit: ((MonitorEvent) -> Void)? = nil) -> MonitorStart {
        stop()
        self.emit = emit ?? { ev in ConnectionManager.shared.emitLocalMonitor(ev) }
        prevCpu = nil; prevNet = nil; prevAt = 0
        _ = cpu()
        self.emit?(.hello(cpus: ProcessInfo.processInfo.activeProcessorCount, interval: Int(interval)))
        timer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) { _ in
            MainActor.assumeIsolated { LocalMonitor.shared.sample() }
        }
        // The first numbers sooner than a whole interval in.
        let w = DispatchWorkItem { MainActor.assumeIsolated { if LocalMonitor.shared.running { LocalMonitor.shared.sample() } } }
        first = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
        return MonitorStart(ok: true)
    }

    @discardableResult
    func stop() -> Bool {
        timer?.invalidate(); timer = nil
        first?.cancel(); first = nil
        return true
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        Task { @MainActor in
            defer { sampling = false }
            let net = await LocalMonitor.netTotals()
            let mem = LocalMonitor.macMemory()
            let now = nowMs()
            let secs = prevAt > 0 ? (now - prevAt) / 1000 : 0
            func rate(_ a: Double, _ b: Double?) -> Double { (b != nil && secs > 0) ? max(0, (a - b!) / secs) : 0 }
            var load = [Double](repeating: 0, count: 3)
            _ = getloadavg(&load, 3)
            let s = MonitorSample(at: now, cpu: cpu(), memTotal: mem.total, memUsed: mem.used,
                                  swapTotal: mem.swapTotal, swapUsed: mem.swapUsed, load: load[0],
                                  disk: LocalMonitor.diskPct(), rx: rate(net.rx, prevNet?.rx), tx: rate(net.tx, prevNet?.tx),
                                  uptime: ProcessInfo.processInfo.systemUptime.rounded())
            prevNet = net
            prevAt = now
            if running { emit?(.sample(s)) }
        }
    }

    /// CPU busy %, from the change in processor ticks since the last call.
    private func cpu() -> Double {
        guard let now = LocalMonitor.cpuTicks() else { return 0 }
        defer { prevCpu = now }
        guard let p = prevCpu, now.total > p.total else { return 0 }
        return max(0, min(100, 100 * (1 - (now.idle - p.idle) / (now.total - p.total))))
    }

    nonisolated static func cpuTicks() -> (idle: Double, total: Double)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var idle = 0.0, total = 0.0
        for c in 0..<Int(count) {
            let base = c * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)]), sys = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let id = Double(info[base + Int(CPU_STATE_IDLE)]), nice = Double(info[base + Int(CPU_STATE_NICE)])
            idle += id
            total += user + sys + id + nice
        }
        return (idle, total)
    }

    /// Used memory as Activity Monitor counts it, near enough — what is not
    /// free, inactive or speculative (only truly free pages would make a Mac
    /// look nearly full) — and swap from vm.swapusage.
    nonisolated static func macMemory() -> (total: Double, used: Double, swapTotal: Double, swapUsed: Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
        }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let pageSize = Double(page == 0 ? 16384 : page)
        let avail = kr == KERN_SUCCESS
            ? Double(UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)) * pageSize : 0
        var sw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let ok = sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0
        return (total, max(0, total - avail), ok ? Double(sw.xsu_total) : 0, ok ? Double(sw.xsu_used) : 0)
    }

    /// How full the disk is, %. / is the sealed system volume; the Data volume is where files go.
    nonisolated static func diskPct() -> Double {
        let target = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        var s = statfs()
        guard statfs(target, &s) == 0 else { return 0 }
        let bs = Double(s.f_bsize)
        let used = Double(s.f_blocks - s.f_bfree) * bs, avail = Double(s.f_bavail) * bs
        return used + avail > 0 ? (100 * used / (used + avail)).rounded() : 0
    }

    /// Bytes received and sent so far, every interface but loopback.
    nonisolated static func netTotals() async -> (rx: Double, tx: Double) {
        let r = await Proc.run("/usr/sbin/netstat", ["-ibn"], timeout: 4)
        return parseNetstatIbn(r.ok ? r.out : "")
    }

    /// `netstat -ibn`: one `<Link#n>` row per interface carries its byte counts.
    nonisolated static func parseNetstatIbn(_ out: String) -> (rx: Double, tx: Double) {
        let lines = out.components(separatedBy: "\n")
        func fields(_ l: String) -> [String] { l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
        let head = fields(lines.first ?? "")
        guard let iI = head.firstIndex(of: "Ibytes"), let iO = head.firstIndex(of: "Obytes") else { return (0, 0) }
        var rx = 0.0, tx = 0.0
        var seen = Set<String>()
        for line in lines.dropFirst() {
            let f = fields(line)
            guard f.count >= head.count, f.count > 2, f[2].hasPrefix("<Link#"), !f[0].hasPrefix("lo"), !seen.contains(f[0])
            else { continue }
            seen.insert(f[0])
            // A row with no address has one field fewer, before the counts.
            let shift = f.count - head.count
            if iI + shift < f.count { rx += Double(f[iI + shift]) ?? 0 }
            if iO + shift < f.count { tx += Double(f[iO + shift]) ?? 0 }
        }
        return (rx, tx)
    }
}
