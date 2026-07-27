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

public struct CascadingAudioFileTranscriber: AudioFileTranscribing {
    private let transcribers: [AudioFileTranscribing]

    public init(_ transcribers: [AudioFileTranscribing]) {
        self.transcribers = transcribers
    }

    public func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        guard !transcribers.isEmpty else {
            throw AudioTranscriberError.allBackendsFailed(["No local ASR backend is ready. Wait for the Apple Silicon speech engine to finish startup."])
        }

        var errors: [String] = []
        for transcriber in transcribers {
            do {
                return try await transcriber.transcribe(audioFile: audioFile, options: options)
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
        for transcriber in transcribers {
            do {
                return try await transcriber.transcribeWithTiming(audioFile: audioFile, options: options)
            } catch {
                errors.append(AudioTranscriberError.describe(error))
            }
        }
        throw AudioTranscriberError.allBackendsFailed(errors)
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
