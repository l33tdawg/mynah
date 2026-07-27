import Foundation

public struct WhisperCommandASRConfiguration: Equatable, Sendable {
    public var executableURL: URL
    public var modelURL: URL
    public var language: String?
    public var extraArguments: [String]

    public init(
        executableURL: URL,
        modelURL: URL,
        language: String? = "en",
        extraArguments: [String] = []
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.language = language
        self.extraArguments = extraArguments
    }
}

public enum WhisperCommandASRError: Error, Equatable, CustomStringConvertible {
    case nonFileURL(String)
    case missingExecutable(String)
    case missingModel(String)
    case missingAudioFile(String)
    case processFailed(exitCode: Int32, stdout: String, stderr: String)
    case emptyTranscript(stdout: String, stderr: String)

    public var description: String {
        switch self {
        case .nonFileURL(let value):
            return "Whisper command paths must be local file URLs: \(value)"
        case .missingExecutable(let path):
            return "Whisper executable does not exist: \(path)"
        case .missingModel(let path):
            return "Whisper model does not exist: \(path)"
        case .missingAudioFile(let path):
            return "Audio file does not exist: \(path)"
        case .processFailed(let exitCode, let stdout, let stderr):
            return "Whisper command failed with exit code \(exitCode). stdout: \(stdout) stderr: \(stderr)"
        case .emptyTranscript(let stdout, let stderr):
            return "Whisper command returned no transcript. stdout: \(stdout) stderr: \(stderr)"
        }
    }
}

public struct WhisperCommandASRBackend: Sendable {
    public var configuration: WhisperCommandASRConfiguration

    public init(configuration: WhisperCommandASRConfiguration) {
        self.configuration = configuration
    }

    public init(
        executablePath: String,
        modelPath: String,
        language: String? = "en",
        extraArguments: [String] = []
    ) {
        self.init(
            configuration: WhisperCommandASRConfiguration(
                executableURL: URL(fileURLWithPath: executablePath),
                modelURL: URL(fileURLWithPath: modelPath),
                language: language,
                extraArguments: extraArguments
            )
        )
    }

    public func transcribe(wavFile: URL, options: AudioTranscriptionOptions = .none) async throws -> String {
        try validateInputs(wavFile: wavFile)

        let result = try await runCommand(arguments: commandArguments(wavFile: wavFile, options: options))
        guard result.exitCode == 0 else {
            throw WhisperCommandASRError.processFailed(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }

        let transcript = Self.parseTranscript(stdout: result.stdout, stderr: result.stderr)
        guard !transcript.isEmpty else {
            throw WhisperCommandASRError.emptyTranscript(stdout: result.stdout, stderr: result.stderr)
        }
        guard !Self.isNoiseOnlyTranscript(transcript) else {
            throw AudioTranscriberError.noiseOnlyTranscript(transcript)
        }
        return transcript
    }

    func commandArguments(wavFile: URL) -> [String] {
        commandArguments(wavFile: wavFile, options: .none)
    }

    func commandArguments(wavFile: URL, options: AudioTranscriptionOptions) -> [String] {
        var arguments = [
            "-m",
            configuration.modelURL.path,
            "-f",
            wavFile.path
        ]

        if let language = configuration.language, !language.isEmpty {
            arguments.append(contentsOf: ["-l", language])
        }

        if let prompt = options.initialPrompt {
            arguments.append(contentsOf: ["--prompt", prompt])
        }

        arguments.append(contentsOf: configuration.extraArguments)
        return arguments
    }

    public static func parseTranscript(stdout: String, stderr: String = "") -> String {
        let timestampedStdout = timestampedTranscript(from: stdout)
        if !timestampedStdout.isEmpty {
            return sanitizeTranscript(timestampedStdout)
        }

        let plainStdout = plainTranscript(from: stdout)
        if !plainStdout.isEmpty {
            return sanitizeTranscript(plainStdout)
        }

        return sanitizeTranscript(timestampedTranscript(from: stderr))
    }

    private func validateInputs(wavFile: URL) throws {
        guard configuration.executableURL.isFileURL else {
            throw WhisperCommandASRError.nonFileURL(configuration.executableURL.absoluteString)
        }
        guard configuration.modelURL.isFileURL else {
            throw WhisperCommandASRError.nonFileURL(configuration.modelURL.absoluteString)
        }
        guard wavFile.isFileURL else {
            throw WhisperCommandASRError.nonFileURL(wavFile.absoluteString)
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configuration.executableURL.path) else {
            throw WhisperCommandASRError.missingExecutable(configuration.executableURL.path)
        }
        guard fileManager.fileExists(atPath: configuration.modelURL.path) else {
            throw WhisperCommandASRError.missingModel(configuration.modelURL.path)
        }
        guard fileManager.fileExists(atPath: wavFile.path) else {
            throw WhisperCommandASRError.missingAudioFile(wavFile.path)
        }
    }

    private func runCommand(arguments: [String]) async throws -> WhisperCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = configuration.executableURL
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdout = WhisperCommandOutputBuffer()
            let stderr = WhisperCommandOutputBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stdout.append(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stderr.append(data)
                }
            }

            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

            return WhisperCommandResult(
                exitCode: process.terminationStatus,
                stdout: stdout.stringValue(),
                stderr: stderr.stringValue()
            )
        }.value
    }

    private static func timestampedTranscript(from output: String) -> String {
        let segments = output
            .components(separatedBy: .newlines)
            .compactMap { timestampedText(in: $0) }
            .filter { !$0.isEmpty }

        return normalize(segments.joined(separator: " "))
    }

    private static func timestampedText(in line: String) -> String? {
        guard
            let openBracket = line.firstIndex(of: "["),
            let arrowRange = line.range(of: "-->", range: openBracket..<line.endIndex),
            let closeBracket = line[arrowRange.upperBound...].firstIndex(of: "]")
        else {
            return nil
        }

        let text = String(line[line.index(after: closeBracket)...])
        return normalize(text)
    }

    private static func plainTranscript(from output: String) -> String {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isWhisperDiagnosticLine($0) }

        return normalize(lines.joined(separator: " "))
    }

    public static func isNoiseOnlyTranscript(_ text: String) -> Bool {
        let normalizedText = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:-_()[]{}\"'"))

        guard !normalizedText.isEmpty else {
            return true
        }

        let words = normalizedText
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.isEmpty {
            return true
        }

        let noiseWords: Set<String> = [
            "music",
            "noise",
            "applause",
            "laughter",
            "silence",
            "inaudible"
        ]
        return words.allSatisfy { noiseWords.contains($0) }
    }

    private static func isWhisperDiagnosticLine(_ line: String) -> Bool {
        let prefixes = [
            "whisper_",
            "ggml_",
            "main:",
            "system_info:",
            "sampling:",
            "processing ",
            "output_"
        ]
        return prefixes.contains { line.hasPrefix($0) }
    }

    private static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sanitizeTranscript(_ text: String) -> String {
        let singingPattern = #"(?i)(\[\s*singing\s*\]|\(\s*singing\s*\)|\*\s*singing\s*\*)"#
        let noisePattern = #"(?i)(\[\s*(music|noise|applause|laughter|silence|inaudible)\s*\]|\(\s*(music|noise|applause|laughter|silence|inaudible)\s*\)|\*\s*(music|noise|applause|laughter|silence|inaudible)\s*\*)"#
        let cleaned = text
            .replacingOccurrences(of: singingPattern, with: " [singing] ", options: .regularExpression)
            .replacingOccurrences(of: noisePattern, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "♪", with: " ")
        return normalize(cleaned)
    }
}

private struct WhisperCommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

private final class WhisperCommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func stringValue() -> String {
        lock.lock()
        let value = String(decoding: data, as: UTF8.self)
        lock.unlock()
        return value
    }
}
