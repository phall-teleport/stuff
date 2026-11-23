import Foundation

/// Drawing helpers for the live stats bar (monitor.js).
enum PaneStatsText {
    // MARK: drawing helpers (monitor.js)

    static let blocks = Array("▁▂▃▄▅▆▇█")
    static func sparkline(_ values: [Double]) -> String {
        String(values.map { blocks[min(7, max(0, Int(($0 / 100 * 7).rounded())))] })
    }

    /// "" / "warn" / "bad".
    static func level(_ pct: Double, warn: Double = 80, bad: Double = 92) -> String {
        pct >= bad ? "bad" : pct >= warn ? "warn" : ""
    }

    static func uptime(_ sec: Double) -> String {
        let s = Int(sec)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
