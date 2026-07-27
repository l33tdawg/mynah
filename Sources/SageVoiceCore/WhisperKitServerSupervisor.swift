import Foundation

public enum WhisperKitServerSupervisorError: Error, CustomStringConvertible, Equatable {
    case missingExecutable(String)
    case incompleteModel(String)
    case startupTimedOut(String)

    public var description: String {
        switch self {
        case .missingExecutable(let path):
            return "WhisperKit server executable is missing: \(path)"
        case .incompleteModel(let path):
            return "WhisperKit model is incomplete or missing tokenizer files: \(path)"
        case .startupTimedOut(let detail):
            return "WhisperKit server did not become ready in time. \(detail)"
        }
    }
}

public final class WhisperKitServerSupervisor: @unchecked Sendable {
    private let executableURL: URL
    private let host: String
    private let port: Int
    private let model: String
    private let modelPath: URL?
    private let startupTimeoutSeconds: TimeInterval
    private let logURL: URL
    private let stateLock = NSLock()
    private var process: Process?
    private var logSink: FileHandle?

    public init(
        executableURL: URL,
        host: String = "127.0.0.1",
        port: Int = 50060,
        model: String = "large-v3-v20240930_626MB",
        modelPath: URL? = WhisperKitModelLocator.localModelPath(named: "openai_whisper-large-v3-v20240930_626MB"),
        startupTimeoutSeconds: TimeInterval = 35,
        logURL: URL = WhisperKitServerLog.defaultLogURL()
    ) {
        self.executableURL = executableURL
        self.host = host
        self.port = port
        self.model = model
        self.modelPath = modelPath
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.logURL = logURL
    }

    deinit {
        stop()
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    public func ensureRunning(stopOnTimeout: Bool = true) async throws {
        if await isServerHealthy() {
            return
        }

        try startIfNeeded()
        let deadline = Date().addingTimeInterval(startupTimeoutSeconds)
        while Date() < deadline {
            if await isServerHealthy() {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if stopOnTimeout {
            stop()
        }
        throw WhisperKitServerSupervisorError.startupTimedOut(logTail())
    }

    public func startWarming() throws {
        try startIfNeeded()
    }

    public func isServerHealthy() async -> Bool {
        await isHealthy()
    }

    public var isProcessRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return process?.isRunning == true
    }

    public func stop() {
        stateLock.lock()
        let runningProcess = process
        let activeLogSink = logSink
        self.process = nil
        logSink = nil
        stateLock.unlock()

        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
        try? activeLogSink?.close()
    }

    private func startIfNeeded() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let process, process.isRunning {
            return
        }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WhisperKitServerSupervisorError.missingExecutable(executableURL.path)
        }
        guard let modelPath else {
            throw WhisperKitServerSupervisorError.incompleteModel("No complete local WhisperKit model was found.")
        }
        if !WhisperKitModelLocator.isCompleteModel(at: modelPath) {
            throw WhisperKitServerSupervisorError.incompleteModel(modelPath.path)
        }

        let process = Process()
        process.executableURL = executableURL
        var arguments = [
            "serve",
            "--host", host,
            "--port", "\(port)",
            "--language", "en",
            "--skip-special-tokens",
            "--no-speech-threshold", "0.25",
            "--chunking-strategy", "none",
            "--audio-encoder-compute-units", "cpuAndGPU",
            "--text-decoder-compute-units", "cpuAndGPU",
            "--verbose"
        ]
        arguments.append(contentsOf: ["--model-path", modelPath.path])
        process.arguments = arguments
        try? logSink?.close()
        let newLogSink = try Self.openLogSink(at: logURL)
        let commandLine = ([executableURL.path] + arguments).joined(separator: " ")
        newLogSink.writeString("\n\n[\(Date())] Starting native ASR server\n\(commandLine)\n")
        process.standardOutput = newLogSink
        process.standardError = newLogSink
        do {
            try process.run()
        } catch {
            try? newLogSink.close()
            throw error
        }
        self.process = process
        self.logSink = newLogSink
    }

    private func isHealthy() async -> Bool {
        do {
            let url = baseURL.appendingPathComponent("health")
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private static func openLogSink(at url: URL) throws -> FileHandle {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func logTail(maxBytes: Int = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return "No server log found at \(logURL.path)."
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = UInt64(max(0, Int(size) - maxBytes))
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Server log is empty at \(logURL.path)." : "Recent server log: \(text)"
    }
}

private extension FileHandle {
    func writeString(_ value: String) {
        if let data = value.data(using: .utf8) {
            write(data)
        }
    }
}

public enum WhisperKitModelLocator {
    public static func localModelPath(
        named modelDirectoryName: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        localModelPath(
            named: modelDirectoryName,
            bundle: .main,
            homeDirectory: homeDirectory
        )
    }

    public static func localModelPath(
        named modelDirectoryName: String,
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let candidates = [
            bundledModelRoot(bundle: bundle)
                .appendingPathComponent(modelDirectoryName),
            homeDirectory
                .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
                .appendingPathComponent(modelDirectoryName),
            homeDirectory
                .appendingPathComponent("Library/Application Support/QuietType/WhisperKit")
                .appendingPathComponent(modelDirectoryName),
            homeDirectory
                .appendingPathComponent(".cache/huggingface/hub/models--argmaxinc--whisperkit-coreml")
                .appendingPathComponent(modelDirectoryName)
        ]

        return candidates.first { url in
            isCompleteModel(at: url)
        }
    }

    public static func bundledModelRoot(bundle: Bundle = .main) -> URL {
        if let resourceURL = bundle.resourceURL {
            return resourceURL.appendingPathComponent("WhisperKit", isDirectory: true)
        }
        return bundle.bundleURL
            .appendingPathComponent("Contents/Resources/WhisperKit", isDirectory: true)
    }

    public static func isCompleteModel(at url: URL) -> Bool {
        let requiredFiles = [
            "AudioEncoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "TextDecoder.mlmodelc",
            "config.json",
            "generation_config.json",
            "tokenizer.json",
            "tokenizer_config.json"
        ]
        return requiredFiles.allSatisfy { name in
            FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
        }
    }
}

public enum WhisperKitServerLog {
    public static func defaultLogURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Logs/QuietType", isDirectory: true)
            .appendingPathComponent("argmax-server.log")
    }
}

public enum WhisperKitServerBundleLocator {
    public static func bundledExecutable(bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forAuxiliaryExecutable: "argmax-cli") {
            return url
        }
        let fallbackURL = bundle.bundleURL.appendingPathComponent("Contents/MacOS/argmax-cli")
        return FileManager.default.isExecutableFile(atPath: fallbackURL.path) ? fallbackURL : nil
    }
}
