import Foundation
import Security

/// The `//call` command: a link to talk to the appliance out loud.
///
/// A slash command rather than an intent the model classifies. "Call me" is
/// something an owner might also say *about* someone else, and the cost of
/// getting it wrong is a microphone opening on their phone. An explicit `//call`
/// cannot be reached by accident or by a model misreading a sentence.
public enum CallInvitation {

    /// What the owner types. Anchored, so a message that merely mentions it —
    /// "how do I use //call" — is a question, not a command.
    public static let command = "//call"

    public static func isRequest(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == command || trimmed.hasPrefix(command + " ")
    }

    /// `//help`, because nothing else discovers a slash command.
    ///
    /// The owner is in a Signal thread, not reading a README, and a command
    /// nobody has told them about does not exist as far as they are concerned.
    /// This is the only place a feature like //call can announce itself at the
    /// moment somebody wonders whether there is one.
    public static let helpCommand = "//help"

    public static func isHelpRequest(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == helpCommand || trimmed == "//commands" || trimmed == "//?"
    }

    /// What `//help` says.
    ///
    /// Describes what calling needs as part of the list rather than as a
    /// footnote, so an owner on a local model learns why //call will refuse
    /// before they try it and are told no.
    ///
    /// **Takes the refusal, not a Bool and not a model name.** A Bool could only
    /// say *whether* calling works, so this branch had to re-author *why* — and
    /// it authored the model reason, because that was the only barrier the Bool
    /// knew about. On a Mac with no relay secret it therefore promised "switch
    /// to an API model in Mynah and it will work" to an owner for whom that is
    /// false. The `model` argument went with it: the caller was digging the name
    /// back out of the refusal to hand it to a function that already had the
    /// refusal. One source for the reason means the help text cannot drift from
    /// the refusal it describes.
    public static func help(callRefusal: Refusal?) -> String {
        let calling = callRefusal.map { "//call — a voice call. Not yet: \($0.sentence)" }
            ?? "//call — I set up a voice call and send you a link. Tap it and talk; you can interrupt me any time."

        return """
            Things you can say:

            \(calling)

            //help — this.

            Anything else is just a question. Talk normally — text or a voice \
            note, whichever suits. I remember what we have talked about.
            """
    }

    /// Why a call cannot happen, in words the owner can act on.
    ///
    /// **There used to be two barriers and now there is one.** A `backendTooSlow`
    /// case refused every brain running on this Mac, on a measured floor of
    /// 40–60 seconds to first token — real at the time, and dead by the time it
    /// was deleted. See `refusal(isSetUpForCalls:)` for what changed.
    ///
    /// What is left is the barrier that is actually a barrier: a Mac with no
    /// relay secret cannot place a call however fast its brain is.
    public enum Refusal: Sendable, Equatable {
        /// This Mac has never been set up for calls.
        case notSetUpForCalls
        case couldNotStart(String)

        public var sentence: String {
            switch self {
            case .notSetUpForCalls:
                // No path, deliberately. `CallHost.Failure.noSharedSecret` says
                // it the same way and for the same reason: a file he has never
                // seen is not a next step, it is a puzzle.
                return "This Mac hasn't been set up for calls yet. Voice notes still work."
            case .couldNotStart(let reason):
                return "I couldn't start the call: \(reason)"
            }
        }
    }

    /// Whether this Mac can place a call.
    ///
    /// **The brain is no longer part of the test, and the old comment here
    /// predicted its own deletion.** It read: *"A local model that got fast
    /// enough would need this revisited — the property that matters is time to
    /// first token, and `isLocal` is a proxy for it that happens to be exactly
    /// right on this hardware today."*
    ///
    /// That condition arrived. The proxy was calibrated when a local brain took
    /// 40–60 seconds to first token; on 29 July 2026 the owner sent a screenshot
    /// of `qwen3.5:4b` — running on this Mac, `keepsWordsOnDevice` — answering
    /// three questions in **5, 6 and 9 seconds**, two of them with a SAGE tool
    /// call inside. Nothing about the model changed. What changed is that tool
    /// results stopped arriving 31KB at a time, and the model was never the
    /// thing that was slow.
    ///
    /// So the refusal was measuring the wrong property through a proxy that had
    /// gone stale underneath it, which is the more useful lesson: `isLocal` was
    /// never *time to first token*, it was a thing that correlated with it once.
    ///
    /// **If a call on a local brain does turn out to be a dead line, the fix is
    /// to measure time to first token, not to reinstate the proxy.** A slow
    /// cloud model would have sailed straight past the old check too.
    public static func refusal(isSetUpForCalls: Bool) -> Refusal? {
        isSetUpForCalls ? nil : .notSetUpForCalls
    }

    /// An unguessable path segment.
    ///
    /// The link *is* the credential. It travels over Signal — authenticated and
    /// end-to-end encrypted, readable only by the owner — so the only thing
    /// standing between a live microphone and anyone who can reach the port is
    /// that nobody else can guess the path. 32 hex characters is 128 bits.
    public static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The sentence sent to the owner with the link.
    ///
    /// Two lines and no warnings to explain away. The page is served with a real
    /// certificate now, so there is no security interstitial to talk the owner
    /// through — which was never just an inconvenience: it was what stopped the
    /// browser persisting a microphone permission, and so what stopped calls
    /// connecting at all.
    public static func invitation(url: String) -> String {
        """
        Tap to talk to me: \(url)

        Allow the microphone when it asks. You can interrupt me any time.
        """
    }
}
