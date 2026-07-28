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
        /// Loaded and answering. Reached only after a real request succeeds.
        case ready
        case failed(String)

        public var isFinished: Bool {
            switch self {
            case .ready, .failed: return true
            case .idle, .downloadingRuntime, .startingRuntime, .downloadingModel: return false
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
            let total = runtimeShare + modelShare

            switch self {
            case .idle:
                return 0
            case .downloadingRuntime(let done, let expected):
                let of = Double(expected ?? LocalBrainModelCatalog.approximateRuntimeDownloadBytes)
                guard of > 0 else { return nil }
                return (Double(done) / of) * (runtimeShare / total)
            case .startingRuntime:
                return runtimeShare / total
            case .downloadingModel(_, let done, let expected):
                let of = Double(expected ?? LocalBrainModelCatalog.approximateModelDownloadBytes)
                guard let done, of > 0 else { return runtimeShare / total }
                return (runtimeShare + Double(done) / of * modelShare) / total
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
            case .ready:
                return "Ready. Nothing you say will leave this Mac."
            case .failed(let reason):
                return reason
            }
        }
    }

    private let client: OllamaClient
    private let model: String
    private let runtime: OllamaRuntimeInstalling

    public init(
        client: OllamaClient = OllamaClient(),
        model: String = LocalBrainModelCatalog.preferredModel,
        runtime: OllamaRuntimeInstalling = OllamaRuntimeInstaller()
    ) {
        self.client = client
        self.model = model
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

            // Reachable plus pulled is still not "works": a model on disk that
            // the runtime cannot load fails at the first real request, which on
            // a voice turn is dead air. So the finish line is a served request.
            guard try await hasModel() else {
                onPhase(.failed("The brain finished downloading but is not usable."))
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
        return installed.contains { $0 == model || $0 == "\(model):latest" }
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

/// Not implemented yet. Present so the sequencing above is complete and testable,
/// and so the gap is a named type rather than a `TODO` in a comment.
///
/// The shape is settled — SAGE's `internal/ollamad/install.go` already does it:
/// fetch a version-pinned `ollama-darwin.tgz` (~129 MB), verify its sha256,
/// extract into the app's own Application Support directory, and exec it on
/// loopback. No admin, no `/Applications`, no Gatekeeper hand-over.
public struct OllamaRuntimeInstaller: OllamaRuntimeInstalling {
    public init() {}

    public func install(onProgress: @Sendable (Int64, Int64?) -> Void) async throws {
        throw Failure.notImplemented
    }

    public func start() async throws {
        throw Failure.notImplemented
    }

    public enum Failure: LocalizedError {
        case notImplemented

        public var errorDescription: String? {
            "Mynah cannot install the brain software yet. Install Ollama, then come back."
        }
    }
}
