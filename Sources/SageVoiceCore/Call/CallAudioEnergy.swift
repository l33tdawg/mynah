import Foundation

/// How loud a captured segment actually was.
///
/// ## Why this exists
///
/// Whisper fills silence with phrases from its training data. `HeardSpeech`
/// catches the unambiguous ones — "thanks for watching", "please subscribe" —
/// and deliberately lets "thank you" through, because that comment is right:
/// filtering it once cost the owner a real turn, and the costs are not
/// symmetric. Ignoring your owner is much worse than thanking a quiet room.
///
/// But on 1 August a call went like this:
///
///     14:09:11  heard: Can you check what's on our task list?
///     14:09:12  said "Let me check your backlog."
///     14:09:20  said "Still on it."
///     …
///     heard: Thank you.        ← nobody spoke
///
/// and the invented "Thank you." became a new turn, which cancelled the answer
/// being prepared. So the third cost appeared: a hallucination does not merely
/// say something silly, it *replaces the question you are waiting on*.
///
/// **The text cannot separate those two cases and the audio can.** A person
/// saying "thank you" produces a segment with speech in it. A hallucination
/// arises from a segment with none. So this measures the sound rather than
/// arguing about the words, and `HeardSpeech` uses it only to break the tie on
/// the handful of phrases that are ambiguous — never to discard speech that was
/// genuinely loud enough to be speech.
public enum CallAudioEnergy {

    /// Root-mean-square amplitude of 16-bit mono PCM, on the sample scale
    /// (0…32767). Nil when the bytes are not a WAV this can read — unknown is
    /// not the same as quiet, and a caller must not treat it as such.
    public static func rootMeanSquare(ofWAV wav: Data) -> Double? {
        guard let samples = pcmRange(in: wav), !samples.isEmpty else { return nil }

        var sum = 0.0
        var index = samples.lowerBound
        while index + 1 < samples.upperBound {
            let low = Int16(wav[index])
            let high = Int16(bitPattern: UInt16(wav[index + 1]) << 8)
            let sample = Double(Int16(clamping: Int(high) | Int(low)))
            sum += sample * sample
            index += 2
        }
        let count = Double((samples.count) / 2)
        guard count > 0 else { return nil }
        return (sum / count).squareRoot()
    }

    /// Below this, the segment holds no speech.
    ///
    /// **Deliberately far under any speaking voice.** Measured against this
    /// appliance's own logs, where the Go segmenter reports its adaptive
    /// thresholds — `noise floor 145, speech above 363` on a first turn,
    /// settling to `72 / 180` once the room was characterised. Those are the
    /// levels at which it is prepared to call something speech, so anything
    /// beneath the *lowest* noise floor it has ever reported is not a quiet
    /// talker, it is a room.
    ///
    /// Erring low on purpose. A mumbled "thank you" must survive this; only
    /// something with no voice in it at all should not. If this is ever wrong it
    /// should be wrong by letting a hallucination through, which is the failure
    /// the product already tolerated for months.
    public static let silenceCeiling: Double = 60

    /// Whether the segment is quiet enough that nothing was said in it.
    ///
    /// `false` when the audio cannot be read: refusing to guess is the safe
    /// direction, because the only thing this is used for is discarding a turn.
    public static func isSilent(_ wav: Data) -> Bool {
        guard let rms = rootMeanSquare(ofWAV: wav) else { return false }
        return rms < silenceCeiling
    }

    /// The byte range of the `data` chunk.
    ///
    /// Found rather than assumed at offset 44. That is the common layout and it
    /// is not the only one — a `LIST`/`INFO` chunk before `data` is legal and
    /// ordinary, and skipping a fixed 44 bytes would then measure chunk headers
    /// as if they were audio, which reads as loud noise and would defeat the
    /// whole check.
    static func pcmRange(in wav: Data) -> Range<Data.Index>? {
        guard wav.count > 12,
              wav[wav.startIndex ..< wav.startIndex + 4].elementsEqual(Array("RIFF".utf8)),
              wav[wav.startIndex + 8 ..< wav.startIndex + 12].elementsEqual(Array("WAVE".utf8)) else {
            return nil
        }

        var cursor = wav.startIndex + 12
        while cursor + 8 <= wav.endIndex {
            let identifier = wav[cursor ..< cursor + 4]
            let size = (0..<4).reduce(0) { total, offset in
                total | Int(wav[cursor + 4 + offset]) << (8 * offset)
            }
            let body = cursor + 8
            guard size >= 0, body <= wav.endIndex else { return nil }
            if identifier.elementsEqual(Array("data".utf8)) {
                return body ..< min(body + size, wav.endIndex)
            }
            // Chunks are word-aligned: an odd size carries a pad byte.
            cursor = body + size + (size % 2)
        }
        return nil
    }
}
