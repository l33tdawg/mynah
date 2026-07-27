import Foundation

public enum DictationSessionState: String, Codable, Equatable, Sendable {
    case idle
    case capturing
    case finalizing
    case inserting
    case completed
    case cancelled
    case failed
}

public struct DictationTiming: Codable, Equatable, Sendable {
    public var timeToAudioStartMS: Int?
    public var firstPartialASRMS: Int?
    public var firstStableSegmentMS: Int?
    public var keyReleaseToInsertMS: Int?
    public var semanticEditorLatencyMS: Int?
    public var insertionLatencyMS: Int?
    public var totalSessionDurationMS: Int?

    public init(
        timeToAudioStartMS: Int? = nil,
        firstPartialASRMS: Int? = nil,
        firstStableSegmentMS: Int? = nil,
        keyReleaseToInsertMS: Int? = nil,
        semanticEditorLatencyMS: Int? = nil,
        insertionLatencyMS: Int? = nil,
        totalSessionDurationMS: Int? = nil
    ) {
        self.timeToAudioStartMS = timeToAudioStartMS
        self.firstPartialASRMS = firstPartialASRMS
        self.firstStableSegmentMS = firstStableSegmentMS
        self.keyReleaseToInsertMS = keyReleaseToInsertMS
        self.semanticEditorLatencyMS = semanticEditorLatencyMS
        self.insertionLatencyMS = insertionLatencyMS
        self.totalSessionDurationMS = totalSessionDurationMS
    }
}

public struct DictationSessionResult: Codable, Equatable, Sendable {
    public var text: String
    public var rawTranscript: String
    public var context: AppContext
    public var timing: DictationTiming

    public init(text: String, rawTranscript: String, context: AppContext, timing: DictationTiming) {
        self.text = text
        self.rawTranscript = rawTranscript
        self.context = context
        self.timing = timing
    }
}

public struct RuntimeConfiguration: Codable, Equatable, Sendable {
    public var strictOfflineMode: Bool
    public var memoryBackendMode: MemoryBackendMode
    public var recallLimit: Int

    public init(
        strictOfflineMode: Bool = true,
        memoryBackendMode: MemoryBackendMode = .sqliteOnly,
        recallLimit: Int = 8
    ) {
        self.strictOfflineMode = strictOfflineMode
        self.memoryBackendMode = memoryBackendMode
        self.recallLimit = recallLimit
    }
}
