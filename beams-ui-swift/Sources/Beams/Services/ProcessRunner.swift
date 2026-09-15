import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: String
    var ok: Bool { status == 0 }
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

struct ProcessError: LocalizedError {
    let command: String
    let status: Int32
    let stderr: String
    var errorDescription: String? {
        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "\(command): exit \(status)" : "\(command): \(tail)"
    }
}

struct NotFoundError: LocalizedError {
    let binary: String
    var errorDescription: String? { "\"\(binary)\" not found on PATH. Install it or set its path in Settings." }
}

/// A handle to a running child so a turn can be stopped, and — when started
/// with interactive stdin — written to (Claude Code's stream-json control
/// protocol rides on stdin/stdout).
final class RunningProcess {
    let process: Process
    private let stdin: FileHandle?
    private let queue = DispatchQueue(label: "beams.process.stdin")
    private var closed = false

    init(_ p: Process, stdin: FileHandle? = nil) { process = p; self.stdin = stdin }

    func terminate() { if process.isRunning { process.terminate() } }

    /// Writes one line (a JSON message) to the child's stdin.
    func send(line: String) {
        guard let stdin else { return }
        queue.async { [self] in
            guard !closed else { return }
            try? stdin.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// Closes stdin so a stream-json child knows no more input is coming.
    func closeStdin() {
        guard let stdin else { return }
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            try? stdin.close()
        }
    }
}

/// Runs child processes with a terminal-like PATH. GUI apps launched from the
/// Dock only get /usr/bin:/bin:/usr/sbin:/sbin, which hides tsh, gh and
/// Homebrew, so we ask the login shell for its PATH once at startup.
enum Shell {
    static private(set) var path: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    static func augmentPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parts: [String] = []
        if let sh = ProcessInfo.processInfo.environment["SHELL"], !sh.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sh)
            p.arguments = ["-lc", "printf %s \"$PATH\""]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            let deadline = DispatchTime.now() + 4
            if (try? p.run()) != nil {
                let group = DispatchGroup(); group.enter()
                p.terminationHandler = { _ in group.leave() }
                if group.wait(timeout: deadline) == .timedOut { p.terminate() }
                let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                parts += s.split(separator: ":").map(String.init)
            }
        }
        parts += ["\(home)/.tsh/bin", "/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "\(home)/.local/bin", "\(home)/go/bin"]
        parts += path.split(separator: ":").map(String.init)
        var seen = Set<String>(); var final: [String] = []
        for p in parts where !p.isEmpty && !seen.contains(p) { seen.insert(p); final.append(p) }
        path = final.joined(separator: ":")
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    static func which(_ bin: String) -> String? {
        if bin.contains("/") { return FileManager.default.isExecutableFile(atPath: bin) ? bin : nil }
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(bin)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs argv (argv[0] resolved on our PATH). With `onStdoutLine`, stdout is
    /// streamed line by line and not collected; otherwise it is returned as
    /// Data (needed for tarballs). stderr is always streamed to `onStderrLine`
    /// if given and collected as text.
    @discardableResult
    static func run(_ argv: [String],
                    stdin: Data? = nil,
                    interactiveStdin: Bool = false,
                    cwd: String? = nil,
                    extraEnv: [String: String] = [:],
                    timeout: TimeInterval? = nil,
                    onStdoutLine: ((String) -> Void)? = nil,
                    onStderrLine: ((String) -> Void)? = nil,
                    register: ((RunningProcess) -> Void)? = nil,
                    check: Bool = true) async throws -> ProcessResult {
        guard let bin = argv.first else { throw ProcessError(command: "", status: -1, stderr: "empty argv") }
        guard let exe = which(bin) else { throw NotFoundError(binary: bin) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        var env = environment
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe: Pipe? = (stdin != nil || interactiveStdin) ? Pipe() : nil
        p.standardInput = inPipe ?? FileHandle.nullDevice

        try p.run()
        register?(RunningProcess(p, stdin: interactiveStdin ? inPipe?.fileHandleForWriting : nil))

        // Guard against a wedged child (e.g. tsh blocked on a credential lock)
        // so callers never hang forever with no feedback.
        var timedOut = false
        let timeoutItem: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
            timeoutItem = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        } else {
            timeoutItem = nil
        }
        defer { timeoutItem?.cancel() }

        if let stdin, let inPipe, !interactiveStdin {
            Task.detached {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        // Read on plain background threads, NOT FileHandle.bytes (AsyncBytes):
        // AsyncBytes stops delivering once we write to the child's stdin, which
        // deadlocks the interactive permission protocol. A blocking
        // availableData loop keeps working while we write.
        let outReader = StreamReader(outPipe.fileHandleForReading, collectRaw: onStdoutLine == nil, onLine: onStdoutLine)
        let errReader = StreamReader(errPipe.fileHandleForReading, collectRaw: false, onLine: onStderrLine, capText: 64 * 1024)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); cont.resume() }
        }
        let outData = outReader.finish()
        let errText = errReader.finishText()

        if timedOut {
            throw ProcessError(command: argv.prefix(3).joined(separator: " "), status: -1,
                               stderr: "timed out after \(Int(timeout ?? 0))s (tsh may be waiting on a credential lock — is another tsh command running?)")
        }
        let res = ProcessResult(status: p.terminationStatus, stdout: outData, stderr: errText)
        if check && !res.ok {
            throw ProcessError(command: argv.prefix(3).joined(separator: " "), status: res.status, stderr: errText)
        }
        return res
    }

    /// Single-quotes s for a POSIX shell.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // (StreamReader lives below.)

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: #"\u{1b}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }
}

/// Reads a FileHandle to EOF on a background thread with a blocking
/// availableData loop, splitting into newline-delimited lines. Unlike
/// FileHandle.bytes (AsyncBytes) it keeps delivering while the parent writes
/// to the child's stdin, which the interactive permission protocol needs.
final class StreamReader {
    private let lock = NSLock()
    private let doneSem = DispatchSemaphore(value: 0)
    private var raw = Data()
    private var text = ""
    private let collectRaw: Bool
    private let capText: Int

    init(_ handle: FileHandle, collectRaw: Bool, onLine: ((String) -> Void)?, capText: Int = 0) {
        self.collectRaw = collectRaw
        self.capText = capText
        Thread.detachNewThread { [self] in
            var buf = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if collectRaw { lock.lock(); raw.append(chunk); lock.unlock() }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let s = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                    buf.removeSubrange(buf.startIndex...nl)
                    if capText > 0 { appendText(s) }
                    onLine?(s)
                }
            }
            // trailing partial line
            if !buf.isEmpty {
                let s = String(decoding: buf, as: UTF8.self)
                if capText > 0 { appendText(s) }
                onLine?(s)
            }
            doneSem.signal()
        }
    }

    /// Waits for EOF and returns the raw bytes (empty unless collectRaw).
    func finish() -> Data {
        doneSem.wait()
        lock.lock(); defer { lock.unlock() }
        return raw
    }

    func finishText() -> String {
        doneSem.wait()
        lock.lock(); defer { lock.unlock() }
        return text
    }

    /// Records a line into the capped text buffer (used for stderr).
    func appendText(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        text += line + "\n"
        if capText > 0 && text.count > capText { text = String(text.suffix(capText / 2)) }
    }
}
