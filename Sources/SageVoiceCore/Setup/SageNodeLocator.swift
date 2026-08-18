import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// Finds the SAGE node this appliance should talk to, and starts it.
///
/// ## Why there is no "install SAGE" step
///
/// SAGE ships inside this app, vendored at build time into
/// `Contents/Resources/SAGE.app` and codesigned as part of our bundle. That is
/// the arrangement QuietType already ships, and it is deliberate:
///
///  - A vendored bundle inherits this app's notarization, so it launches with
///    no Gatekeeper prompt and nothing for the owner to approve.
///  - An app downloaded at runtime and copied into `/Applications` carries a
///    `com.apple.quarantine` flag, needs privileges we would have to ask for,
///    and is exactly the shape a user is right to be suspicious of.
///
/// So the normal path is: the node is already here, start it. Downloading is a
/// fallback for a build that was not vendored, and even then this type does not
/// silently install — see `SageNodeInstaller`.
public enum SageNodeLocator {
    /// Executable name inside a SAGE app bundle.
    public static let executableName = "sage-gui"

    /// The bundle identifier a genuine SAGE.app carries. Checked before we run
    /// anything, so a stray directory of the right name cannot get executed.
    public static let expectedBundleIdentifier = "com.sage.brain"

    /// `SAGE.app` vendored inside the running app's `Resources`.
    ///
    /// `nil` under `swift test` and for the CLI harness, where there is no app
    /// bundle — which is correct, not a failure.
    public static func vendoredExecutableURL(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let candidate = resources
            .appendingPathComponent("SAGE.app/Contents/MacOS/\(executableName)")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Verifies that a path really is a SAGE app bundle before we run it.
    ///
    /// Mirrors `require_sage_app` in QuietType's vendoring script. The bundle-id
    /// check is the one that matters: everything else confirms the layout, but
    /// only this confirms identity.
    public static func verifyBundle(
        at appURL: URL,
        fileManager: FileManager = .default
    ) -> Result<URL, SageNodeError> {
        let executable = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        let plist = appURL.appendingPathComponent("Contents/Info.plist")

        guard fileManager.fileExists(atPath: appURL.path) else {
            return .failure(.notFound(appURL.path))
        }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            return .failure(.notRunnable(executable.path))
        }
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return .failure(.malformedBundle("missing or unreadable Info.plist at \(plist.path)"))
        }
        let identifier = info["CFBundleIdentifier"] as? String
        guard identifier == expectedBundleIdentifier else {
            return .failure(.unexpectedBundleIdentifier(
                found: identifier ?? "none",
                expected: expectedBundleIdentifier
            ))
        }
        return .success(executable)
    }

    /// Bundle version string, for reporting which node we are about to run.
    public static func bundleVersion(at appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return nil
        }
        return info["CFBundleShortVersionString"] as? String
    }

    /// The app bundle containing an executable path, or `nil` if it is a bare
    /// binary on `PATH` rather than something in a bundle.
    public static func appBundle(containing executable: URL) -> URL? {
        // …/SAGE.app/Contents/MacOS/sage-gui -> …/SAGE.app
        let bundle = executable
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // SAGE.app
        return bundle.pathExtension == "app" ? bundle : nil
    }
}

public enum SageNodeError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case notRunnable(String)
    case malformedBundle(String)
    case unexpectedBundleIdentifier(found: String, expected: String)
    case launchFailed(String)
    /// Something is installed there, and it would not say it is SAGE.
    ///
    /// The refusal exists so the alternative cannot happen: running any
    /// executable that happens to be called `sage` as the owner's memory. On a
    /// Linux box that is a real collision — SageMath installs one.
    case unprovenExecutable(path: String, evidence: String)
    /// Nothing found anywhere, with the list of everywhere.
    case noNodeInstalled(searched: [String])

    public var description: String {
        switch self {
        case .notFound(let path):
            return "No SAGE app bundle at \(path)."
        case .notRunnable(let path):
            return "SAGE bundle is not runnable; no executable at \(path)."
        case .malformedBundle(let detail):
            return "SAGE bundle is malformed: \(detail)"
        case .unexpectedBundleIdentifier(let found, let expected):
            return "Refusing to run \(found.isEmpty ? "an unidentified bundle" : found) as SAGE; expected \(expected)."
        case .launchFailed(let detail):
            return "Could not start the SAGE node: \(detail)"
        case .unprovenExecutable(let path, let evidence):
            return "Found \(path), but it did not identify itself as SAGE: \(evidence). "
                + "Refusing to run an unidentified binary as your memory \u{2014} "
                + "point Mynah at the right one with `sage-voiced --sage /path/to/sage`."
        case .noNodeInstalled(let searched):
            return "No SAGE node found. Mynah does not install one for you here: get it from "
                + "\(SageNodeInstaller.releasesPageURL.absoluteString), then either put `sage` on "
                + "PATH or start the daemon with `sage-voiced --sage /path/to/sage`. Looked in: "
                + searched.joined(separator: ", ") + "."
        }
    }
}

// MARK: - Finding a SAGE the owner installed themselves

/// Off-Darwin there is no app bundle to find, and no bundled node to fall back
/// on either.
///
/// The owner's rule for Linux is that **they** install SAGE and Mynah finds it;
/// nothing is vendored there. So both halves of the macOS check — "is there a
/// `SAGE.app` in one of the two Applications folders?" and "what does its
/// `Info.plist` say?" — have no answer on a Linux box, and asking them anyway is
/// how the daemon came to die naming
/// `/Applications/SAGE.app/Contents/MacOS/sage-gui` on a machine with a
/// perfectly good `sage` on `PATH`.
///
/// ## One search, not a third one
///
/// `EnvironmentProbe.probeSage` has always searched the right places. The
/// product therefore shipped **two** detectors that disagreed: setup printed
/// one answer and the daemon died naming another. The lists below are that
/// search, hoisted to one place so it can be shared rather than copied —
/// `SageNodeChoiceLinuxTests.testBothDetectorsSearchTheSamePlaces` reads
/// `EnvironmentProbe.swift` and fails if its literals ever drift from these.
public extension SageNodeLocator {

    /// Executable names a SAGE install goes by, in preference order.
    static let installedExecutableNames = ["sage", "sage-gui", "sagectl", "saged"]

    /// Home-relative install locations, searched after `PATH`.
    ///
    /// The last entry is the macOS bundle layout, and it stays in the list on
    /// every platform because that is where somebody who unpacked a Mac build
    /// into their home directory put it — the probe has always looked there.
    static let installedHomeRelativePaths = [
        ".sage/bin/sage",
        ".sage/bin/sage-gui",
        "go/bin/sage",
        ".local/bin/sage",
        "Applications/SAGE.app/Contents/MacOS/sage-gui"
    ]

    /// Everything that is looked at after `PATH`, in order.
    ///
    /// `EnvironmentProbe.defaultSystemBinaryDirectories` rather than a private
    /// copy of it, so a directory added there is added to both detectors at
    /// once.
    static func installedSearchCandidates(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var candidates = installedHomeRelativePaths.map(homeDirectory.appendingPathComponent)
        for directory in EnvironmentProbe.defaultSystemBinaryDirectories {
            candidates.append(
                contentsOf: installedExecutableNames.map(directory.appendingPathComponent)
            )
        }
        return candidates
    }

    /// The user-installed SAGE, or `nil`.
    ///
    /// `PATH` first — if the owner has two copies, the one they can type is the
    /// one they think they have — then the well-known locations. This is
    /// `ExecutableLookup.find`, the same call `EnvironmentProbe.locate` makes,
    /// with the same arguments.
    ///
    /// **Finding is not identifying.** The answer here is a path, not a
    /// promise: see `identify(executableAt:)`.
    static func locateInstalledExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        ExecutableLookup.find(
            names: installedExecutableNames,
            extraCandidates: installedSearchCandidates(homeDirectory: homeDirectory),
            environment: environment,
            fileManager: fileManager
        )
    }

    /// Everything the search found, in the order it found it.
    ///
    /// `locateInstalledExecutable` answers with the first of these, which is
    /// what the probe wants. The resolver wants the whole list, and the reason
    /// is the collision this file keeps coming back to: if SageMath's `sage` is
    /// first on `PATH` and the owner's real node is in `~/.sage/bin`, stopping
    /// at the first hit means refusing a machine that has a perfectly good SAGE
    /// on it. Refusing loudly is better than running SageMath as somebody's
    /// memory, but *finding the real one* is better than either.
    ///
    /// Same order and the same primitive as `ExecutableLookup.find`, which is
    /// pinned by `testTheFirstCandidateIsWhatTheProbeWouldHaveFound`.
    static func installedExecutableCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        var found: [URL] = []
        var seen: Set<String> = []

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            seen.insert(path)
            found.append(url)
        }

        for name in installedExecutableNames {
            if let onPath = ExecutableLookup.onPath(name, environment: environment, fileManager: fileManager) {
                add(onPath)
            }
        }
        for candidate in installedSearchCandidates(homeDirectory: homeDirectory)
        where fileManager.isExecutableFile(atPath: candidate.path) {
            add(candidate)
        }
        return found
    }

    /// Every place the search looked, for a failure message that names them.
    ///
    /// A "SAGE not found" that does not say where it looked leaves the owner
    /// guessing whether their install is in the wrong place or Mynah is broken.
    static func describeSearchedLocations(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        ["PATH (\(installedExecutableNames.joined(separator: ", ")))"]
            + installedSearchCandidates(homeDirectory: homeDirectory).map(\.path)
    }
}

// MARK: - Proving a bare binary really is SAGE

public extension SageNodeLocator {

    /// What SAGE's `version` subcommand printed, when the shape was SAGE's.
    struct VersionBanner: Sendable, Equatable {
        /// The name the binary calls itself, e.g. `sage-gui`. Deliberately not
        /// compared against the filename: a `sage` symlinked to `sage-gui`
        /// prints the latter and is still the owner's node.
        public let program: String
        /// The version token, e.g. `11.18.14`.
        public let version: String
        /// The whole line, so a refusal can quote what it actually saw.
        public let line: String

        public init(program: String, version: String, line: String) {
            self.program = program
            self.version = version
            self.line = line
        }
    }

    /// The argument that makes SAGE print its version.
    ///
    /// **`version`, not `--version`.** Measured against SAGE 11.18.14:
    /// `--version` is not a command — it prints `Unknown command: --version`
    /// followed by the whole usage banner. A check written against `--version`
    /// would therefore reject every genuine SAGE on the machine, which is worse
    /// than no check at all because it fails in the direction that looks like a
    /// finding.
    static let versionArgument = "version"

    /// How long a `version` call gets. It is a Go binary printing one line;
    /// measured at 0.07–0.34s on this machine. Anything past five seconds is a
    /// wedged or hostile binary and "unknown" is the right answer.
    static let versionProbeTimeoutSeconds: TimeInterval = 5

    /// What we learned by asking a binary who it is.
    ///
    /// Every non-`proven` case carries the evidence, because the whole point is
    /// that a refusal has to be able to say *why* rather than quietly moving on
    /// to the next candidate.
    enum IdentityEvidence: Sendable, Equatable {
        /// It answered, in SAGE's shape.
        case proven(VersionBanner)
        /// Nothing executable at that path.
        case notExecutable(String)
        /// The kernel refused to launch it.
        case couldNotRun(String)
        /// It never answered.
        case timedOut
        /// It answered with a failure. SageMath's `sage` lands here: it has no
        /// `version` subcommand and exits nonzero.
        case failed(exitCode: Int32, output: String)
        /// It exited cleanly and said something that is not a SAGE version
        /// line. A different program that happens to be called `sage`.
        case unrecognised(String)

        public var banner: VersionBanner? {
            if case .proven(let banner) = self { return banner }
            return nil
        }

        public var isProven: Bool { banner != nil }

        /// Quotable in a refusal. Says what was seen, never a verdict on it.
        public var evidence: String {
            switch self {
            case .proven(let banner):
                return "identified itself as \"\(banner.line)\""
            case .notExecutable(let path):
                return "nothing executable at \(path)"
            case .couldNotRun(let detail):
                return "it could not be launched (\(detail))"
            case .timedOut:
                return "`\(SageNodeLocator.versionArgument)` did not answer within "
                    + "\(Int(SageNodeLocator.versionProbeTimeoutSeconds))s"
            case .failed(let exitCode, let output):
                return "`\(SageNodeLocator.versionArgument)` exited \(exitCode)"
                    + (output.isEmpty ? "" : " saying \"\(output)\"")
            case .unrecognised(let output):
                return "`\(SageNodeLocator.versionArgument)` printed "
                    + (output.isEmpty ? "nothing" : "\"\(output)\"")
                    + ", which is not a SAGE version line"
            }
        }
    }

    /// A SAGE version line, or `nil` for anything else.
    ///
    /// ## What the check actually is
    ///
    /// A bare ELF binary has no `CFBundleIdentifier`, so the macOS proof does
    /// not exist off-Darwin. What SAGE does have is a distinctive version line:
    ///
    ///     sage-gui 11.18.14 (commit 5053ca0c, built 2026-08-16T04:48:49Z)
    ///
    /// The discriminator is **both `commit` and `built` on the first line**,
    /// after a bare program name. That pair is what keeps this honest, and the
    /// reason it has to be more than "the output mentions SAGE": *SageMath*
    /// installs a `sage` on `PATH` on exactly the kind of Linux box this runs
    /// on, and it answers `--version` with `SageMath version 10.3, Release
    /// Date: …`. A looser check would hand the owner's memory to a computer
    /// algebra system and every cheap test would pass.
    ///
    /// Deliberately tolerant about the version token itself — a SAGE built from
    /// source without the release ldflags prints something like `dev` there,
    /// and it is still the owner's node.
    static func parseVersionBanner(_ output: String) -> VersionBanner? {
        guard let line = firstNonEmptyLine(of: output) else { return nil }
        let lowered = line.lowercased()
        guard lowered.contains("commit"), lowered.contains("built") else { return nil }

        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }

        let program = String(fields[0])
        // A program name, not a sentence and not a path. "Error: /usr/bin/sage
        // could not be built from commit …" must not parse as one.
        guard !program.isEmpty,
              !program.contains("/"),
              !program.contains("\\"),
              !program.hasSuffix(":") else { return nil }

        return VersionBanner(program: program, version: String(fields[1]), line: line)
    }

    /// Asks a binary who it is, by running it.
    ///
    /// Safe to do, and checked rather than assumed: `version` on SAGE 11.18.14
    /// prints one line, exits 0, and leaves an empty `SAGE_HOME` empty. It
    /// starts no node and touches no chain.
    ///
    /// stdin is `/dev/null` so a binary that decides to ask for a vault
    /// passphrase gets EOF instead of a terminal and exits, rather than hanging
    /// the daemon's startup forever.
    static func identify(
        executableAt executable: URL,
        fileManager: FileManager = .default,
        timeout: TimeInterval = SageNodeLocator.versionProbeTimeoutSeconds
    ) -> IdentityEvidence {
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            return .notExecutable(executable.path)
        }

        // Keyed on size and modification date as well as path, so an upgraded
        // or replaced binary is asked again rather than answered from a stale
        // entry. `startIfNeeded` takes `resolve()` as a default argument, so
        // without this a supervision loop would launch a process per tick.
        let stamp = SageIdentityCache.stamp(of: executable, fileManager: fileManager)
        if let cached = SageIdentityCache.shared.value(forPath: executable.path, stamp: stamp) {
            return cached
        }

        let evidence = SageVersionProbe.run(executable, timeout: timeout)
        SageIdentityCache.shared.store(evidence, forPath: executable.path, stamp: stamp)
        return evidence
    }

    internal static func firstNonEmptyLine(of text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

// MARK: - The one synchronous shell-out

/// `ProbeCommandRunner` does this properly but it is `async`, and
/// `SageNodeChoice.resolve` is synchronous at every one of its call sites —
/// including default arguments, which cannot await. Bridging with a semaphore
/// would block a cooperative-pool thread on a task that needs that same pool,
/// which is a deadlock that appears under load and never in a test.
///
/// So: the same three defences, spelled synchronously.
///
///  1. stdin is `/dev/null`, so a prompt gets EOF rather than blocking forever.
///  2. Output is drained by readability handlers, never by a blocking read — a
///     64 KB pipe buffer is enough to deadlock a chatty child against a parent
///     that only reads after the child exits.
///  3. SIGTERM, then SIGKILL. `terminate()` is polite and ignorable.
private enum SageVersionProbe {

    static func run(_ executable: URL, timeout: TimeInterval) -> SageNodeLocator.IdentityEvidence {
        let process = Process()
        process.executableURL = executable
        process.arguments = [SageNodeLocator.versionArgument]
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = LockedBuffer()
        let errors = LockedBuffer()
        outputPipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        errorPipe.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return .couldNotRun("\(error)")
        }

        var timedOut = false
        if finished.wait(timeout: .now() + max(timeout, 0)) == .timedOut {
            timedOut = true
            escalate(process, waitingOn: finished)
        }

        // Let the dispatch sources deliver what is already buffered. A short
        // fixed wait, not a read: a read could block forever on a grandchild
        // holding the write end.
        Thread.sleep(forTimeInterval: 0.05)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()

        if timedOut { return .timedOut }

        // `terminationStatus` traps if the child has somehow not been reaped.
        let exitCode: Int32 = process.isRunning ? -1 : process.terminationStatus
        let standardOutput = output.text()
        let standardError = errors.text()

        guard exitCode == 0 else {
            let said = SageNodeLocator.firstNonEmptyLine(of: standardError)
                ?? SageNodeLocator.firstNonEmptyLine(of: standardOutput)
                ?? ""
            return .failed(exitCode: exitCode, output: said)
        }
        guard let banner = SageNodeLocator.parseVersionBanner(standardOutput) else {
            return .unrecognised(SageNodeLocator.firstNonEmptyLine(of: standardOutput) ?? "")
        }
        return .proven(banner)
    }

    private static func escalate(_ process: Process, waitingOn finished: DispatchSemaphore) {
        process.terminate()
        guard finished.wait(timeout: .now() + 0.5) == .timedOut else { return }
        let pid = process.processIdentifier
        if pid > 0 { posixKill(pid, SIGKILL) }
        _ = finished.wait(timeout: .now() + 0.5)
    }
}

/// Readability handlers fire on a private queue, so the buffer is touched from
/// a thread other than the one waiting on the deadline.
private final class LockedBuffer: @unchecked Sendable {
    private static let limit = 64 * 1024
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard data.count < Self.limit else { return }
        data.append(chunk.prefix(Self.limit - data.count))
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Remembers what each binary answered, for this process only.
///
/// Not a performance nicety: `SageNodeSupervisor.startIfNeeded` takes
/// `SageNodeChoice.resolve(...)` as a **default argument**, which is evaluated
/// on every call — including the calls that return `.alreadyRunning`. Without
/// this, a supervision loop would fork a `sage version` every tick.
private final class SageIdentityCache: @unchecked Sendable {
    static let shared = SageIdentityCache()

    private let lock = NSLock()
    private var entries: [String: (stamp: String, evidence: SageNodeLocator.IdentityEvidence)] = [:]

    /// Size and modification date. An upgrade or a replacement changes both, so
    /// a stale answer cannot survive one.
    static func stamp(of executable: URL, fileManager: FileManager) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: executable.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)@\(modified)"
    }

    func value(forPath path: String, stamp: String) -> SageNodeLocator.IdentityEvidence? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.stamp == stamp else { return nil }
        return entry.evidence
    }

    func store(_ evidence: SageNodeLocator.IdentityEvidence, forPath path: String, stamp: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = (stamp, evidence)
    }
}
