import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Result

/// Outcome of one bounded, best-effort shell-out.
///
/// There is no error case. Detection is not an exceptional path: a binary that
/// is missing, wedged, or that answers with garbage is an ordinary Tuesday on a
/// stranger's Mac, and the probe must be able to say "unknown" and move on.
public struct ProbeCommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    /// True when the deadline expired and we killed the child. `exitCode` is
    /// meaningless in that case.
    public var timedOut: Bool

    public init(exitCode: Int32, standardOutput: String, standardError: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var succeeded: Bool { !timedOut && exitCode == 0 }

    /// First non-empty line of stdout (falling back to stderr), trimmed.
    ///
    /// `--version` output is one line on every CLI we care about, but some
    /// wrappers print an update banner first, so take the first line with
    /// content rather than the whole buffer.
    public var firstOutputLine: String? {
        for stream in [standardOutput, standardError] {
            for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

// MARK: - Protocol

/// Runs an external binary with a hard deadline.
///
/// Injected so the setup tests can exercise the probe's decisions without a
/// single real process on the machine.
public protocol ProbeCommandRunning: Sendable {
    /// - Returns: `nil` when the process could not be launched at all (the
    ///   binary is missing, is not executable, or the kernel refused). A launched
    ///   process that failed, hung, or was killed still returns a result.
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> ProbeCommandResult?
}

public extension ProbeCommandRunning {
    /// 4s is the working budget for a `--version` call. Measured intent, not
    /// measured fact: every CLI here answers in well under a second when healthy,
    /// so anything past 4s is a wedged install and we would rather report
    /// "unknown version" than stall an install screen.
    func run(executable: URL, arguments: [String]) async -> ProbeCommandResult? {
        await run(executable: executable, arguments: arguments, timeout: 4)
    }
}

// MARK: - Implementation

/// `Process`-backed runner that cannot outlive its deadline.
///
/// Three deliberate defences, each of which has a real failure behind it:
///
///  1. **stdin is `/dev/null`.** A CLI that decides it needs to ask the owner a
///     question gets EOF instead of a terminal, so it exits rather than blocking
///     forever on a read. This is the difference between "Codex isn't signed in"
///     and an install screen that never appears.
///  2. **Output is drained by readability handlers, never by a blocking read.**
///     A 64 KB pipe buffer is enough to deadlock a chatty child against a parent
///     that only reads after `waitUntilExit`. We never call
///     `readDataToEndOfFile()`, because a grandchild holding the write end means
///     EOF never arrives.
///  3. **SIGTERM, then SIGKILL.** `Process.terminate()` is polite and ignorable.
public struct ProbeCommandRunner: ProbeCommandRunning {
    /// Anything past this is a runaway or a hostile binary; truncate rather than
    /// letting a probe hold megabytes of someone's log spew.
    public static let maximumCapturedBytes = 64 * 1024

    /// How long a terminated child gets to die politely before SIGKILL.
    private static let terminationGraceSeconds: TimeInterval = 0.5

    /// Poll interval for the deadline loop. Fine-grained enough that a fast
    /// binary is not artificially delayed, coarse enough not to spin a core.
    private static let pollIntervalNanoseconds: UInt64 = 20_000_000

    /// Time given to the readability handlers to flush after the child exits.
    private static let drainSeconds: TimeInterval = 0.05

    public init() {}

    public func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> ProbeCommandResult? {
        guard executable.isFileURL else {
            return nil
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardOutput = ProbeOutputBuffer(limit: Self.maximumCapturedBytes)
        let standardError = ProbeOutputBuffer(limit: Self.maximumCapturedBytes)

        standardOutputPipe.fileHandleForReading.readabilityHandler = { handle in
            standardOutput.append(handle.availableData)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { handle in
            standardError.append(handle.availableData)
        }
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
        } catch {
            standardOutputPipe.fileHandleForReading.readabilityHandler = nil
            standardErrorPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let timedOut = await Self.wait(for: process, timeout: timeout)

        // Let the dispatch sources deliver whatever is already buffered. A short
        // fixed sleep, not a read: a read could block forever.
        try? await Task.sleep(nanoseconds: UInt64(Self.drainSeconds * 1_000_000_000))
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        try? standardOutputPipe.fileHandleForReading.close()
        try? standardErrorPipe.fileHandleForReading.close()

        // `terminationStatus` traps if consulted while the child is still alive,
        // which can happen if even SIGKILL has not been reaped yet.
        let exitCode: Int32 = process.isRunning ? -1 : process.terminationStatus

        return ProbeCommandResult(
            exitCode: exitCode,
            standardOutput: standardOutput.stringValue(),
            standardError: standardError.stringValue(),
            timedOut: timedOut
        )
    }

    /// - Returns: `true` when the deadline (or cancellation) forced the kill.
    private static func wait(for process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline {
                escalate(process)
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return false
    }

    /// SIGTERM, a grace period, then SIGKILL. A CLI that installs a SIGTERM
    /// handler and then hangs inside it is exactly the case that would otherwise
    /// wedge the probe forever.
    private static func escalate(_ process: Process) {
        process.terminate()

        let graceDeadline = Date().addingTimeInterval(terminationGraceSeconds)
        while process.isRunning && Date() < graceDeadline {
            // Synchronous sleep: this path is already a failure and the window is
            // half a second. Doing it with `await` here would let a cancelled
            // task skip the escalation and leak the process.
            usleep(20_000)
        }

        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0 {
            kill(pid, SIGKILL)
        }
        let reapDeadline = Date().addingTimeInterval(terminationGraceSeconds)
        while process.isRunning && Date() < reapDeadline {
            usleep(20_000)
        }
    }
}

/// Thread-safe, size-capped accumulator for pipe output.
///
/// The readability handlers fire on a private dispatch queue, so the buffer is
/// touched from a thread other than the one awaiting the deadline.
private final class ProbeOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(chunk.prefix(limit - data.count))
    }

    func stringValue() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Executable lookup

/// Finds binaries without shelling out.
///
/// `which` is itself a process launch, and on a machine where the probe is
/// trying to decide whether anything is installed, launching a process to find
/// out is both slower and more fragile than reading `PATH` ourselves. Same
/// approach `LocalASRDiscovery` takes for `whisper-cli`.
public enum ExecutableLookup {
    /// First entry on `PATH` that is an executable file named `name`.
    public static func onPath(
        _ name: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL? {
        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// `PATH` first, then the well-known install locations.
    ///
    /// `PATH` wins because if the owner has two copies, the one they can type is
    /// the one they think they have.
    public static func find(
        names: [String],
        extraCandidates: [URL] = [],
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL? {
        for name in names {
            if let found = onPath(name, environment: environment, fileManager: fileManager) {
                return found
            }
        }
        return extraCandidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
