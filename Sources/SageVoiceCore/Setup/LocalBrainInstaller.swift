import Foundation

/// Gets a local brain working, and says what it is doing while it does.
///
/// This is the missing half of "Fully on this Mac". `EnvironmentProbe` could
/// already see that the runtime or the model was absent, and `BrainSetupPlanner`
/// could explain why the option was unavailable — but nothing in the product
/// could *act* on it, so the one choice that keeps the owner's words on their
/// machine was permanently greyed out behind a reason amounting to "go and do
/// this yourself in a terminal".
///
/// ## Why this can install a runtime when the SAGE installer cannot
///
/// `SageNodeInstaller` downloads and then hands over, because a `.app` needs to
/// reach `/Applications`, which needs admin, and a bundle fetched by a
/// background process carries `com.apple.quarantine`.
///
/// Ollama does not have that problem, and SAGE already proved it: its own
/// `internal/ollamad` fetches a pinned `ollama-darwin.tgz` into
/// `~/.sage/data/ollama` and runs it as a loopback sidecar. A CLI binary in the
/// app's own container is not an app bundle, needs no admin, and is not subject
/// to Gatekeeper's app translocation. So the whole thing can happen inside the
/// setup screen with a progress bar, which is what the owner asked for.
///
/// ## What it deliberately does not do
///
/// It never adopts a runtime it did not install *and* never installs one that is
/// already there. A healthy loopback API is the source of truth — the same rule
/// `ollamad.Manager` uses — so an owner who already runs Ollama gets their own,
/// and nobody ends up with two.
public actor LocalBrainInstaller {

    /// What the owner is waiting for, in terms a progress view can render.
    public enum Phase: Sendable, Equatable {
        case idle
        /// Fetching the runtime. ~129 MB.
        case downloadingRuntime(completedBytes: Int64, totalBytes: Int64?)
        case startingRuntime
        /// Fetching the model. ~3.4 GB, and the long pole by an order of
        /// magnitude.
        case downloadingModel(status: String, completedBytes: Int64?, totalBytes: Int64?)
        /// Fetching SAGE's semantic-memory model. ~274 MB.
        case downloadingEmbeddingModel(status: String, completedBytes: Int64?, totalBytes: Int64?)
        case verifyingModels
        /// Loaded and answering. Reached only after a real request succeeds.
        case ready
        case failed(String)

        public var isFinished: Bool {
            switch self {
            case .ready, .failed: return true
            case .idle, .downloadingRuntime, .startingRuntime, .downloadingModel,
                    .downloadingEmbeddingModel, .verifyingModels:
                return false
            }
        }

        /// 0–1 across the whole job, or `nil` when the current step cannot say.
        ///
        /// Weighted by bytes rather than by step count, because the two steps
        /// differ by a factor of 26 and a bar that sat at 50% through the model
        /// pull would be lying about the half that matters.
        public var fraction: Double? {
            let runtimeShare = Double(LocalBrainModelCatalog.approximateRuntimeDownloadBytes)
            let modelShare = Double(LocalBrainModelCatalog.approximateModelDownloadBytes)
            let embeddingShare = Double(LocalBrainModelCatalog.approximateEmbeddingModelDownloadBytes)
            let total = runtimeShare + modelShare + embeddingShare
            let downloadPortion = 0.99

            switch self {
            case .idle:
                return 0
            case .downloadingRuntime(let done, let expected):
                let of = Double(expected ?? LocalBrainModelCatalog.approximateRuntimeDownloadBytes)
                guard of > 0 else { return nil }
                return (Double(done) / of) * (runtimeShare / total) * downloadPortion
            case .startingRuntime:
                return runtimeShare / total * downloadPortion
            case .downloadingModel(_, let done, let expected):
                let of = Double(expected ?? LocalBrainModelCatalog.approximateModelDownloadBytes)
                guard let done, of > 0 else { return runtimeShare / total * downloadPortion }
                return (runtimeShare + Double(done) / of * modelShare) / total * downloadPortion
            case .downloadingEmbeddingModel(_, let done, let expected):
                let of = Double(expected ?? LocalBrainModelCatalog.approximateEmbeddingModelDownloadBytes)
                let completedBefore = runtimeShare + modelShare
                guard let done, of > 0 else { return completedBefore / total * downloadPortion }
                return (completedBefore + Double(done) / of * embeddingShare) / total * downloadPortion
            case .verifyingModels:
                return downloadPortion
            case .ready:
                return 1
            case .failed:
                return nil
            }
        }

        /// One sentence for the owner. Says what is happening, not which API is
        /// being called.
        public var sentence: String {
            switch self {
            case .idle:
                return "Ready to set up."
            case .downloadingRuntime:
                return "Getting the software that runs the brain…"
            case .startingRuntime:
                return "Starting it up…"
            case .downloadingModel:
                // Never the digest. Ollama's status line for the bulk of the
                // pull is "pulling 61aa3858e9d3", which means nothing to anyone.
                return "Downloading the brain — this is the big one, a few gigabytes."
            case .downloadingEmbeddingModel:
                return "Getting the memory model…"
            case .verifyingModels:
                return "Checking that the brain and memory can answer…"
            case .ready:
                return "Ready. Nothing you say will leave this Mac."
            case .failed(let reason):
                return reason
            }
        }
    }

    private let client: OllamaClient
    private let model: String
    private let embeddingModel: String
    private let runtime: OllamaRuntimeInstalling

    public init(
        client: OllamaClient = OllamaClient(),
        model: String = LocalBrainModelCatalog.preferredModel,
        embeddingModel: String = LocalBrainModelCatalog.embeddingModel,
        runtime: OllamaRuntimeInstalling = OllamaRuntimeInstaller.shared
    ) {
        self.client = client
        self.model = model
        self.embeddingModel = embeddingModel
        self.runtime = runtime
    }

    /// Runs the whole job, reporting each phase.
    ///
    /// Idempotent and resumable in the only sense that matters: every step
    /// checks whether it is already done. An interrupted 3.4 GB pull resumes
    /// from Ollama's own partial layers on the next attempt, so "try again"
    /// costs the owner the remainder rather than the whole thing.
    ///
    /// - Returns: `true` when a local turn could be served now.
    @discardableResult
    public func install(onPhase: @Sendable (Phase) -> Void = { _ in }) async -> Bool {
        do {
            if await !client.isReachable() {
                onPhase(.downloadingRuntime(completedBytes: 0, totalBytes: nil))
                try await runtime.install { done, total in
                    onPhase(.downloadingRuntime(completedBytes: done, totalBytes: total))
                }
                onPhase(.startingRuntime)
                try await runtime.start()
                guard await client.isReachable(timeoutSeconds: 30) else {
                    onPhase(.failed("The brain software started but is not answering."))
                    return false
                }
            }

            if try await !hasModel() {
                onPhase(.downloadingModel(status: "", completedBytes: nil, totalBytes: nil))
                try await client.pull(model: model) { progress in
                    onPhase(.downloadingModel(
                        status: progress.status,
                        completedBytes: progress.completedBytes,
                        totalBytes: progress.totalBytes
                    ))
                }
            }

            if try await !hasEmbeddingModel() {
                onPhase(.downloadingEmbeddingModel(status: "", completedBytes: nil, totalBytes: nil))
                try await client.pull(model: embeddingModel) { progress in
                    onPhase(.downloadingEmbeddingModel(
                        status: progress.status,
                        completedBytes: progress.completedBytes,
                        totalBytes: progress.totalBytes
                    ))
                }
            }

            onPhase(.verifyingModels)
            // Reachable plus pulled is still not "works": models on disk that
            // the runtime cannot load fails at the first real request, which on
            // a voice turn is dead air. So the finish line is a served request.
            guard try await hasModel(), try await hasEmbeddingModel() else {
                onPhase(.failed("The brain finished downloading but is not usable."))
                return false
            }
            _ = try await client.chat(
                model: model,
                messages: [BrainMessage(role: .user, content: "Reply with OK.")],
                temperature: 0,
                think: .off,
                keepAlive: "5m",
                numPredict: 2
            )
            let dimensions = try await client.embeddingDimensions(
                model: embeddingModel,
                input: "Mynah local memory readiness probe"
            )
            guard dimensions == LocalBrainModelCatalog.embeddingDimensions else {
                onPhase(.failed(
                    "The memory model returned \(dimensions) values instead of "
                        + "\(LocalBrainModelCatalog.embeddingDimensions)."
                ))
                return false
            }
            onPhase(.ready)
            return true
        } catch {
            onPhase(.failed(Self.explain(error)))
            return false
        }
    }

    private func hasModel() async throws -> Bool {
        let installed = try await client.listModels()
        return has(model, in: installed)
    }

    private func hasEmbeddingModel() async throws -> Bool {
        let installed = try await client.listModels()
        return has(embeddingModel, in: installed)
    }

    private func has(_ expected: String, in installed: [String]) -> Bool {
        let key = LocalBrainModelCatalog.normalize(expected)
        return installed.contains { LocalBrainModelCatalog.normalize($0) == key }
    }

    /// Turns a thrown error into something worth reading on a setup screen.
    ///
    /// The owner is mid-install and cannot act on a URLError code. Disk and
    /// network are the two they *can* act on, so those are named and everything
    /// else says plainly that it failed rather than pretending to diagnose.
    static func explain(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                return "The download stopped — this Mac lost its internet connection. Try again."
            case .timedOut:
                return "The download timed out. Try again."
            default:
                break
            }
        }
        let text = "\(error)"
        if text.localizedCaseInsensitiveContains("no space") {
            return "There is not enough free space on this Mac to finish the download."
        }
        return "The brain could not be set up: \(text)"
    }
}

/// Fetching and starting the Ollama runtime.
///
/// A protocol because it is the half that touches the network and the
/// filesystem, and `LocalBrainInstaller`'s sequencing — the part with the
/// decisions in it — should be testable without either.
public protocol OllamaRuntimeInstalling: Sendable {
    func install(onProgress: @Sendable (Int64, Int64?) -> Void) async throws
    func start() async throws
}

/// Installs and owns Mynah's loopback Ollama sidecar.
///
/// This deliberately uses the exact release, size and digest SAGE's
/// `internal/ollamad` pins. The archive never becomes executable until all
/// three match, its member paths are checked before extraction, and the final
/// directory is installed with one rename. An interrupted install therefore
/// leaves either the old complete runtime or a disposable `.part` directory,
/// never a half-runtime that looks installed.
public final class OllamaRuntimeInstaller: OllamaRuntimeInstalling, @unchecked Sendable {
    public static let shared = OllamaRuntimeInstaller()

    public static let release = "v0.31.1"
    public static let archiveByteCount: Int64 = 129_037_451
    public static let archiveSHA256 =
        "0c4f92389fcc1f651c17282e2eaffd68c8d3d06e1f7b307604102ad0e09a10c9"
    public static let archiveURL = URL(
        string: "https://github.com/ollama/ollama/releases/download/"
            + "\(release)/ollama-darwin.tgz"
    )!

    private let session: URLSession
    private let fileManager: FileManager
    private let supportDirectory: URL
    private let assetURL: URL
    private let expectedBytes: Int64
    private let expectedSHA256: String
    private let stateLock = NSLock()
    private var process: Process?
    private var logSink: FileHandle?

    public convenience init() {
        self.init(
            session: .shared,
            fileManager: .default,
            supportDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/SAGE Voice Bridge",
                    isDirectory: true
                ),
            assetURL: Self.archiveURL,
            expectedBytes: Self.archiveByteCount,
            expectedSHA256: Self.archiveSHA256
        )
    }

    init(
        session: URLSession,
        fileManager: FileManager,
        supportDirectory: URL,
        assetURL: URL,
        expectedBytes: Int64,
        expectedSHA256: String
    ) {
        self.session = session
        self.fileManager = fileManager
        self.supportDirectory = supportDirectory
        self.assetURL = assetURL
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256
    }

    public func install(onProgress: @Sendable (Int64, Int64?) -> Void) async throws {
        if installedBinaryURL() != nil {
            onProgress(expectedBytes, expectedBytes)
            return
        }

        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let archive = runtimeRoot.appendingPathComponent("ollama-darwin.tgz.part")
        try? fileManager.removeItem(at: archive)
        onProgress(0, expectedBytes)

        var request = URLRequest(url: assetURL)
        request.timeoutInterval = 60 * 30
        request.setValue("Mynah-Runtime-Installer", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.downloadHTTP((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try fileManager.moveItem(at: temporary, to: archive)
        defer { try? fileManager.removeItem(at: archive) }

        let attributes = try fileManager.attributesOfItem(atPath: archive.path)
        let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualBytes == expectedBytes else {
            throw Failure.wrongSize(expected: expectedBytes, actual: actualBytes)
        }
        onProgress(actualBytes, expectedBytes)

        let actualSHA256 = try FileDigest.sha256Hex(ofFileAt: archive, fileManager: fileManager)
        guard actualSHA256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw Failure.checksumMismatch
        }

        let entries = try Self.run("/usr/bin/tar", arguments: ["-tzf", archive.path])
        try Self.validateArchiveEntries(entries)

        let staging = runtimeRoot.appendingPathComponent(
            "ollama-\(Self.release).part-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            _ = try Self.run(
                "/usr/bin/tar",
                arguments: ["-xzf", archive.path, "-C", staging.path]
            )
            guard let binary = binaryURL(under: staging) else {
                throw Failure.missingBinary
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: binary.path
            )
            try? fileManager.removeItem(at: engineDirectory)
            try fileManager.moveItem(at: staging, to: engineDirectory)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func start() async throws {
        if await OllamaClient().isReachable() {
            return
        }

        if withStateLock({ process?.isRunning == true }) {
            return
        }

        guard let binary = installedBinaryURL() else {
            throw Failure.missingBinary
        }
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let sink = try FileHandle(forWritingTo: logURL)
        try sink.seekToEnd()

        let child = Process()
        child.executableURL = binary
        child.arguments = ["serve"]
        child.standardOutput = sink
        child.standardError = sink
        child.environment = ProcessInfo.processInfo.environment.filter {
            $0.key != "OLLAMA_HOST" && $0.key != "OLLAMA_MODELS"
        }.merging([
            "OLLAMA_HOST": "127.0.0.1:11434",
            "OLLAMA_MODELS": modelDirectory.path
        ]) { _, managed in managed }

        child.terminationHandler = { [weak self, weak child] _ in
            guard let self else { return }
            self.stateLock.lock()
            if self.process === child {
                self.process = nil
                let oldSink = self.logSink
                self.logSink = nil
                self.stateLock.unlock()
                try? oldSink?.close()
                try? self.fileManager.removeItem(at: self.pidURL)
            } else {
                self.stateLock.unlock()
            }
        }

        do {
            try child.run()
        } catch {
            try? sink.close()
            throw Failure.couldNotStart(String(describing: error))
        }
        withStateLock {
            process = child
            logSink = sink
        }
        try Data("\(child.processIdentifier)\n".utf8).write(to: pidURL, options: .atomic)
    }

    var engineDirectory: URL {
        runtimeRoot.appendingPathComponent("ollama-\(Self.release)", isDirectory: true)
    }

    var modelDirectory: URL {
        supportDirectory.appendingPathComponent("Ollama/Models", isDirectory: true)
    }

    private var runtimeRoot: URL {
        supportDirectory.appendingPathComponent("Runtime", isDirectory: true)
    }

    private var logURL: URL {
        supportDirectory.appendingPathComponent("Logs/ollama.log")
    }

    private var pidURL: URL {
        supportDirectory.appendingPathComponent("Runtime/ollama.pid")
    }

    func installedBinaryURL() -> URL? {
        binaryURL(under: engineDirectory)
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func binaryURL(under root: URL) -> URL? {
        [
            root.appendingPathComponent("ollama"),
            root.appendingPathComponent("bin/ollama"),
            root.appendingPathComponent("ollama/ollama")
        ].first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Rejects absolute paths and any component that climbs above the staging
    /// directory. The pinned digest is the primary trust boundary; this is the
    /// second one that prevents an archive-tool regression becoming a write
    /// outside Application Support.
    static func validateArchiveEntries(_ listing: String) throws {
        for raw in listing.split(whereSeparator: \.isNewline) {
            let name = String(raw)
            let path = NSString(string: name).standardizingPath
            let components = path.split(separator: "/")
            if name.hasPrefix("/") || path == ".." || path.hasPrefix("../")
                || components.contains("..") {
                throw Failure.unsafeArchiveEntry(name)
            }
        }
    }

    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure.archiveTool(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    public enum Failure: LocalizedError, Equatable {
        case downloadHTTP(Int)
        case wrongSize(expected: Int64, actual: Int64)
        case checksumMismatch
        case unsafeArchiveEntry(String)
        case archiveTool(String)
        case missingBinary
        case couldNotStart(String)

        public var errorDescription: String? {
            switch self {
            case .downloadHTTP(let status):
                return "The Ollama runtime download returned HTTP \(status)."
            case .wrongSize(let expected, let actual):
                return "The Ollama runtime download was incomplete (\(actual) of \(expected) bytes)."
            case .checksumMismatch:
                return "The Ollama runtime failed its security check and was not installed."
            case .unsafeArchiveEntry:
                return "The Ollama runtime archive contained an unsafe path and was refused."
            case .archiveTool(let detail):
                return "The Ollama runtime could not be unpacked: \(detail)"
            case .missingBinary:
                return "The verified Ollama archive did not contain a runnable Ollama binary."
            case .couldNotStart(let detail):
                return "Ollama could not start: \(detail)"
            }
        }
    }
}
