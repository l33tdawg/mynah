import Foundation

public struct LocalASRDiscovery {
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        rootDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
        self.homeDirectory = homeDirectory
    }

    public func commandBackend(language: String = "en") -> WhisperCommandASRBackend? {
        guard let executable = firstExecutable(), let model = firstModel() else {
            return nil
        }

        return WhisperCommandASRBackend(
            executablePath: executable.path,
            modelPath: model.path,
            language: language,
            extraArguments: commandArgumentsForLowLatencyFallback()
        )
    }

    public func firstExecutable() -> URL? {
        let names = ["whisper-cli", "main", "whisper"]
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli"), isExecutable(bundled) {
            return bundled
        }

        if let candidate = executableCandidates().first(where: isExecutable) {
            return candidate
        }

        for name in names {
            if let path = pathFromEnvironment(name), isExecutable(URL(fileURLWithPath: path)) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    public func firstModel() -> URL? {
        modelCandidates().first { fileManager.fileExists(atPath: $0.path) }
    }

    private func pathFromEnvironment(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(name)
            if isExecutable(candidate) {
                return candidate.path
            }
        }
        return nil
    }

    private func isExecutable(_ url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

    private func commandArgumentsForLowLatencyFallback() -> [String] {
        let threads = min(8, max(4, ProcessInfo.processInfo.processorCount - 2))
        return [
            "--no-timestamps",
            "--suppress-nst",
            "--no-speech-thold",
            "0.25",
            "--threads",
            "\(threads)",
            "--beam-size",
            "1",
            "--best-of",
            "2"
        ]
    }

    private func executableCandidates() -> [URL] {
        [
            "/opt/homebrew/bin/whisper-cli",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper-cli",
            "/usr/local/bin/whisper",
            homeDirectory.appendingPathComponent("whisper.cpp/build/bin/whisper-cli").path,
            homeDirectory.appendingPathComponent("whisper.cpp/main").path,
            rootDirectory.appendingPathComponent("vendor/whisper.cpp/build/bin/whisper-cli").path,
            rootDirectory.appendingPathComponent("third_party/whisper.cpp/build/bin/whisper-cli").path,
            rootDirectory.appendingPathComponent("build/bin/whisper-cli").path
        ].map(URL.init(fileURLWithPath:))
    }

    private func modelCandidates() -> [URL] {
        let filenames = [
            "ggml-large-v3-turbo.bin",
            "ggml-small.en.bin",
            "ggml-base.en.bin",
            "ggml-tiny.en.bin"
        ]
        let directories = [
            (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("Models", isDirectory: true),
            rootDirectory.appendingPathComponent("models"),
            rootDirectory.appendingPathComponent("resources/Models"),
            homeDirectory.appendingPathComponent("Library/Application Support/QuietType/Models"),
            homeDirectory.appendingPathComponent(".cache/whisper.cpp"),
            homeDirectory.appendingPathComponent("whisper.cpp/models")
        ]

        return directories.flatMap { directory in
            filenames.map { directory.appendingPathComponent($0) }
        }
    }
}

/// Starts the best packaged speech engine and keeps the whisper.cpp fallback
/// ready behind it.
///
/// The helpers and models are release assets, not runtime downloads. That keeps
/// every executable inside the app's notarized signature and means first speech
/// never asks the owner to install Python, Homebrew, or a command-line tool.
public actor LocalASRRuntime {
    public static let shared = LocalASRRuntime()

    private var nativeSupervisor: WhisperKitServerSupervisor?

    public init() {}

    /// - Parameter log: where the per-transcription timing goes. Defaulted to
    ///   nothing so the app and the CLI probes stay quiet; the daemon passes its
    ///   own, because the daemon is the process somebody complained about.
    public func prepare(
        language: String = "en",
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CascadingAudioFileTranscriber {
        var backends: [AudioFileTranscribing] = []
        var startupFailures: [String] = []

        if let executable = WhisperKitServerBundleLocator.bundledExecutable() {
            let supervisor: WhisperKitServerSupervisor
            if let nativeSupervisor {
                supervisor = nativeSupervisor
            } else {
                supervisor = WhisperKitServerSupervisor(executableURL: executable)
                nativeSupervisor = supervisor
            }
            do {
                // **Checked, not started.** This called `ensureRunning()` here,
                // at daemon boot, and the comment at the call site defended it:
                // "better to know now than when the first voice note arrives".
                //
                // That argument is about *diagnosis*, and it is right — a bundle
                // shipped with no ASR helper once crash-looped the daemon under
                // launchd. But what it was diagnosing is a missing file, and a
                // missing file can be seen without loading a 626 MB model.
                //
                // What the eager start actually bought was a whisper-large-v3
                // server resident for the life of the daemon on every Mac,
                // holding both encoder and decoder on `cpuAndGPU`, whether or
                // not anybody ever sent a voice note. That is the leading
                // candidate for "it's made my laptop very laggy", and it is
                // invisible on this owner's Mac because QuietType already owns
                // the port — see `isUsingSomebodyElsesServer`.
                //
                // So: the file check at boot, the process on first speech.
                try supervisor.verifyInstallation()
                backends.append(ManagedWhisperKitTranscriber(
                    supervisor: supervisor,
                    inner: WhisperKitServerTranscriber(
                        endpoint: supervisor.baseURL.appendingPathComponent("v1/audio/transcriptions"),
                        model: "large-v3-v20240930_626MB",
                        language: language,
                        timeoutSeconds: WhisperKitServerTranscriber.minimumFullAudioTimeoutSeconds
                    ),
                    log: log
                ))
            } catch {
                startupFailures.append("WhisperKit: \(error)")
            }
        } else {
            startupFailures.append("WhisperKit helper is not bundled")
        }

        if let fallback = LocalASRDiscovery().commandBackend(language: language) {
            backends.append(fallback)
        } else {
            startupFailures.append("whisper.cpp helper or model is not bundled")
        }

        guard !backends.isEmpty else {
            throw AudioTranscriberError.allBackendsFailed(startupFailures)
        }
        return CascadingAudioFileTranscriber(backends, log: log)
    }
}

/// Starts the ASR server the first time somebody actually speaks, and checks it
/// is still there before every transcription after that.
///
/// ## Two failures, one wrapper
///
/// **The server was started once, at daemon boot, and never checked again.** The
/// endpoint was baked into a `WhisperKitServerTranscriber` at that moment, so
/// nothing downstream could tell a healthy server from a departed one — every
/// voice note simply failed until somebody restarted the daemon. That is not
/// hypothetical on the owner's Mac: the process answering on port 50060 belongs
/// to **QuietType**, not to Mynah, and Mynah adopted it without noticing. When
/// QuietType quits, so does Mynah's ability to hear.
///
/// **And starting at boot is what made the appliance heavy.** A 626 MB
/// whisper-large-v3 model, encoder and decoder both on `cpuAndGPU`, resident for
/// the life of the daemon on every Mac — including the ones where nobody ever
/// sends a voice note. Asking here instead means a Mac that is never spoken to
/// never loads it.
///
/// ## The timing line
///
/// #34 asked for per-request ASR timing and there was none, which is why "ASR
/// exceeded the model on three of twelve turns" could be observed and not
/// explained. Emitted per transcription rather than aggregated, because the
/// interesting cases are individual: 5.8 s to transcribe half a second of speech
/// is not visible in a mean.
struct ManagedWhisperKitTranscriber: AudioFileTranscribing {
    let supervisor: WhisperKitServerSupervisor
    let inner: WhisperKitServerTranscriber
    let log: @Sendable (String) -> Void

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        let waitingForServer = Date()
        try await supervisor.ensureRunning()
        let startupSeconds = Date().timeIntervalSince(waitingForServer)

        let started = Date()
        let text = try await inner.transcribe(audioFile: audioFile, options: options)
        let seconds = Date().timeIntervalSince(started)

        let bytes = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? nil
        // Whose server did the work is on every line, not just the first. It is
        // the difference between a Mac carrying its own copy of the model and
        // one borrowing somebody else's, and that difference is the whole of why
        // the lag report could not be reproduced here.
        log(String(
            format: "[asr] transcribed %@ in %.1fs%@ — %@ server%@",
            bytes.map { "\($0 / 1024)kB" } ?? "audio",
            seconds,
            startupSeconds > 0.5 ? String(format: ", after %.1fs starting it", startupSeconds) : "",
            supervisor.isUsingSomebodyElsesServer ? "somebody else's" : "our own",
            text.isEmpty ? " — and it heard nothing" : ""
        ))
        return text
    }
}

public struct CascadingAudioFileTranscriber: AudioFileTranscribing {
    private let transcribers: [AudioFileTranscribing]
    private let log: @Sendable (String) -> Void

    public init(
        _ transcribers: [AudioFileTranscribing],
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transcribers = transcribers
        self.log = log
    }

    public func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        guard !transcribers.isEmpty else {
            throw AudioTranscriberError.allBackendsFailed(["No local ASR backend is ready. Wait for the Apple Silicon speech engine to finish startup."])
        }

        var errors: [String] = []
        let started = Date()
        for (index, transcriber) in transcribers.enumerated() {
            do {
                let text = try await transcriber.transcribe(audioFile: audioFile, options: options)
                reportRescue(ifNeeded: errors, succeedingAt: index, started: started)
                return text
            } catch {
                errors.append(AudioTranscriberError.describe(error))
            }
        }
        throw AudioTranscriberError.allBackendsFailed(errors)
    }

    public func transcribeWithTiming(audioFile: URL, options: AudioTranscriptionOptions) async throws -> TimedTranscriptionResult {
        guard !transcribers.isEmpty else {
            throw AudioTranscriberError.allBackendsFailed(["No local ASR backend is ready. Wait for the Apple Silicon speech engine to finish startup."])
        }

        var errors: [String] = []
        let started = Date()
        for (index, transcriber) in transcribers.enumerated() {
            do {
                let result = try await transcriber.transcribeWithTiming(audioFile: audioFile, options: options)
                reportRescue(ifNeeded: errors, succeedingAt: index, started: started)
                return result
            } catch {
                errors.append(AudioTranscriberError.describe(error))
            }
        }
        throw AudioTranscriberError.allBackendsFailed(errors)
    }

    /// A successful fallback used to erase the only evidence that another
    /// backend had failed first. On the owner's real call that made a rescued
    /// 4.5-second recognition indistinguishable from an ordinary 1.0-second
    /// turn, leaving the Mac-lag investigation with a hole in its instrument.
    private func reportRescue(ifNeeded errors: [String], succeedingAt index: Int, started: Date) {
        guard !errors.isEmpty else { return }
        let failures = errors.enumerated().map { offset, error in
            "backend \(offset + 1): \(error)"
        }.joined(separator: "; ")
        log(String(
            format: "[asr] rescued by backend %d after %.1fs (%@)",
            index + 1,
            Date().timeIntervalSince(started),
            failures
        ))
    }
}

public extension AudioTranscriberError {
    static func describe(_ error: Error) -> String {
        if case let AudioTranscriberError.requestFailed(message) = error {
            return message
        }
        return String(describing: error)
    }
}

extension WhisperCommandASRBackend: AudioFileTranscribing {
    public func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        try await transcribe(wavFile: audioFile, options: options)
    }
}
