import Foundation

/// Everything fixed at `claude` launch. A spare process is reusable only for a
/// request whose launch is identical; the system prompt is not part of it
/// because it travels in the initialize handshake.
struct ClaudeLaunch: Equatable, Sendable {
    let claudePath: String
    let path: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
}

/// One `claude -p` child with its pipes wired. Stdout is left unread until a
/// turn takes the child; stderr is drained from launch.
final class ClaudeChild: @unchecked Sendable {
    let launch: ClaudeLaunch
    let process: Process
    let stdin: FileHandle
    let stdout: FileHandle
    let stderrLog = OutputBuffer()
    let exit = ProcessExit()
    private let launchedAt = Date()
    private let stderr: FileHandle

    private init(launch: ClaudeLaunch) {
        self.launch = launch
        process = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        stdin = stdinPipe.fileHandleForWriting
        stdout = stdoutPipe.fileHandleForReading
        stderr = stderrPipe.fileHandleForReading
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    static func spawn(_ launch: ClaudeLaunch) throws -> ClaudeChild {
        let child = ClaudeChild(launch: launch)
        let process = child.process
        process.executableURL = URL(fileURLWithPath: launch.claudePath)
        process.arguments = launch.arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = launch.path
        // Stops the CLI building a file attachment out of an `@path` in message
        // text at all, rather than letting one be built and then refused.
        env["CLAUDE_CODE_DISABLE_ATTACHMENTS"] = "1"
        env.merge(launch.environment) { _, override in override }
        process.environment = env
        process.currentDirectoryURL = launch.workingDirectory

        // Set before run() so an immediate exit cannot be missed.
        let exit = child.exit
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        try process.run()

        // Drain stderr for the life of the process. Reading it only after exit
        // deadlocks the turn once the child fills the 64 KB pipe buffer.
        let log = child.stderrLog
        child.stderr.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            log.append(chunk)
        }
        return child
    }

    func isFresh(maxAge: TimeInterval) -> Bool {
        process.isRunning && Date().timeIntervalSince(launchedAt) < maxAge
    }

    func stopReadingStderr() {
        stderr.readabilityHandler = nil
    }

    func discard() {
        stopReadingStderr()
        try? stdin.close()
        if process.isRunning { process.terminate() }
    }
}

/// Serves requests that opt in with `keep_warm`: keeps one booted `claude -p`
/// (about 230 MB) waiting for the most recent warm launch, so the turn skips
/// the CLI's startup. The spare is replaced after every use and retired after
/// `maxSpareAge` idle, so a CLI update or re-login is picked up.
final class ClaudeProcessPool: @unchecked Sendable {
    static let shared = ClaudeProcessPool()

    private static let maxSpareAge: TimeInterval = 300
    private let lock = NSLock()
    private var spare: ClaudeChild?

    var spareProcessID: Int32? {
        lock.lock(); defer { lock.unlock() }
        return spare?.process.processIdentifier
    }

    func take(_ launch: ClaudeLaunch) throws -> ClaudeChild {
        lock.lock()
        let candidate = spare
        spare = nil
        lock.unlock()

        let child: ClaudeChild
        if let candidate, candidate.launch == launch, candidate.isFresh(maxAge: Self.maxSpareAge) {
            child = candidate
        } else {
            candidate?.discard()
            child = try ClaudeChild.spawn(launch)
        }
        replenish(launch)
        return child
    }

    private func replenish(_ launch: ClaudeLaunch) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let fresh = try? ClaudeChild.spawn(launch) else { return }
            lock.lock()
            let replaced = spare
            spare = fresh
            lock.unlock()
            replaced?.discard()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.maxSpareAge) { [self] in
                lock.lock()
                let expired = spare === fresh
                if expired { spare = nil }
                lock.unlock()
                if expired { fresh.discard() }
            }
        }
    }
}

/// Awaits a child process's exit status without blocking a thread.
///
/// `Process.waitUntilExit()` cannot be used here: it blocks, and called from a
/// Swift concurrency task it occupies a cooperative-pool thread. It was also
/// observed hanging permanently on an already-reaped child — roughly one request
/// in twenty never returned, leaving the caller waiting on a response forever.
final class ProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func finish(_ value: Int32) {
        lock.lock()
        guard status == nil else { lock.unlock(); return }
        status = value
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Accumulates a child process's output from the pipe's read queue.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
