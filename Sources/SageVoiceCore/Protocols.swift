import Foundation

public protocol ASRBackend: Sendable {
    func startSession(profile: DictationProfile) async throws
    func pushAudio(_ frame: AudioFrame) async throws
    func partialTranscript() async throws -> String
    func stableSegments() async throws -> [StableSegment]
    func finish() async throws -> [StableSegment]
    func cancel() async
}

public protocol SemanticEditor: Sendable {
    func edit(_ request: EditorRequest) async throws -> EditorResult
}

public protocol ContextCollecting: Sendable {
    func currentContext() async throws -> AppContext
}

public protocol TextInserting: Sendable {
    func insert(_ text: String, into context: AppContext) async throws
}

public struct AudioFrame: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    public var timestamp: TimeInterval

    public init(samples: [Float], sampleRate: Int, timestamp: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }
}

public enum LocalTypeError: Error, Equatable {
    case secureInputBlocked(String)
    case emptyDictation
    case editorReturnedEmptyText
    case insertionFailed(String)
    case invalidSessionState(String)
}
