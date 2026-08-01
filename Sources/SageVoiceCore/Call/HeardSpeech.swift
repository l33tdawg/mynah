import Foundation

/// Decides whether recognition actually heard something.
///
/// Whisper does not return an empty string for silence. It confabulates, and it
/// confabulates the same handful of phrases every time, because they are what
/// its training data contained wherever there was nothing to hear: the closing
/// courtesies and channel sign-offs of millions of subtitled videos.
///
/// Observed live, on a call with no one talking:
///
///     [call] heard: ありがとうございました
///     [call] replying: どういたしまして。 Ready when you are…
///
/// Nobody had said anything. Recognition was already locked to English and the
/// language parameter is passed to the backend — it does not suppress this, and
/// the model then answered politely in Japanese, and an English voice spent ten
/// seconds trying to pronounce it.
///
/// This is not general-purpose language detection. It is a narrow filter for a
/// specific, well-known artefact, applied where the cost of a false negative is
/// an appliance answering a question nobody asked.
public enum HeardSpeech {

    /// The phrases Whisper reaches for when there is nothing to transcribe.
    ///
    /// Compared after normalisation, so punctuation and case do not matter. Kept
    /// short deliberately: every entry here is a phrase a caller might one day
    /// genuinely say, and the length guard below is what keeps that safe.
    /// Only phrases nobody says to an appliance.
    ///
    /// This list was longer and it cost the owner a turn: "thanks" was filtered
    /// as an artefact and the call simply did not answer. A short "thank you" is
    /// both what Whisper invents over silence AND one of the most ordinary
    /// things anyone says to an assistant, and no amount of length checking
    /// separates them.
    ///
    /// The costs are not symmetric. Filtering real speech means the appliance
    /// ignores its owner, who has no idea why. Not filtering a hallucination
    /// means it says "you're welcome" to a quiet room, which is a curiosity. So
    /// this keeps only what is unambiguously subtitle furniture — nobody
    /// telephones their own Mac to say "thanks for watching" — and lets the
    /// rest through.
    static let stockPhrases: Set<String> = [
        "ありがとうございました",
        "ご視聴ありがとうございました",
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
        "subtitles by the amaraorg community",
        "amaraorg",
        "blankaudio"
    ]

    /// Whether a transcript should be treated as nothing having been said.
    ///
    /// - Parameters:
    ///   - transcript: what recognition returned.
    ///   - milliseconds: how much audio produced it. A stock phrase over four
    ///     seconds of audio is a caller who really did say it; the same phrase
    ///     over half a second is the artefact.
    /// Phrases that are both what Whisper invents over silence and ordinary
    /// things to say to an assistant.
    ///
    /// **Not in `stockPhrases`, and that is deliberate** — the comment above
    /// records what filtering these outright cost: a caller said "thanks", the
    /// call ignored them, and they had no way to know why.
    ///
    /// So they are filtered only when the audio says nobody spoke, which is a
    /// fact about the sound rather than an argument about the words. When the
    /// segment has speech in it, every one of these is taken at face value
    /// exactly as before.
    static let phrasesOnlyDiscardedInSilence: Set<String> = [
        "thank you",
        "thanks",
        "thank you very much",
        "thanks very much",
        "you",
        "bye",
        "goodbye",
        "okay",
        "ok",
        "mm",
        "mhm",
        "uh",
        "um"
    ]

    /// - Parameter cameFromSilence: the captured audio contained no speech. See
    ///   `CallAudioEnergy`. Defaults to `false`, so a caller that cannot measure
    ///   gets exactly the previous behaviour.
    public static func isNothing(
        _ transcript: String,
        milliseconds: Int,
        cameFromSilence: Bool = false
    ) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        // Nothing but punctuation, dots or musical notes — the other shape this
        // takes.
        if trimmed.rangeOfCharacter(from: .alphanumerics) == nil { return true }

        let normalised = normalise(trimmed)

        // A stock phrase from a short utterance. The length guard is what makes
        // this safe: "thank you" is a thing people say, and at four seconds of
        // audio it is taken at face value.
        if milliseconds < 4000, stockPhrases.contains(normalised) { return true }

        // The ambiguous ones, and only when the microphone heard nothing.
        //
        // **This is the case that cancelled an answer.** On 1 August the owner
        // asked what was on the task list, Mynah said "Let me check your
        // backlog", and an invented "Thank you." arrived while it was working —
        // which `replaceTurn` treats as a new question, so it cancelled the
        // reply being prepared. A hallucination does not merely say something
        // silly; it takes away the answer somebody is waiting for.
        //
        // Guarded on the audio rather than the text, because the text of a real
        // "thank you" and an invented one are identical and always will be.
        if cameFromSilence, phrasesOnlyDiscardedInSilence.contains(normalised) { return true }

        // No Latin letters at all, while recognition is locked to English.
        //
        // A caller who genuinely switches to Japanese mid-call deserves better
        // than this, and will not get it while the backend is told to expect
        // English — but the alternative is the appliance conducting both halves
        // of a conversation in a language nobody spoke.
        if !trimmed.contains(where: { $0.isLetter && $0.isASCII }) { return true }

        return false
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }
}
