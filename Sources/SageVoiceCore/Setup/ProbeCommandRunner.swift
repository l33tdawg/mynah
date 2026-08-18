import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
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
            posixSleep(microseconds: 20_000)
        }

        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0 {
            posixKill(pid, SIGKILL)
        }
        let reapDeadline = Date().addingTimeInterval(terminationGraceSeconds)
        while process.isRunning && Date() < reapDeadline {
            posixSleep(microseconds: 20_000)
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

/// What "installed" means, spelled the way each platform actually spells it.
///
/// Four separate assumptions hide inside a `PATH` lookup — what separates the
/// entries, what the variable is called, what makes a file runnable, and
/// whether a program's name is its file's name. On UNIX all four are the same
/// assumption and it is right. On Windows all four are wrong, and they are
/// wrong in the same direction: the code compiles, runs, and confidently
/// reports "not installed" about a program sitting right there on `PATH`.
///
/// That is the worst shape a bug can take, because it reads as a *finding*. The
/// install screen tells the owner to go and install something they already
/// have, and nothing anywhere says otherwise.
///
/// Gathered in one type rather than solved at each call site, so the answer
/// cannot drift between the two places that ask it.
enum PlatformExecutable {

    /// An environment variable, looked up the way the platform names it.
    ///
    /// Windows environment names are case-*insensitive*, and the block the OS
    /// hands back spells this particular one `Path` — that is what `set` prints
    /// and what `Get-ChildItem Env:` shows. `ProcessInfo.environment` is a plain
    /// Swift `Dictionary`, which is case-*sensitive*, so `environment["PATH"]`
    /// comes back `nil` on a Windows machine whose `PATH` is perfectly healthy.
    ///
    /// UNIX names genuinely are case-sensitive — `Path` and `PATH` are two
    /// different variables there and conflating them would be its own bug — so
    /// the fallback scan is compiled only where it is correct, and an exact
    /// match still wins everywhere.
    static func environmentValue(_ name: String, in environment: [String: String]) -> String? {
        if let exact = environment[name] {
            return exact
        }
        #if os(Windows)
        // Windows will not let two names differ only in case, so "the first
        // case-insensitive match" is also "the only one".
        let wanted = name.lowercased()
        return environment.first { $0.key.lowercased() == wanted }?.value
        #else
        return nil
        #endif
    }

    /// The directories on `PATH`, in the order the platform searches them.
    static func searchPathDirectories(in environment: [String: String]) -> [String] {
        // `:` on every UNIX and `;` on Windows — see `PlatformPath`. Splitting a
        // Windows `PATH` on a colon cuts every entry in half at its drive
        // letter and reports "not installed" for a binary that is right there.
        (environmentValue("PATH", in: environment) ?? "")
            .split(separator: PlatformPath.searchPathSeparator)
            .map { unquoted(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// A Windows `PATH` entry is allowed to be quoted, because an unquoted one
    /// cannot contain the `;` that separates entries. The quotes are
    /// punctuation rather than part of the directory name, and a path built
    /// with them still in refers to nothing at all.
    private static func unquoted(_ directory: String) -> String {
        #if os(Windows)
        var trimmed = directory[...]
        while trimmed.first == "\"" { trimmed = trimmed.dropFirst() }
        while trimmed.last == "\"" { trimmed = trimmed.dropLast() }
        return String(trimmed)
        #else
        return directory
        #endif
    }

    /// The file names worth trying for a program the owner knows as `name`.
    ///
    /// Exactly one on UNIX, where a file is executable because of a permission
    /// bit and its name is whatever it is. On Windows a file is runnable
    /// because of its *extension*: `whisper-cli` names nothing and
    /// `whisper-cli.exe` names the program, and `PATHEXT` is the list of
    /// suffixes that count.
    ///
    /// The suffix is appended rather than substituted, so this is equally
    /// correct handed a bare program name or a whole path. A name that already
    /// carries a runnable extension is left alone.
    static func executableNameCandidates(for name: String, in environment: [String: String]) -> [String] {
        #if os(Windows)
        let extensions = pathExtensions(in: environment)
        let lowered = name.lowercased()
        if extensions.contains(where: { lowered.hasSuffix($0) }) {
            return [name]
        }
        // Deliberately no extension-less fallback: Windows cannot launch a file
        // without one, and `CreateProcess` appends `.exe` itself — so the `.exe`
        // candidate already covers the only case a bare name could have found.
        return extensions.map { name + $0 }
        #else
        return [name]
        #endif
    }

    /// The same list for a caller that has no injected environment.
    static func executableNameCandidates(for name: String) -> [String] {
        #if os(Windows)
        return executableNameCandidates(for: name, in: ProcessInfo.processInfo.environment)
        #else
        return [name]
        #endif
    }

    /// Whether the platform would actually run this file.
    ///
    /// UNIX keeps the answer it has always given — the execute bit, via
    /// `isExecutableFile` — so macOS and Linux are byte-for-byte unchanged.
    ///
    /// Windows has no execute bit, and `isExecutableFile` there is backed by
    /// `GetBinaryTypeW`, which reads the PE header and therefore answers
    /// **false** for a `.bat` or a `.cmd`. A `.cmd` shim is precisely how npm
    /// installs every CLI this probe hunts for, so believing it would report
    /// the SAGE node, Codex and Claude Code all missing on a machine where all
    /// three are installed and on `PATH`. Membership of `PATHEXT` is what
    /// "runnable" means there — the same rule the shell itself uses.
    static func isRunnableFile(
        atPath path: String,
        in environment: [String: String],
        fileManager: FileManager = .default
    ) -> Bool {
        #if os(Windows)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        let lowered = path.lowercased()
        return pathExtensions(in: environment).contains { lowered.hasSuffix($0) }
        #else
        return fileManager.isExecutableFile(atPath: path)
        #endif
    }

    /// The same question for a caller that has no injected environment.
    static func isRunnableFile(atPath path: String, fileManager: FileManager = .default) -> Bool {
        #if os(Windows)
        return isRunnableFile(atPath: path, in: ProcessInfo.processInfo.environment, fileManager: fileManager)
        #else
        return fileManager.isExecutableFile(atPath: path)
        #endif
    }

    #if os(Windows)
    /// `PATHEXT`, lower-cased and dot-prefixed.
    ///
    /// Defaulted to the four that are programs. Windows' real default also
    /// carries `.VBS`, `.JS`, `.WSF` and friends, but those are scripts a shell
    /// hands to an interpreter, and launching a `sage.vbs` somebody left lying
    /// on their `PATH` is not a decision to take on the owner's behalf.
    static func pathExtensions(in environment: [String: String]) -> [String] {
        let fallback = [".com", ".exe", ".bat", ".cmd"]
        let parsed = (environmentValue("PATHEXT", in: environment) ?? "")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count > 1 && $0.hasPrefix(".") }
        return parsed.isEmpty ? fallback : parsed
    }
    #endif
}

/// Finds binaries without shelling out.
///
/// `which` is itself a process launch, and on a machine where the probe is
/// trying to decide whether anything is installed, launching a process to find
/// out is both slower and more fragile than reading `PATH` ourselves. Same
/// approach `LocalASRDiscovery` takes for `whisper-cli`, and since both now go
/// through `PlatformExecutable`, the same answer.
public enum ExecutableLookup {
    /// First entry on `PATH` that is a runnable file named `name`.
    ///
    /// Every spelling of the name is tried within a directory before moving to
    /// the next directory, which is the order the Windows shell searches and a
    /// no-op on UNIX, where there is only ever one spelling.
    public static func onPath(
        _ name: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL? {
        let names = PlatformExecutable.executableNameCandidates(for: name, in: environment)
        for directory in PlatformExecutable.searchPathDirectories(in: environment) {
            let base = URL(fileURLWithPath: directory)
            for candidateName in names {
                let candidate = base.appendingPathComponent(candidateName)
                if PlatformExecutable.isRunnableFile(
                    atPath: candidate.path,
                    in: environment,
                    fileManager: fileManager
                ) {
                    return candidate
                }
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
        return extraCandidates.first {
            PlatformExecutable.isRunnableFile(atPath: $0.path, in: environment, fileManager: fileManager)
        }
    }
}
