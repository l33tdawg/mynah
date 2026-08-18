import Foundation

/// What the owner is actually told when a voice note could not be turned into
/// text.
///
/// **The refusal existed, was correct, named the next action — and stopped at
/// the log.** `WhisperAudioConversionError` was written for this exact moment:
/// every case names the program and what to do about it, and the cascade
/// carries it faithfully from the converter all the way up to `handle`. There
/// the daemon caught it, logged it, and replied the same six words it replies
/// for a truncated download — *"I couldn't read that voice note."*
///
/// On a Linux box without ffmpeg that is every WhatsApp Ogg/Opus note and every
/// Signal m4a one, which is to say 100% of spoken messages, on the one feature
/// the port exists to keep. The owner has whisper.cpp installed and working,
/// the missing piece is one `apt install` away, and the sentence saying so was
/// sitting in `bridge.log` where nobody was looking. A failure that names
/// itself only to the machine is a silent failure with extra steps.
///
/// This is the seam that picks the reason back out and puts it in the thread.
///
/// **It is a string match, and that is not an accident of laziness.**
/// `LocalASRCascade` flattens every backend's error to `String(describing:)`
/// before it throws `allBackendsFailed`, so by the time the daemon has it the
/// type is gone and the text is all that survives. Widening that enum to carry
/// errors instead of strings is the better fix and a larger one; until then the
/// markers below are pinned by `TheRefusalReachesTheOwnerTests`, which builds
/// all five cases and fails if the prose ever drifts out from under them.
enum UnreadableVoiceNote {

    /// Unchanged, and still the whole of the right answer for audio that is
    /// simply broken — a truncated download, a file with no audio track, a
    /// recogniser that ran fine and heard nothing. There is nothing to install
    /// and nothing to fix, so a paragraph about ffmpeg would be noise dressed
    /// up as help.
    ///
    /// It also stays the opening sentence when a reason *is* appended: the
    /// owner should read the same first line every time a note fails, and the
    /// detail after it is the part that varies.
    static let generic = "I couldn't read that voice note."

    /// The sentence to send, given every failure the batch produced.
    ///
    /// The first reason wins rather than all of them being concatenated: a
    /// batch of three notes on a machine with no ffmpeg fails three identical
    /// ways, and the owner needs the install command once.
    static func refusal(for failures: [Error]) -> String {
        guard let reason = failures.lazy.compactMap({ self.reason(in: $0) }).first else {
            return generic
        }
        return generic + " " + reason
    }

    /// The owner-facing reason this failure carries, if it carries one.
    ///
    /// `nil` means "nothing here is fit to show him" — a whisper.cpp exit code
    /// and eighty lines of its stderr are a debugging artefact, not an answer,
    /// and pasting them into Signal would be a different kind of failing to
    /// communicate.
    static func reason(in failure: Error) -> String? {
        // Thrown straight through, which is what happens when the transcriber
        // is the whisper.cpp backend itself rather than the cascade in front of
        // it. Free of charge and exact, so it is tried first.
        if let conversion = failure as? WhisperAudioConversionError {
            return conversion.description
        }
        // The ordinary path. Each element is one backend's `String(describing:)`,
        // in the order the cascade tried them.
        if case let AudioTranscriberError.allBackendsFailed(reasons) = failure {
            return reasons.first(where: namesTheConverter)
        }
        return nil
    }

    /// Is this flattened reason one of `WhisperAudioConversionError`'s?
    ///
    /// Two markers because the enum has two shapes. `converterMissing` opens by
    /// describing the file and carries `installInstruction` — a shared constant,
    /// so that half cannot drift at all. The four cases that actually ran the
    /// program all open `"ffmpeg at <path>"`.
    ///
    /// A *prefix* match on that second one, deliberately: a `contains` would let
    /// any transcript or stderr dump that happened to mention ffmpeg through,
    /// and the whole point of this predicate is that it says no to everything
    /// which is not a refusal written for the owner.
    static func namesTheConverter(_ reason: String) -> Bool {
        reason.hasPrefix(converterSentenceOpening)
            || reason.contains(WhisperAudioConverter.installInstruction)
    }

    private static let converterSentenceOpening = "ffmpeg at "
}
