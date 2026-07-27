import Foundation

/// What the caller asks for: some text, optionally in a particular voice.
///
/// Everything except `text` has a default, so `SpeechRequest("hello")` is the
/// common case. `voice` and `speed` are advisory - a backend that does not
/// support them ignores them rather than failing.
public struct SpeechRequest: Sendable, Equatable {
    /// The text to speak. Must be non-empty after trimming.
    public var text: String

    /// Backend-specific voice identifier (e.g. `"am_puck"` for Kokoro,
    /// `"aiden"` for Qwen3-TTS). `nil` uses the backend default.
    public var voice: String?

    /// Speaking-rate multiplier. `1.0` is the backend's natural rate.
    public var speed: Double

    public init(text: String, voice: String? = nil, speed: Double = 1.0) {
        self.text = text
        self.voice = voice
        self.speed = speed
    }
}

/// A finished synthesis: WAV bytes plus the timings needed to reason about latency.
public struct SynthesizedSpeech: Sendable {
    /// A complete RIFF/WAVE container, 16-bit signed PCM. Playable as-is,
    /// writable to disk as-is, sendable over the wire as-is.
    public let wav: Data

    /// Sample rate of `wav`, in Hz.
    public let sampleRate: Int

    /// Number of channels in `wav`.
    public let channelCount: Int

    /// Duration of the synthesized audio, in seconds.
    public let duration: TimeInterval

    /// Wall-clock seconds from request start until the first audio byte was
    /// available. For non-streaming backends this equals `generationDuration`.
    public let timeToFirstAudio: TimeInterval

    /// Wall-clock seconds for the whole request, measured by the caller side.
    public let generationDuration: TimeInterval

    public init(
        wav: Data,
        sampleRate: Int,
        channelCount: Int,
        duration: TimeInterval,
        timeToFirstAudio: TimeInterval,
        generationDuration: TimeInterval
    ) {
        self.wav = wav
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.timeToFirstAudio = timeToFirstAudio
        self.generationDuration = generationDuration
    }

    /// Generation time divided by audio duration. Below `1.0` means the backend
    /// produces audio faster than it is spoken, which is what streaming playback
    /// needs in order not to stall.
    public var realTimeFactor: Double {
        duration > 0 ? generationDuration / duration : 0
    }

    /// Inverse of `realTimeFactor`: how many seconds of audio are produced per
    /// second of wall clock.
    public var speedFactor: Double {
        generationDuration > 0 ? duration / generationDuration : 0
    }
}

/// Text in, WAV bytes out.
///
/// Deliberately narrow: the agent loop hands over a finished sentence and gets
/// back something it can play or forward to the phone. Backends that stream
/// internally still return the assembled result, and report when the first
/// audio became available via `SynthesizedSpeech.timeToFirstAudio`.
public protocol SpeechSynthesizing: Sendable {
    /// Stable short name for logs and metrics, e.g. `"kokoro-http"`.
    var identifier: String { get }

    /// Voice used when `SpeechRequest.voice` is `nil`.
    var defaultVoice: String { get }

    /// Cheap liveness probe. Returns `false` instead of throwing so callers can
    /// pick a fallback backend without exception plumbing.
    func isAvailable() async -> Bool

    /// Synthesize `request` and return the complete audio.
    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech
}

public extension SpeechSynthesizing {
    /// Convenience for the overwhelmingly common call site.
    func synthesize(text: String) async throws -> SynthesizedSpeech {
        try await synthesize(SpeechRequest(text: text))
    }

    /// Split `text` on sentence boundaries and synthesize each piece in order,
    /// invoking `onSegment` as soon as each one is ready.
    ///
    /// This is how you get a low time-to-first-word out of a backend that has no
    /// internal streaming: the first sentence of a three-sentence reply is
    /// usually ready in well under a second, and playback of sentence *n* covers
    /// the synthesis of sentence *n+1* as long as the backend runs faster than
    /// real time.
    ///
    /// - Parameters:
    ///   - text: Full reply text.
    ///   - voice: Voice identifier, or `nil` for the backend default.
    ///   - speed: Speaking-rate multiplier.
    ///   - maximumSegmentLength: Sentences longer than this are further split on
    ///     clause punctuation, then on whitespace, so one runaway sentence cannot
    ///     block the first audio.
    ///   - onSegment: Called on the calling task, in order, once per segment.
    func synthesizeBySentence(
        text: String,
        voice: String? = nil,
        speed: Double = 1.0,
        maximumSegmentLength: Int = 240,
        onSegment: (SynthesizedSpeech, Int) async throws -> Void
    ) async throws {
        let segments = SpeechTextSegmenter.segments(for: text, maximumLength: maximumSegmentLength)
        guard !segments.isEmpty else {
            throw SpeechSynthesisError.emptyText
        }
        for (index, segment) in segments.enumerated() {
            let speech = try await synthesize(SpeechRequest(text: segment, voice: voice, speed: speed))
            try await onSegment(speech, index)
        }
    }
}

/// Failure modes shared by every synthesizer backend.
public enum SpeechSynthesisError: Error, Equatable, CustomStringConvertible {
    /// The request text was empty or whitespace only.
    case emptyText
    /// The configured endpoint is not on loopback. Synthesis endpoints carry the
    /// owner's words; we refuse to send them off-box.
    case nonLoopbackEndpoint(String)
    /// The backend answered with a non-2xx status. Payload is the status code
    /// and any short body the server returned.
    case badResponse(Int, String)
    /// The transport failed (connection refused, timeout, ...).
    case requestFailed(String)
    /// The backend answered 2xx but the body was not a WAV we can read.
    case malformedAudio(String)
    /// The backend is reachable but reported that it cannot synthesize right now.
    case backendUnavailable(String)

    public var description: String {
        switch self {
            case .emptyText:
                return "Nothing to speak: the request text was empty."
            case let .nonLoopbackEndpoint(endpoint):
                return "Refusing to send speech text to a non-loopback endpoint (\(endpoint))."
            case let .badResponse(status, body):
                let detail = body.isEmpty ? "" : " - \(body)"
                return "Speech backend returned HTTP \(status)\(detail)."
            case let .requestFailed(reason):
                return "Speech request failed: \(reason)"
            case let .malformedAudio(reason):
                return "Speech backend returned unreadable audio: \(reason)"
            case let .backendUnavailable(reason):
                return "Speech backend unavailable: \(reason)"
        }
    }
}

/// Splits reply text into speakable segments.
///
/// Not a linguist. It walks the string once, breaks after `.`/`!`/`?`/newline
/// when the next character looks like a boundary, and then hard-splits anything
/// still longer than `maximumLength`.
public enum SpeechTextSegmenter {
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "\n"]
    private static let clauseTerminators: Set<Character> = [";", ":", ",", "-"]

    public static func segments(for text: String, maximumLength: Int = 240) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        var current = ""
        let characters = Array(trimmed)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            current.append(character)

            if sentenceTerminators.contains(character) {
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                var breaks = character == "\n" || next == " " || next == "\n"

                // "next character is a space" is not enough to call it a sentence
                // end. Abbreviations are followed by a space too, so it split
                // "9 a.m. today" into ["…since 9 a.m.", "today."] and
                // "Ping Dr. Smith" into ["Ping Dr.", "Smith…"] — the owner hears
                // "Ping Doctor." [pause] "Smith about the mini."
                // Times, titles and initialisms are routine in an agent status
                // reply, so this fired constantly.
                if breaks && character == "." && endsWithAbbreviation(current) {
                    breaks = false
                }

                // A real sentence end is also followed by a capital or a digit;
                // a lowercase continuation means we are mid-sentence.
                if breaks && character == "." {
                    let following = characters[(index + 1)...].first { $0 != " " && $0 != "\n" }
                    if let following, following.isLowercase {
                        breaks = false
                    }
                }

                if breaks {
                    appendIfMeaningful(current, to: &sentences)
                    current = ""
                }
            }
            index += 1
        }
        appendIfMeaningful(current, to: &sentences)

        return sentences.flatMap { split($0, maximumLength: maximumLength) }
    }

    /// Common abbreviations that end in a period without ending a sentence.
    /// Matched against the tail of the text accumulated so far.
    private static let abbreviations: Set<String> = [
        "a.m.", "p.m.", "e.g.", "i.e.", "etc.", "vs.", "approx.", "no.",
        "dr.", "mr.", "mrs.", "ms.", "prof.", "st.", "jr.", "sr.",
        "u.s.", "u.k.", "inc.", "ltd.", "co.", "fig.", "cf.", "al.",
    ]

    private static func endsWithAbbreviation(_ text: String) -> Bool {
        // Last whitespace-delimited token, lowercased.
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).last else {
            return false
        }
        let lowered = String(token).lowercased()
        if abbreviations.contains(lowered) { return true }

        // A single initial ("J.") or a dotted initialism ("U.S.A.") — any token
        // whose letters are all single characters between dots.
        let parts = lowered.split(separator: ".", omittingEmptySubsequences: true)
        return parts.count >= 1 && parts.allSatisfy { $0.count == 1 && $0.first!.isLetter }
    }

    /// Splits a single over-long token into budget-sized pieces so no segment
    /// can exceed `maximumLength`. Text with no spaces (CJK, a long URL) would
    /// otherwise never be split at all.
    private static func hardChop(_ token: String, maximumLength: Int) -> [String] {
        guard maximumLength > 0, token.count > maximumLength else { return [token] }
        var pieces: [String] = []
        var index = token.startIndex
        while index < token.endIndex {
            let end = token.index(index, offsetBy: maximumLength, limitedBy: token.endIndex) ?? token.endIndex
            pieces.append(String(token[index..<end]))
            index = end
        }
        return pieces
    }

    private static func appendIfMeaningful(_ candidate: String, to sentences: inout [String]) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentences.append(trimmed)
    }

    private static func split(_ sentence: String, maximumLength: Int) -> [String] {
        guard maximumLength > 0, sentence.count > maximumLength else { return [sentence] }

        var pieces: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            // A single token can exceed the whole budget — a file path, a URL, a
            // base64 or JSON blob quoted back from a tool result, or CJK text
            // with no spaces at all. The old `!current.isEmpty` guard let such a
            // token through whole, so the first-audio guarantee did not hold.
            // Hard-chop anything over budget before it can become a segment.
            for chunk in hardChop(String(word), maximumLength: maximumLength) {
                let candidate = current.isEmpty ? chunk : current + " " + chunk
                if candidate.count > maximumLength, !current.isEmpty {
                    pieces.append(current)
                    current = chunk
                } else {
                    current = candidate
                }
            }
            // Prefer breaking right after a clause terminator once we are past
            // half the budget, so the pieces sound less arbitrary.
            if let last = current.last,
               clauseTerminators.contains(last),
               current.count >= maximumLength / 2 {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces.isEmpty ? [sentence] : pieces
    }
}
