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

        #if os(macOS)
        let result = try await runCommand(arguments: commandArguments(wavFile: wavFile, options: options))
        #else
        let result = try await runRetryingWithoutExtraArguments(wavFile: wavFile, options: options)
        #endif
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
        commandArguments(wavFile: wavFile, options: options, includingExtraArguments: true)
    }

    func commandArguments(
        wavFile: URL,
        options: AudioTranscriptionOptions,
        includingExtraArguments: Bool
    ) -> [String] {
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

        if includingExtraArguments {
            arguments.append(contentsOf: configuration.extraArguments)
        }
        return arguments
    }

    #if !os(macOS)
    /// Runs the program, and runs it once more without the tuning flags if it
    /// refused one of them.
    ///
    /// **The Mac does not need this and does not get it.** There, whisper.cpp is
    /// a revision-pinned build staged by `provision-asr-assets.sh` and signed
    /// into the bundle, so the flags it is given are known to exist. Off Darwin
    /// the program came from the owner's distribution, and whisper.cpp changes
    /// its command line between releases: an unknown flag makes it exit non-zero
    /// before transcribing anything, which turns the one speech feature the port
    /// keeps into a hard failure over a latency tweak.
    ///
    /// The extras are `--threads`, `--beam-size` and friends — speed, not
    /// correctness — so dropping them costs a slower transcription and nothing
    /// else. One retry, not a loop: if it fails again the error is real and
    /// belongs in front of the owner rather than behind five more launches.
    ///
    /// **The exit code is not part of the test, and that was measured rather
    /// than assumed.** Run against whisper.cpp 1.9.1 with a flag it does not
    /// know, it prints `error: unknown argument`, dumps its usage to *stderr*,
    /// and **exits 0**. A first version of this gated the retry on a non-zero
    /// exit and therefore never fired: the owner got `emptyTranscript` — "the
    /// engine heard nothing" — for a voice note the engine never listened to.
    /// That is precisely the silent-empty-transcript failure this is here to
    /// prevent, so the gate is the *output*, not the status.
    private func runRetryingWithoutExtraArguments(
        wavFile: URL,
        options: AudioTranscriptionOptions
    ) async throws -> WhisperCommandResult {
        let result = try await runCommand(
            arguments: commandArguments(wavFile: wavFile, options: options)
        )
        // Nothing usable came back *and* the program said why. Requiring the
        // empty transcript as well as the message keeps somebody who dictates
        // the words "unknown argument" from paying for two runs of every note.
        guard !configuration.extraArguments.isEmpty,
              Self.parseTranscript(stdout: result.stdout, stderr: result.stderr).isEmpty,
              Self.looksLikeARejectedArgument(stdout: result.stdout, stderr: result.stderr) else {
            return result
        }
        return try await runCommand(
            arguments: commandArguments(
                wavFile: wavFile,
                options: options,
                includingExtraArguments: false
            )
        )
    }

    /// whisper.cpp's own refusal, in the several shapes it has had.
    ///
    /// Deliberately narrow: a broken model file also produces no transcript, and
    /// re-running that without `--threads` would waste a second and change
    /// nothing.
    static func looksLikeARejectedArgument(stdout: String, stderr: String) -> Bool {
        let combined = (stdout + "\n" + stderr).lowercased()
        let refusals = [
            "unknown argument",
            "unrecognized argument",
            "invalid argument",
            "unknown option",
            "error: unknown"
        ]
        return refusals.contains { combined.contains($0) }
    }
    #endif

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
        var prefixes = [
            "whisper_",
            "ggml_",
            "main:",
            "system_info:",
            "sampling:",
            "processing ",
            "output_"
        ]
        #if !os(macOS)
        // The usage dump, which whisper.cpp prints when it rejects a flag — and
        // which it prints on *exit 0*. The Mac never sees it, because the Mac
        // runs a pinned build with a known command line. Off Darwin the program
        // is whatever the distribution packaged, and if a build sends that dump
        // to stdout instead of stderr then `plainTranscript` would hand its
        // eighty lines back as the transcript of the voice note. Empty is a
        // failure the cascade can report; a page of flag documentation
        // delivered as speech is not.
        prefixes += [
            "usage:",
            "options:",
            "error:",
            "supported audio formats:",
            "load_backend:"
        ]
        #endif
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

// MARK: - Getting a voice note into the one shape whisper.cpp reads

/// Whether whisper.cpp can read this file, and if not, what it actually is.
///
/// **whisper.cpp reads one container and one only:** RIFF/WAVE holding 16 kHz
/// 16-bit PCM, mono or stereo. A WhatsApp voice note is Ogg/Opus and a Signal
/// one is usually MPEG-4 audio, so the file that arrives is never the file
/// whisper.cpp wants.
///
/// On a Mac that never mattered, because the first rung of the cascade is the
/// WhisperKit helper, which decodes the container itself through Apple's audio
/// stack before it ever sees a sample. Off Darwin that rung does not exist —
/// there is no CoreML and no port of it — so whisper.cpp *is* the feature, and
/// it was being handed Ogg.
///
/// This is a probe rather than a guess from the file extension. WhatsApp writes
/// `.ogg`, Signal writes `.m4a`, and the daemon's own scratch recordings write
/// `.wav` at whatever rate produced them; only the bytes say which of those is
/// true, and a `.wav` at 44.1 kHz is refused by whisper.cpp exactly as firmly as
/// an Ogg is.
public enum WhisperAudioInput: Equatable, Sendable {
    /// Hand it to whisper.cpp untouched.
    case whisperReady
    /// What the file really is, phrased for a sentence the owner will read.
    case needsConversion(describedAs: String)

    public var isWhisperReady: Bool { self == .whisperReady }
}

/// Reads the first few hundred bytes of a file and says whether whisper.cpp
/// will accept it.
///
/// Deliberately header-only: a voice note can be tens of megabytes and the
/// answer lives in the first 44 bytes, and shelling out to `ffprobe` would make
/// the *question* depend on the tool whose absence is the thing being reported.
public enum WhisperAudioProbe {
    /// whisper.cpp's `COMMON_SAMPLE_RATE`. Anything else and it prints
    /// "WAV file must be 16 kHz" and stops.
    public static let requiredSampleRate = 16_000
    static let headerBytesToRead = 4096

    public static func inspect(fileAt url: URL) -> WhisperAudioInput {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .needsConversion(describedAs: "an unreadable file (\(url.lastPathComponent))")
        }
        defer { try? handle.close() }
        let header = ((try? handle.read(upToCount: headerBytesToRead)) ?? nil) ?? Data()
        return inspect(header: [UInt8](header), named: url.lastPathComponent)
    }

    /// The pure half, so the decision can be tested without a filesystem.
    public static func inspect(header bytes: [UInt8], named name: String) -> WhisperAudioInput {
        guard !bytes.isEmpty else {
            return .needsConversion(describedAs: "an empty file (\(name))")
        }
        guard ascii(bytes, 0, 4) == "RIFF" else {
            return .needsConversion(describedAs: describeNonRIFF(bytes, named: name))
        }
        guard ascii(bytes, 8, 4) == "WAVE" else {
            return .needsConversion(describedAs: "a RIFF file that is not WAVE (\(name))")
        }

        // Walk the chunk list rather than assuming `fmt ` sits at byte 12:
        // plenty of writers put a `JUNK` or `LIST` chunk in front of it, and
        // reading the wrong offset would call a perfectly good 16 kHz WAV
        // "compressed" and convert it for no reason.
        var offset = 12
        while let identifier = ascii(bytes, offset, 4), let size = u32(bytes, offset + 4) {
            if identifier == "fmt " {
                guard let tag = u16(bytes, offset + 8),
                      let channels = u16(bytes, offset + 10),
                      let sampleRate = u32(bytes, offset + 12),
                      let bitsPerSample = u16(bytes, offset + 22) else {
                    break
                }
                // 0xFFFE is WAVE_FORMAT_EXTENSIBLE, which is ordinary PCM with a
                // longer header; whisper.cpp's WAV reader handles it.
                let isPCM = tag == 1 || (tag == 0xFFFE && bitsPerSample == 16)
                if isPCM,
                   bitsPerSample == 16,
                   sampleRate == requiredSampleRate,
                   channels == 1 || channels == 2 {
                    return .whisperReady
                }
                return .needsConversion(
                    describedAs: describeWAV(
                        tag: tag,
                        channels: channels,
                        sampleRate: sampleRate,
                        bitsPerSample: bitsPerSample
                    )
                )
            }
            // Chunks are word aligned. A chunk header is 8 bytes, so this
            // always advances and cannot spin.
            let next = offset + 8 + size + (size % 2)
            guard next > offset else { break }
            offset = next
        }
        return .needsConversion(describedAs: "a WAV whose format chunk could not be read (\(name))")
    }

    private static func describeWAV(tag: Int, channels: Int, sampleRate: Int, bitsPerSample: Int) -> String {
        let codec: String
        switch tag {
        case 1, 0xFFFE: codec = "\(bitsPerSample)-bit PCM"
        case 3: codec = "\(bitsPerSample)-bit float"
        case 6: codec = "A-law"
        case 7: codec = "mu-law"
        case 0x11: codec = "IMA ADPCM"
        default: codec = String(format: "format 0x%04X", tag)
        }
        let layout: String
        switch channels {
        case 1: layout = "mono"
        case 2: layout = "stereo"
        default: layout = "\(channels)-channel"
        }
        return "a \(sampleRate) Hz \(layout) \(codec) WAV, and whisper.cpp reads only "
            + "\(requiredSampleRate) Hz 16-bit PCM"
    }

    private static func describeNonRIFF(_ bytes: [UInt8], named name: String) -> String {
        if ascii(bytes, 0, 4) == "OggS" {
            return "an Ogg file (Opus or Vorbis — what a WhatsApp voice note is)"
        }
        if ascii(bytes, 4, 4) == "ftyp" {
            return "an MPEG-4 audio file (m4a/aac — what a Signal voice note usually is)"
        }
        if ascii(bytes, 0, 4) == "fLaC" {
            return "a FLAC file"
        }
        if ascii(bytes, 0, 4) == "FORM", let kind = ascii(bytes, 8, 4), kind.hasPrefix("AIF") {
            return "an AIFF file"
        }
        if ascii(bytes, 0, 5) == "#!AMR" {
            return "an AMR file"
        }
        if ascii(bytes, 0, 3) == "ID3" {
            return "an MP3 file"
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            return "an MPEG audio file (mp3)"
        }
        if ascii(bytes, 0, 4) == "\u{1A}\u{45}\u{DF}\u{A3}" {
            return "a Matroska/WebM file"
        }
        let suffix = (name as NSString).pathExtension.lowercased()
        return suffix.isEmpty
            ? "not a WAV file (\(name))"
            : "a .\(suffix) file, which is not a WAV"
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String? {
        guard offset >= 0, count > 0, offset + count <= bytes.count else { return nil }
        return String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return Int(bytes[offset])
            | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16
            | Int(bytes[offset + 3]) << 24
    }
}

/// Why a voice note could not be made readable — never silently, and never as
/// an empty transcript.
///
/// Every case names the program and the next action. "Nothing came back" for a
/// note the owner can hear perfectly well when he plays it is the failure this
/// whole file exists to stop.
public enum WhisperAudioConversionError: Error, Equatable, CustomStringConvertible {
    case converterMissing(input: String, searched: [String])
    case converterFailed(converter: String, input: String, exitCode: Int32, stderr: String)
    case converterTimedOut(converter: String, seconds: Int)
    case converterProducedNoAudio(converter: String, input: String)
    case converterProducedUnusableAudio(converter: String, describedAs: String)

    public var description: String {
        switch self {
        case let .converterMissing(input, searched):
            return "This voice note is \(input), and whisper.cpp only reads "
                + "\(WhisperAudioProbe.requiredSampleRate) Hz 16-bit PCM WAV. Converting it needs "
                + "ffmpeg, which is not installed. \(WhisperAudioConverter.installInstruction) "
                + "Looked for it in: \(Self.list(searched))."

        case let .converterFailed(converter, input, exitCode, stderr):
            return "ffmpeg at \(converter) could not convert this voice note (\(input)) — it "
                + "exited \(exitCode)\(Self.quote(stderr)). If the note was a partial download, "
                + "ask for it again; if this ffmpeg was built without the Opus decoder — Fedora's "
                + "ffmpeg-free is — install the full ffmpeg package instead."

        case let .converterTimedOut(converter, seconds):
            return "ffmpeg at \(converter) did not finish converting this voice note within "
                + "\(seconds)s and was stopped. Ask for the note again; if it happens every time, "
                + "run ffmpeg on the file by hand to see what it is waiting for."

        case let .converterProducedNoAudio(converter, input):
            return "ffmpeg at \(converter) read this voice note (\(input)) and produced no audio "
                + "at all, so there is nothing to transcribe. The file most likely has no audio "
                + "track or arrived truncated — ask for the note again."

        case let .converterProducedUnusableAudio(converter, describedAs):
            return "ffmpeg at \(converter) converted this voice note into \(describedAs), which "
                + "whisper.cpp cannot read. That is a fault in Mynah rather than in the note — "
                + "the daemon log carries the ffmpeg command that produced it."
        }
    }

    private static func quote(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return ": " + String(trimmed.prefix(400))
    }

    private static func list(_ paths: [String], limit: Int = 8) -> String {
        guard paths.count > limit else { return paths.joined(separator: ", ") }
        return paths.prefix(limit).joined(separator: ", ") + " (and \(paths.count - limit) more)"
    }
}

/// ffmpeg, when the machine has one.
///
/// **Not bundled, and not downloaded.** Off Darwin the owner installs SAGE and
/// whisper.cpp themselves and Mynah ships no binaries there; ffmpeg is the same
/// arrangement, and it is a reasonable one to ask for — every distribution has
/// it in its main repository, and a machine that already has whisper.cpp
/// usually already has ffmpeg beside it.
///
/// What is *not* acceptable is finding it absent and saying nothing. A missing
/// converter is a named refusal with an install command, never an empty
/// transcript.
public struct WhisperAudioConverter: Sendable, Equatable {
    public let executableURL: URL
    /// Generous — a long note on a slow machine — but bounded, because a wedged
    /// converter must not hold the turn open until the owner gives up.
    public let timeoutSeconds: TimeInterval

    public init(executableURL: URL, timeoutSeconds: TimeInterval = 120) {
        self.executableURL = executableURL
        self.timeoutSeconds = timeoutSeconds
    }

    public static let installInstruction =
        "Install ffmpeg — `sudo apt install ffmpeg` on Debian or Ubuntu, `sudo dnf install ffmpeg` "
        + "on Fedora, `sudo pacman -S ffmpeg` on Arch — or point SAGE_VOICE_FFMPEG at the program "
        + "if it lives somewhere else."

    /// What the daemon says at startup on a machine that can hear WAV and
    /// nothing else. Not fatal: a machine with whisper.cpp and no ffmpeg still
    /// transcribes a WAV, so the engine is started and this is a warning.
    public static var missingConverterWarning: String {
        "ffmpeg was not found, so voice notes that arrive as Ogg/Opus or m4a — which is what "
            + "WhatsApp and Signal send — cannot be converted for whisper.cpp and will be refused "
            + "by name rather than transcribed. \(installInstruction)"
    }

    public static func discover(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> WhisperAudioConverter? {
        for path in searchedPaths(environment: environment, homeDirectory: homeDirectory) {
            // **A directory answers yes to `isExecutableFile`.** Somebody who
            // sets SAGE_VOICE_FFMPEG to their build directory would otherwise
            // have Mynah try to run the directory, and the failure that came
            // back would be about permissions rather than about the fact that
            // the override wants the program next to it.
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: path) else {
                continue
            }
            return WhisperAudioConverter(executableURL: URL(fileURLWithPath: path))
        }
        return nil
    }

    /// The same list `discover` walks, kept so the refusal can say where it
    /// looked. A failure that names no place to put the missing thing is half a
    /// failure.
    public static func searchedPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        var paths: [String] = []

        // The override first, and accepted as either the program or the
        // directory holding it, because half the people who set it will point
        // it at a directory.
        if let raw = environment["SAGE_VOICE_FFMPEG"], !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            paths.append(expanded)
            paths.append(URL(fileURLWithPath: expanded).appendingPathComponent("ffmpeg").path)
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            paths.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("ffmpeg").path)
        }

        paths += [
            "/usr/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/snap/bin/ffmpeg",
            homeDirectory.appendingPathComponent(".local/bin/ffmpeg").path
        ]

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Old flags on purpose. `-acodec` and `-ar` have been in ffmpeg since
    /// before any distribution packaged it, where `-c:a` and the filter syntax
    /// have not; the point of this command is that it runs on whatever ffmpeg
    /// the owner's distribution happens to ship.
    public static func arguments(input: URL, output: URL) -> [String] {
        [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", input.path,
            "-vn",
            "-ac", "1",
            "-ar", "\(WhisperAudioProbe.requiredSampleRate)",
            "-acodec", "pcm_s16le",
            "-f", "wav",
            output.path
        ]
    }

    public func convert(input: URL, to output: URL) async throws {
        let result = try await run(arguments: Self.arguments(input: input, output: output))

        guard result.exitCode == 0 else {
            throw WhisperAudioConversionError.converterFailed(
                converter: executableURL.path,
                input: input.lastPathComponent,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }

        // **A zero exit is not proof of audio.** ffmpeg exits 0 having written a
        // 44-byte header when the input has no audio track, and that WAV
        // transcribes to the empty string — which is the exact silent failure
        // this file exists to prevent. So the output is inspected, not trusted.
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? nil
        guard let bytes = size, bytes > WAVAudio.headerByteCount else {
            throw WhisperAudioConversionError.converterProducedNoAudio(
                converter: executableURL.path,
                input: input.lastPathComponent
            )
        }

        if case let .needsConversion(describedAs) = WhisperAudioProbe.inspect(fileAt: output) {
            throw WhisperAudioConversionError.converterProducedUnusableAudio(
                converter: executableURL.path,
                describedAs: describedAs
            )
        }
    }

    private func run(arguments: [String]) async throws -> WhisperCommandResult {
        let executableURL = executableURL
        let timeoutSeconds = timeoutSeconds
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdout = WhisperCommandOutputBuffer()
            let stderr = WhisperCommandOutputBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stdout.append(data) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderr.append(data) }
            }

            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    throw CancellationError()
                }
                if Date() >= deadline {
                    process.terminate()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    throw WhisperAudioConversionError.converterTimedOut(
                        converter: executableURL.path,
                        seconds: Int(timeoutSeconds.rounded())
                    )
                }
                try await Task.sleep(nanoseconds: 20_000_000)
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
}

/// The file whisper.cpp is actually given, and the scratch copy to delete
/// afterwards if one was made.
///
/// A value rather than a bare `URL` because somebody has to remove the
/// converted copy, and returning the path alone is how a daemon accumulates a
/// temporary directory per voice note until the disk fills.
public struct PreparedWhisperAudio: Sendable {
    public let url: URL
    private let scratchDirectory: URL?

    public var wasConverted: Bool { scratchDirectory != nil }

    private init(url: URL, scratchDirectory: URL?) {
        self.url = url
        self.scratchDirectory = scratchDirectory
    }

    public func discard() {
        guard let scratchDirectory else { return }
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    public static func prepare(audioFile: URL, fileManager: FileManager = .default) async throws -> PreparedWhisperAudio {
        try await prepare(
            audioFile: audioFile,
            converter: WhisperAudioConverter.discover(fileManager: fileManager),
            searchedConverterPaths: WhisperAudioConverter.searchedPaths(),
            fileManager: fileManager
        )
    }

    public static func prepare(
        audioFile: URL,
        converter: WhisperAudioConverter?,
        searchedConverterPaths: [String],
        fileManager: FileManager = .default
    ) async throws -> PreparedWhisperAudio {
        // A file that is not there is `WhisperCommandASRBackend`'s error to
        // report, and it reports it by name. Sending it down this path instead
        // would blame ffmpeg for a download that never landed.
        guard fileManager.fileExists(atPath: audioFile.path) else {
            return PreparedWhisperAudio(url: audioFile, scratchDirectory: nil)
        }

        guard case let .needsConversion(describedAs) = WhisperAudioProbe.inspect(fileAt: audioFile) else {
            return PreparedWhisperAudio(url: audioFile, scratchDirectory: nil)
        }

        guard let converter else {
            throw WhisperAudioConversionError.converterMissing(
                input: describedAs,
                searched: searchedConverterPaths
            )
        }

        // 0700, because a voice note is the owner's speech and the scratch copy
        // of it lives in a world-readable temporary directory otherwise.
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("mynah-asr-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: scratch,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let output = scratch.appendingPathComponent("voice-note.wav")
        do {
            try await converter.convert(input: audioFile, to: output)
        } catch {
            try? fileManager.removeItem(at: scratch)
            throw error
        }
        return PreparedWhisperAudio(url: output, scratchDirectory: scratch)
    }
}
