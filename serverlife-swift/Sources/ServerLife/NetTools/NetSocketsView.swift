import SwiftUI

// nettools.js renderSockets: listening sockets first (what could be
// reached), then active connections (what is actually talking to what).

enum NetSocketWords {
    /// host:port, or just the port when there is no address worth repeating.
    static func addr(_ a: String?, _ port: Int?) -> String {
        guard let port else { return a ?? "*" }
        let keep = a.map { !$0.isEmpty && $0 != "0.0.0.0" && $0 != "::" && $0 != "*" } ?? false
        return "\(keep ? a! : "*"):\(port)"
    }

    static func isListening(_ x: SocketRow) -> Bool {
        x.state.range(of: "^(listen|unconn)", options: [.regularExpression, .caseInsensitive]) != nil
            || (x.state.isEmpty && x.remotePort == nil)
    }

    static func head(_ r: SocketsResult, _ label: String?) -> String {
        "\(label.map { "\($0) — " } ?? "")\(r.rows.count) socket\(r.rows.count == 1 ? "" : "s")" + (r.tool.map { "  ·  \($0)" } ?? "")
    }

    static func process(_ x: SocketRow) -> String { x.pid.map { "\(x.process ?? "?") (\($0))" } ?? (x.process ?? "") }

    static let noProcessHint = "Some rows have no process name — that usually means it belongs to another user, "
        + "which needs more than this app runs with to see."

    static func text(_ r: SocketsResult, _ label: String?) -> String {
        if let m = r.missing { return "\(label.map { "\($0) has" } ?? "This machine has") no \(m)." + (r.hint.map { "\nto install it\n\($0)" } ?? "") }
        let listening = r.rows.filter(isListening), connected = r.rows.filter { !isListening($0) }
        func table(_ l: [SocketRow]) -> [String] {
            ["Proto\tLocal\tState\tRemote\tProcess"] + l.map {
                [$0.proto, addr($0.localAddr, $0.localPort), $0.state,
                 $0.remotePort != nil ? addr($0.remoteAddr, $0.remotePort) : "", process($0)].joined(separator: "\t")
            }
        }
        var out = [head(r, label), r.command]
        if r.rows.isEmpty { out.append("Nothing parsed from the output — see the raw text below.") }
        if !listening.isEmpty { out.append("Listening (\(listening.count))"); out += table(listening) }
        if !connected.isEmpty { out.append("Connected (\(connected.count))"); out += table(connected) }
        return out.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct SocketsView: View {
    let r: SocketsResult
    let label: String?

    var body: some View {
        let p = Theme.shared.p
        if let missing = r.missing {
            NTEmpty(text: "\(label.map { "\($0) has" } ?? "This machine has") no \(missing).", color: p.amber)
            if let hint = r.hint {
                NTHead(text: "to install it")
                NTPre(text: hint)
                if label != nil {
                    NTHint(text: "Then press Re-check beside the host, and the tool becomes available.").padding(.top, 4)
                }
            }
        } else {
            NTCmd(text: NetSocketWords.head(r, label))
            NTCmdBlock(command: r.command)
            if r.rows.isEmpty {
                NTEmpty(text: "Nothing parsed from the output — see the raw text below.")
                NTPre(text: r.text, boxed: true)
            } else {
                let listening = r.rows.filter(NetSocketWords.isListening)
                let connected = r.rows.filter { !NetSocketWords.isListening($0) }
                if !listening.isEmpty {
                    NTHead(text: "Listening (\(listening.count))")
                    table(listening)
                }
                if !connected.isEmpty {
                    NTHead(text: "Connected (\(connected.count))", top: 10)
                    table(connected)
                }
                if r.rows.contains(where: { $0.pid == nil }) {
                    NTHint(text: NetSocketWords.noProcessHint).padding(.top, 10)
                }
            }
        }
    }

    private func table(_ list: [SocketRow]) -> some View {
        let p = Theme.shared.p
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                ForEach(["Proto", "Local", "State", "Remote", "Process"], id: \.self) {
                    Text($0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.muted)
                }
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, x in
                let listen = NetSocketWords.isListening(x) || x.remotePort == nil
                let estab = x.state.lowercased().hasPrefix("estab")
                let local = NetSocketWords.addr(x.localAddr, x.localPort)
                let remote = x.remotePort != nil ? NetSocketWords.addr(x.remoteAddr, x.remotePort) : ""
                GridRow {
                    Text(x.proto)
                    Text(local).help(local).foregroundStyle(listen ? p.green : p.textDim)
                    Text(x.state).foregroundStyle(estab ? p.accent : p.muted)
                    Text(remote).help(remote)
                    Text(NetSocketWords.process(x)).help(x.process ?? "")
                }
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            }
        }
        .padding(.bottom, 8)
    }
}
