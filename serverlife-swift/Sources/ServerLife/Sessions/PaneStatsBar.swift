import SwiftUI

/// The live stats line under a pane (monitor.js `contents`): the numbers in
/// the text colour, their names muted, and amber or red only for what is
/// running high.
struct PaneStatsBar: View {
    let pane: SessionPane

    var body: some View {
        let p = Theme.shared.p
        let local = pane.statsKey == PaneStats.local
        HStack(spacing: 14) {
            if let k = pane.statsKey { contents(k) }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 9)
        .frame(height: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(p.panel)
        .overlay(Rectangle().fill(p.borderSoft).frame(height: 1), alignment: .top)
        .help(local ? "Live stats for this computer — right-click the pane to hide them"
                    : "Live stats for this host — right-click the pane to hide them")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(Theme.shared.p.muted).truncationMode(.tail)
    }

    private func color(_ level: String) -> Color {
        let p = Theme.shared.p
        return level == "bad" ? p.red : level == "warn" ? p.amber : p.textDim
    }

    private func cell(_ k: String, _ v: String, _ level: String = "", _ tip: String = "") -> some View {
        HStack(spacing: 5) {
            Text(k).foregroundStyle(Theme.shared.p.muted)
            Text(v).foregroundStyle(color(level))
        }
        .help(tip)
    }

    private func rate(_ n: Double) -> String { "\(Fmt.bytes(n))/s" }

    @ViewBuilder
    private func contents(_ k: String) -> some View {
        let st = PaneStats.shared
        let e = st.entry(k)
        let error = e?.error ?? ""
        switch st.status(k) {
        case .mfa:
            note("Live stats are off on this host: it uses per-session MFA, and they would need another approval.")
        case .unsupported:
            note("Live stats read Linux’s /proc, which this host (\(st.unsupportedOS[k].flatMap { $0.isEmpty ? nil : $0 } ?? "not Linux")) does not have.")
        case .ended:
            note("Live stats stopped" + (error.isEmpty ? "." : ": " + error))
            Button("Restart") { st.restart(k) }
                .buttonStyle(.plain).foregroundStyle(Theme.shared.p.accent)
        default:
            let all = st.samples[k] ?? []
            if let s = all.last ?? e?.last { readings(e, all.isEmpty ? [s] : all, s) } else { note("Reading live stats…") }
        }
    }

    @ViewBuilder
    private func readings(_ e: LiveStats.Entry?, _ all: [MonitorSample], _ s: MonitorSample) -> some View {
        let memPct = s.memTotal > 0 ? 100 * s.memUsed / s.memTotal : 0
        let swapPct = s.swapTotal > 0 ? 100 * s.swapUsed / s.swapTotal : 0
        let cpus = e?.hello?.cpus ?? 1
        let perCpu = s.load / Double(cpus)
        let plural = cpus == 1 ? "" : "s"
        cell("CPU", String(format: "%.0f%%", s.cpu), PaneStatsText.level(s.cpu),
             "CPU busy across \(cpus) CPU\(plural), over the last \(e?.hello?.interval ?? 5)s")
        Text(PaneStatsText.sparkline(all.map(\.cpu)))
            .kerning(-1)
            .foregroundStyle(PaneStatsText.level(s.cpu).isEmpty ? Theme.shared.p.accent : color(PaneStatsText.level(s.cpu)))
            .help("CPU over the last few minutes")
        cell("Mem", "\(Fmt.bytes(s.memUsed)) / \(Fmt.bytes(s.memTotal))", PaneStatsText.level(memPct, warn: 85, bad: 95),
             String(format: "%.0f", memPct) + "% of memory in use (MemTotal − MemAvailable)")
        if s.swapTotal > 0 {
            cell("Swap", String(format: "%.0f%%", swapPct), PaneStatsText.level(swapPct, warn: 50, bad: 80),
                 "\(Fmt.bytes(s.swapUsed)) of \(Fmt.bytes(s.swapTotal)) swap in use")
        }
        cell("Load", String(format: "%.2f", s.load), perCpu >= 2 ? "bad" : perCpu >= 1 ? "warn" : "",
             "1-minute load average, on \(cpus) CPU\(plural)")
        cell("Disk /", "\(Int(s.disk))%", PaneStatsText.level(s.disk, warn: 85, bad: 95), "How full the root filesystem is")
        cell("Net", "↓ \(rate(s.rx))  ↑ \(rate(s.tx))", "", "Received and sent, every interface but loopback")
        cell("Up", PaneStatsText.uptime(s.uptime))
    }
}
