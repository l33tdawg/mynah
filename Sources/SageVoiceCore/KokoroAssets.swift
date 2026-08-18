#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches the Kokoro voice model onto this Mac, once, in the background.
///
/// ## Why these are downloaded and the runtime is not
///
/// The split is a **signing** boundary, not a size one.
///
/// Everything executable that Mynah runs is bundled inside the app and signed
/// with it. Code downloaded after installation arrives unsigned and quarantined,
/// and asking the owner to clear Gatekeeper by hand for a voice is not a product.
/// Model weights are not code — they are opaque data that only ever reaches an
/// inference session — so they can be fetched later with nothing to sign and
/// nothing for Gatekeeper to have an opinion about.
///
/// That the data also happens to be the heavy part is a convenience rather than
/// the reason. 325 MB of weights and 28 MB of voices would nearly double the
/// DMG, and they would be paid for by every owner including the ones who never
/// link a phone.
///
/// The owner's instruction: *"if stuff is native - use native - package what we
/// need, install via github or wget whatever is too heavy to package
/// together"*, and on when: *"the signal part //call only comes in once you
/// link signal - download it then"*.
///
/// ## Why nothing here ever throws
///
/// This runs off the end of linking a phone, beside `CallEnrolment`. An
/// appliance that failed to finish linking because an optional voice could not
/// be downloaded would be trading the thing the owner asked for against the
/// thing they were in the middle of setting up. Every failure is a returned
/// `Outcome` that names itself in the log, and the appliance keeps the system
/// voice until the next attempt succeeds.
public enum KokoroAssets {

    /// One downloadable file, pinned by content rather than by trust.
    ///
    /// The digest is of the **file this Mac has been synthesizing with**, not one
    /// copied from a release page. A published checksum only proves the upload
    /// matches itself; this proves the bytes match the ones actually measured at
    /// real-time factor 0.16 on this hardware. `byteCount` is carried too so a
    /// truncated transfer is rejected before hashing 325 MB to learn the same
    /// thing.
    public struct Asset: Sendable, Equatable {
        public let name: String
        public let url: URL
        public let sha256: String
        public let byteCount: Int64

        public init(name: String, url: URL, sha256: String, byteCount: Int64) {
            self.name = name
            self.url = url
            self.sha256 = sha256
            self.byteCount = byteCount
        }
    }

    /// Verified against `/Users/l33tdawg/sage-voice-lab/kokoro` on 2026-07-29;
    /// the release URLs served exactly these byte counts on the same day.
    public static let model = Asset(
        name: "kokoro-v1.0.onnx",
        url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx")!,
        sha256: "7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5",
        byteCount: 325_532_387
    )

    public static let voices = Asset(
        name: "voices-v1.0.bin",
        url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin")!,
        sha256: "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d",
        byteCount: 28_214_398
    )

    public static var all: [Asset] { [model, voices] }

    /// Total bytes on the wire, for a caller that wants to say so before asking.
    public static var totalByteCount: Int64 { all.reduce(0) { $0 + $1.byteCount } }

    // MARK: - Where they live

    /// Beside everything else this appliance keeps for itself — the appliance
    /// directory, which is `~/Library/Application Support/SAGE Voice Bridge` on
    /// a Mac, unchanged, and `$XDG_DATA_HOME/SAGE Voice Bridge` off Darwin.
    ///
    /// 354 MB of downloaded weights is the worst thing to put in a folder the
    /// owner cannot find: it survives an uninstall, it is invisible to their
    /// backup, and the only symptom is a home directory that is a third of a
    /// gigabyte larger than they can account for. Off Darwin the native voice is
    /// the *ordinary* path rather than an option, so this directory is the one
    /// most likely to exist on a Linux box.
    public static func directory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ApplianceSupportDirectory.directory(
            layout: layout,
            homeDirectory: homeDirectory,
            environment: environment
        )
        .appendingPathComponent("Kokoro", isDirectory: true)
    }

    public static func location(
        of asset: Asset,
        in directory: URL = KokoroAssets.directory()
    ) -> URL {
        directory.appendingPathComponent(asset.name)
    }

    // MARK: - What happened

    public enum Outcome: Equatable, Sendable {
        /// Every asset is already in place. Provisioning is once per Mac.
        case alreadyInstalled
        case installed(byteCount: Int64)
        /// Not enough room to land the download. Named separately because it is
        /// the one failure the owner can actually do something about.
        case notEnoughSpace(needed: Int64, free: Int64)
        case couldNotReach(asset: String, reason: String)
        /// Downloaded, and the bytes are not the bytes. A wrong model does not
        /// fail loudly — it synthesizes something subtly wrong — so this refuses
        /// rather than installing and hoping.
        case corrupted(asset: String)
        case couldNotSave(String)

        public var isReady: Bool {
            switch self {
            case .alreadyInstalled, .installed: return true
            case .notEnoughSpace, .couldNotReach, .corrupted, .couldNotSave: return false
            }
        }

        /// One line for the log. No paths from the owner's home directory and no
        /// URLs — this file has already had to have a phone number scrubbed out
        /// of it once.
        public var logLine: String {
            switch self {
            case .alreadyInstalled:
                return "voice: the Kokoro model is already installed"
            case .installed(let bytes):
                return "voice: installed the Kokoro model (\(bytes / 1_048_576) MB)"
            case .notEnoughSpace(let needed, let free):
                return "voice: not enough disk space for the model "
                    + "(needs \(needed / 1_048_576) MB, \(free / 1_048_576) MB free)"
            case .couldNotReach(let asset, let reason):
                return "voice: could not download \(asset) (\(reason))"
            case .corrupted(let asset):
                return "voice: \(asset) did not match its checksum and was discarded"
            case .couldNotSave(let reason):
                return "voice: could not save the model (\(reason))"
            }
        }
    }

    /// Somewhere to report a fraction to, that can be handed onwards freely.
    ///
    /// A bare closure would do the job everywhere except in a function *type*,
    /// where nested closure parameters are implicitly non-escaping — so a
    /// downloader could receive the callback and not be allowed to give it to
    /// the delegate that actually knows the byte counts. Holding the closure in
    /// a `Sendable` value sidesteps that without `withoutActuallyEscaping`, and
    /// `callAsFunction` keeps the call sites reading as `progress(0.5)`.
    public struct ProgressSink: Sendable {
        private let report: @Sendable (Double) -> Void

        public init(_ report: @escaping @Sendable (Double) -> Void) {
            self.report = report
        }

        public func callAsFunction(_ fraction: Double) { report(fraction) }
    }

    /// Fetches one asset to a temporary file, reporting progress from 0 to 1.
    ///
    /// Injected so the whole of `installIfNeeded` — space check, digest,
    /// rejection, atomic placement — is testable without a 325 MB download.
    public typealias Downloader = @Sendable (
        _ asset: Asset,
        _ progress: ProgressSink
    ) async throws -> URL

    // MARK: - Installing

    /// Whether every asset is present at its expected size.
    ///
    /// Size only, deliberately. A file at the final path is one that already
    /// passed a full SHA-256 check at the instant it was placed there — nothing
    /// is ever moved into place unverified — so re-hashing 325 MB at every
    /// launch would buy only the detection of later disk corruption, which
    /// costs a second of startup and which the inference session would surface
    /// anyway by failing to load.
    public static func isInstalled(
        assets: [Asset] = KokoroAssets.all,
        in directory: URL = KokoroAssets.directory(),
        fileManager: FileManager = .default
    ) -> Bool {
        assets.allSatisfy { asset in
            let path = location(of: asset, in: directory).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int64 else { return false }
            return size == asset.byteCount
        }
    }

    /// Downloads whatever is missing. Safe to call on every link.
    @discardableResult
    public static func installIfNeeded(
        assets: [Asset] = KokoroAssets.all,
        into directory: URL = KokoroAssets.directory(),
        fileManager: FileManager = .default,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        download: Downloader = KokoroAssets.liveDownloader
    ) async -> Outcome {
        if isInstalled(assets: assets, in: directory, fileManager: fileManager) {
            return .alreadyInstalled
        }

        let missing = assets.filter { asset in
            let path = location(of: asset, in: directory).path
            let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int64
            return size != asset.byteCount
        }
        let wanted = missing.reduce(0) { $0 + $1.byteCount }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .couldNotSave(error.localizedDescription)
        }

        // Checked before the first byte rather than discovered at the last one.
        // Twice the payload, because the file lands in a temporary location and
        // is then copied into place, so both exist at once at the moment of
        // installation.
        if let free = freeSpace(at: directory, fileManager: fileManager), free < wanted * 2 {
            return .notEnoughSpace(needed: wanted * 2, free: free)
        }

        var completed: Int64 = 0
        for asset in missing {
            let share = Double(asset.byteCount) / Double(max(wanted, 1))
            let base = Double(completed) / Double(max(wanted, 1))

            let temporary: URL
            do {
                temporary = try await download(asset, ProgressSink { fraction in
                    progress(base + share * min(max(fraction, 0), 1))
                })
            } catch {
                return .couldNotReach(asset: asset.name, reason: error.localizedDescription)
            }
            defer { try? fileManager.removeItem(at: temporary) }

            guard digest(of: temporary) == asset.sha256 else {
                return .corrupted(asset: asset.name)
            }

            // Verified first, then placed. Nothing incomplete or unchecked ever
            // occupies the real path, which is what lets `isInstalled` trust a
            // byte count instead of re-hashing.
            let destination = location(of: asset, in: directory)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                return .couldNotSave(error.localizedDescription)
            }
            completed += asset.byteCount
        }

        progress(1)
        return .installed(byteCount: wanted)
    }

    // MARK: - Helpers

    /// Streamed rather than loaded. `Data(contentsOf:)` on the model would put
    /// 325 MB in memory to compute a number about it.
    static func digest(of url: URL, chunkSize: Int = 1 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func freeSpace(at url: URL, fileManager: FileManager) -> Int64? {
        VolumeFreeSpace.availableBytes(at: url)
    }

    /// The real downloader: a transfer that streams to disk and reports how far
    /// along it is.
    ///
    /// A stored closure rather than a static method, because a method reference
    /// used as a default argument has to convert to the typealias, and Swift
    /// refuses that conversion.
    public static let liveDownloader: Downloader = { asset, progress in
        try await ProgressReportingDownload.run(url: asset.url, progress: progress)
    }
}

/// A `URLSessionDownloadTask` wrapped so it can be awaited with progress.
///
/// `URLSession.download(for:)` is the obvious call and reports nothing, and
/// `URLSession.bytes(for:)` reports everything one `UInt8` at a time — an await
/// per byte across 325 MB. The delegate is the only shape that streams to disk
/// at full speed and still says how far along it is.
final class ProgressReportingDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let progress: KokoroAssets.ProgressSink
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    private init(progress: KokoroAssets.ProgressSink) {
        self.progress = progress
    }

    static func run(
        url: URL,
        progress: KokoroAssets.ProgressSink
    ) async throws -> URL {
        let delegate = ProgressReportingDownload(progress: progress)
        let configuration = URLSessionConfiguration.default
        // The transfer is long and the owner is not watching it. A short
        // per-request timeout would kill a download that is progressing fine on
        // a slow line; the resource timeout is what bounds the whole thing.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.lock.lock()
            delegate.continuation = continuation
            delegate.lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    /// Resumes the caller exactly once. The delegate can report both a finished
    /// file and an error for the same task, and resuming a continuation twice is
    /// a crash rather than a warning.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // A 404 or a 503 is a *successful transfer* of an error page. Left
        // unchecked it would reach the checksum and be reported as a corrupted
        // model, sending anyone reading the log after the wrong thing entirely.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(DownloadError.badStatus(http.statusCode)))
            return
        }

        // The delegate's file is deleted the moment this returns, so it has to be
        // moved somewhere the caller still owns before that happens.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        finish(.failure(error))
    }

    enum DownloadError: LocalizedError {
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "the server answered \(code)"
            }
        }
    }
}
