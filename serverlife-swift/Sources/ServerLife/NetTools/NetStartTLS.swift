import Foundation
import Network

/// The plaintext half of STARTTLS (nettools.js `starttlsHandshake`): say
/// hello, ask to upgrade, and wait for the server to agree — all three
/// protocols spell this differently. It sits *below* TLS in the connection's
/// protocol stack and marks itself ready only once the server has agreed,
/// so the TLS handshake then runs on the same connection.
final class StartTLSFramer: NWProtocolFramerImplementation {
    static let label = "ServerLife STARTTLS"
    static let definition = NWProtocolFramer.Definition(implementation: StartTLSFramer.self)

    /// Why the upgrade failed, in the server's words — read by the caller
    /// once the connection reports `.failed`.
    final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        var message: String? {
            get { lock.lock(); defer { lock.unlock() }; return text }
            set { lock.lock(); text = newValue; lock.unlock() }
        }
    }

    private var proto = ""
    private var failure: Failure?
    private var buf = ""
    private var stage = 0
    private var done = false

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        proto = framer.options["protocol"] as? String ?? ""
        failure = framer.options["failure"] as? Failure
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while !done {
            var chunk = Data()
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65536) { b, _ in
                guard let b, b.count > 0 else { return 0 }
                chunk.append(contentsOf: b)
                return b.count
            }
            if !parsed || chunk.isEmpty { break }
            buf += String(data: chunk, encoding: .isoLatin1) ?? ""
            step(framer)
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    private func has(_ pattern: String, lines: Bool = false, caseless: Bool = false) -> Bool {
        var o: NSRegularExpression.Options = []
        if lines { o.insert(.anchorsMatchLines) }
        if caseless { o.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: o) else { return false }
        return re.firstMatch(in: buf, range: NSRange(buf.startIndex..., in: buf)) != nil
    }

    private func send(_ framer: NWProtocolFramer.Instance, _ line: String) {
        buf = ""
        stage += 1
        framer.writeOutput(data: Data(line.utf8))
    }

    private func upgraded(_ framer: NWProtocolFramer.Instance) {
        done = true
        framer.passThroughInput()
        framer.passThroughOutput()
        framer.markReady()
    }

    private func fail(_ framer: NWProtocolFramer.Instance, _ fallback: String) {
        done = true
        let first = buf.components(separatedBy: "\r\n").first ?? ""
        failure?.message = first.isEmpty ? fallback : first
        framer.markFailed(error: .posix(.ECONNREFUSED))
    }

    private func step(_ framer: NWProtocolFramer.Instance) {
        switch proto {
        case "smtp":
            // Multi-line greeting/EHLO replies continue "250-…"; the final
            // line of a block is the only one spelled "250 " (a space).
            if stage == 0 && has("^220[ -]") {
                if !has("^220 ", lines: true) { return }
                return send(framer, "EHLO serverlife.local\r\n")
            }
            if stage == 1 && has("^250[ -]") {
                if !has("^250 ", lines: true) { return }
                return send(framer, "STARTTLS\r\n")
            }
            if stage == 2 {
                if has("^220") { return upgraded(framer) }
                if has("^5\\d\\d") { return fail(framer, "STARTTLS refused.") }
            }
        case "imap":
            if stage == 0 && has("^\\*\\s+OK", caseless: true) { return send(framer, "a1 STARTTLS\r\n") }
            if stage == 1 {
                if has("^a1\\s+OK", lines: true, caseless: true) { return upgraded(framer) }
                if has("^a1\\s+(NO|BAD)", lines: true, caseless: true) { return fail(framer, "STARTTLS refused.") }
            }
        case "pop3":
            if stage == 0 && has("^\\+OK") { return send(framer, "STLS\r\n") }
            if stage == 1 {
                if has("^\\+OK") { return upgraded(framer) }
                if has("^-ERR") { return fail(framer, "STLS refused.") }
            }
        default:
            upgraded(framer)
        }
    }
}
