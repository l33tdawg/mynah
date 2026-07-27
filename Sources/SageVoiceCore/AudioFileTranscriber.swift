import Foundation

public struct AudioTranscriptionOptions: Equatable, Sendable {
    public var initialPrompt: String?

    public init(initialPrompt: String? = nil) {
        let trimmed = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialPrompt = trimmed?.isEmpty == false ? trimmed : nil
    }

    public static let none = AudioTranscriptionOptions()
}

public struct TranscribedWordTiming: Codable, Equatable, Sendable {
    public var word: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var confidence: Double?

    public init(word: String, startSeconds: Double, endSeconds: Double, confidence: Double? = nil) {
        self.word = word
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }
}

public struct TimedTranscriptionResult: Codable, Equatable, Sendable {
    public var text: String
    public var words: [TranscribedWordTiming]

    public init(text: String, words: [TranscribedWordTiming] = []) {
        self.text = text
        self.words = words
    }
}

public protocol AudioFileTranscribing: Sendable {
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String
}

public extension AudioFileTranscribing {
    func transcribe(audioFile: URL) async throws -> String {
        try await transcribe(audioFile: audioFile, options: .none)
    }

    func transcribeWithTiming(audioFile: URL, options: AudioTranscriptionOptions) async throws -> TimedTranscriptionResult {
        let text = try await transcribe(audioFile: audioFile, options: options)
        return TimedTranscriptionResult(text: text)
    }
}

public enum AudioTranscriberError: Error, Equatable {
    case nonLoopbackEndpoint(String)
    case emptyTranscript
    case noiseOnlyTranscript(String)
    case badResponse(Int)
    case requestFailed(String)
    case allBackendsFailed([String])
}

public struct NoopAudioFileTranscriber: AudioFileTranscribing {
    public init() {}

    public func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        throw AudioTranscriberError.emptyTranscript
    }
}
