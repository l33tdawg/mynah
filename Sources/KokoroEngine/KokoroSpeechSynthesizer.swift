import Foundation
import SageVoiceCore

/// Kokoro, entirely in this process.
///
/// The last piece of the port. Every stage was built and verified separately —
/// `EspeakPhonemizer` for the front end, `KokoroTokenizer` for the vocabulary,
/// `KokoroVoices` for the style row, `KokoroSession` for the graph,
/// `SilenceTrim` and `AudioUpsampler` for what comes after — and this composes
/// them in the order `kokoro_onnx` composes its own, so the result is the same
/// audio the loopback server used to return.
///
/// ## What it replaces
///
/// A 309 MB virtual environment, a FastAPI server, a launchd job, a port, and an
/// HTTP round trip per sentence. `KokoroHTTPSynthesizer` spoke to that; this
/// speaks to nothing. The owner's words no longer cross a socket to be said out
/// loud, which was always the odd part of an appliance whose entire argument is
/// that they stay on his machine.
///
/// ## Order matters, in one place especially
///
/// Trimming happens **per batch, before concatenation** — not once at the end.
/// `kokoro_onnx` does the same and the comment there explains why: each batch
/// carries its own leading and trailing padding, so trimming the joined result
/// would leave every internal pad in place and put a pause in the middle of a
/// sentence.
public struct KokoroSpeechSynthesizer: SpeechSynthesizing {

    /// Kokoro emits 24 kHz; the phone bridge and Opus want 48. The doubling is
    /// exact rather than approximate — `AudioUpsampler` is a transcription of
    /// the `resample_poly` the Python server used, verified sample for sample —
    /// so this is the same audio at the same rate the app already consumes.
    public static let outputSampleRate = KokoroSession.sampleRate * 2

    /// The voice, from the one place that declares it.
    public static let defaultKokoroVoice = KokoroVoices.defaultVoiceName

    private let session: KokoroSession
    private let voices: KokoroVoices
    private let phonemizer: EspeakPhonemizer
    private let voice: String

    // MARK: - Construction

    /// Loads the model, the voices and the phoneme front end.
    ///
    /// Expensive — about three quarters of a second, nearly all of it the graph —
    /// and therefore done once. Paying it per request would double the latency of
    /// every spoken reply.
    public init(
        modelPath: URL = KokoroAssets.location(of: KokoroAssets.model),
        voicesPath: URL = KokoroAssets.location(of: KokoroAssets.voices),
        phonemizer: EspeakPhonemizer? = nil,
        voice: String = KokoroSpeechSynthesizer.defaultKokoroVoice
    ) throws {
        self.session = try KokoroSession(modelPath: modelPath)
        self.voices = try KokoroVoices(contentsOf: voicesPath)
        self.phonemizer = try phonemizer ?? EspeakPhonemizer()
        self.voice = voice
    }

    /// Builds one only if everything it needs is already on the machine.
    ///
    /// The model is fetched when Signal is linked, not shipped in the bundle, so
    /// at first launch it genuinely is not there. Returning `nil` lets the daemon
    /// fall back to the system voice for that one session rather than refusing to
    /// speak — and unlike a thrown error, it does so without a stack trace for a
    /// state that is expected.
    public static func ifReady(
        voice: String = KokoroSpeechSynthesizer.defaultKokoroVoice
    ) -> KokoroSpeechSynthesizer? {
        try? KokoroSpeechSynthesizer(voice: voice)
    }

    // MARK: - SpeechSynthesizing

    public var identifier: String { "kokoro-native" }

    public var defaultVoice: String { voice }

    /// Already loaded by the time this exists, so there is nothing to probe.
    ///
    /// The HTTP synthesizer had to ask a server whether it was alive; a model
    /// held in this process either loaded in `init` or the initialiser threw.
    public func isAvailable() async -> Bool { true }

    public func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechSynthesisError.emptyText }

        let started = Date()
        let resolvedVoice = request.voice ?? voice

        let phonemes: String
        do {
            phonemes = try phonemizer.phonemes(for: text)
        } catch {
            throw SpeechSynthesisError.backendUnavailable(
                "could not turn text into phonemes: \(error)"
            )
        }

        let samples = try await spokenSamples(
            phonemes: phonemes, voice: resolvedVoice, speed: Float(request.speed)
        )

        guard !samples.isEmpty else {
            // Punctuation, emoji, or anything else with no pronounceable
            // content. Silence would be indistinguishable from a broken voice.
            throw SpeechSynthesisError.malformedAudio(
                "nothing in \(text.debugDescription) could be spoken"
            )
        }

        let wav = WAVAudio.encode(
            pcm: AudioUpsampler.toInt16(AudioUpsampler.doubled(samples)),
            sampleRate: Self.outputSampleRate
        )
        let elapsed = Date().timeIntervalSince(started)

        return SynthesizedSpeech(
            wav: wav,
            sampleRate: Self.outputSampleRate,
            channelCount: 1,
            duration: Double(samples.count) / Double(KokoroSession.sampleRate),
            // Not a streaming backend: the assembled result is the first thing
            // the caller can play, so both timings are the whole call.
            timeToFirstAudio: elapsed,
            generationDuration: elapsed
        )
    }

    // MARK: - The stage the golden vectors describe

    /// The spoken audio at Kokoro's own 24 kHz, trimmed and concatenated but not
    /// yet resampled.
    ///
    /// Separated out because this is exactly the boundary the captured reference
    /// describes: `golden-trimmed.wav` is what Python held at this point, and
    /// comparing here tests text-to-phonemes, batching, style selection, the
    /// graph and the trim together, without folding in the upsampler that was
    /// already verified on its own.
    func spokenSamples(phonemes: String, voice: String, speed: Float) async throws -> [Float] {
        var samples: [Float] = []
        for batch in Self.batches(of: phonemes) {
            let ids = KokoroTokenizer.ids(for: batch)
            // A batch that survived splitting but contains nothing the
            // vocabulary knows — a run of emoji, say. Feeding it to the graph
            // would be padding alone, which `KokoroSession` refuses.
            guard !ids.isEmpty else { continue }

            let style = try voices.style(for: voice, tokenCount: ids.count)
            let audio = try await session.audio(phonemes: batch, style: style, speed: speed)
            samples.append(contentsOf: SilenceTrim.trimmed(audio))
        }
        return samples
    }

    /// Phonemes for `text`, for tests and diagnostics that need to see what the
    /// front end produced before the graph ran.
    func phonemes(for text: String) throws -> String {
        try phonemizer.phonemes(for: text)
    }

    // MARK: - Batching

    /// Splits phonemes into runs the model's 510-token context can hold,
    /// preferring to break at punctuation.
    ///
    /// A port of `kokoro_onnx._split_phonemes`, including the details that look
    /// like slips and are not: the comparison is `>=` rather than `>`, and a
    /// punctuation mark joins the batch **without** a preceding space while every
    /// other part gets one. Both decide where a long reply breaks, and a break in
    /// a different place is an audibly different pause.
    ///
    /// `SpeechTextSegmenter` has usually already reduced the text to one
    /// sentence, so most replies arrive as a single batch. This exists for the
    /// one that does not.
    static func batches(of phonemes: String) -> [String] {
        let separators: Set<Character> = [".", ",", "!", "?", ";"]
        // `re.split(r"([.,!?;])", …)` — the marks are kept as their own parts.
        var parts: [String] = []
        var current = ""
        for character in phonemes {
            if separators.contains(character) {
                parts.append(current)
                parts.append(String(character))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)

        var batches: [String] = []
        var batch = ""
        for rawPart in parts {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }

            // Counted in scalars, matching Python's `len` on a str. Counting
            // Characters would count `ˈoʊ` as fewer symbols than the tokenizer
            // will, and the batch would overrun the context it was sized for.
            let projected = batch.unicodeScalars.count + part.unicodeScalars.count + 1
            if projected >= KokoroTokenizer.maximumPhonemes {
                batches.append(batch.trimmingCharacters(in: .whitespaces))
                batch = part
            } else if part.count == 1, separators.contains(part.first!) {
                batch += part
            } else {
                if !batch.isEmpty { batch += " " }
                batch += part
            }
        }
        if !batch.isEmpty {
            batches.append(batch.trimmingCharacters(in: .whitespaces))
        }
        return batches.filter { !$0.isEmpty }
    }
}
