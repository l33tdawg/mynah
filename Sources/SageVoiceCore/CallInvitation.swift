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
    /// **There are two barriers, and this used to name only the first.** The
    /// model check ran alone, so an owner on a local brain was told *"switch to
    /// an API model and try again"* — and on this Mac, where
    /// `~/.sage/call-relay.secret` does not exist, doing exactly that lands him
    /// on "this Mac hasn't been set up for calls yet". We sent him to change his
    /// brain to fix a problem changing his brain does not fix.
    ///
    /// A refusal that names one of two blockers is not a smaller truth, it is a
    /// wrong instruction. So the model barrier now carries whether the other one
    /// is also standing, and says so in the same breath.
    public enum Refusal: Sendable, Equatable {
        /// `alsoNeedsSetup` when the relay secret is missing too, so switching
        /// brains alone would not get him a call.
        case backendTooSlow(model: String, alsoNeedsSetup: Bool)
        /// The brain is fast enough; this Mac has never been set up for calls.
        case notSetUpForCalls
        case couldNotStart(String)

        public var sentence: String {
            switch self {
            case .backendTooSlow(let model, let alsoNeedsSetup):
                // Not a limitation to hide. A local 4B takes 40-60 seconds to
                // produce a first token on this hardware; in a message that is
                // a wait, and in a call it is a dead line. Saying which model
                // and what to do about it beats "calling is unavailable".
                let head = "Calling needs a fast model, and \(model) runs on this Mac — it takes "
                    + "the best part of a minute to answer, which works in messages and not in a "
                    + "call."
                guard alsoNeedsSetup else {
                    return head + " Switch to an API model and try again. Voice notes still "
                        + "work either way."
                }
                // Both, in one message. Told separately these become two trips:
                // switch the brain, try again, get refused for a different
                // reason he was never warned about.
                return head + " This Mac also hasn't been set up for calls yet, so that needs "
                    + "doing as well — switching to an API model on its own won't be enough. "
                    + "Voice notes still work either way."
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

    /// Whether the backend can hold a conversation.
    ///
    /// The test is `isLocal`, not a model allowlist. Anything running on this
    /// Mac is competing with the appliance itself for the same GPU, and the
    /// measured floor here is tens of seconds to first token. A cloud model
    /// answers in single digits, which is the difference between a call and a
    /// silence.
    ///
    /// A local model that got fast enough would need this revisited — the
    /// property that matters is time to first token, and `isLocal` is a proxy
    /// for it that happens to be exactly right on this hardware today.
    ///
    /// `isSetUpForCalls` is the second barrier and must be passed rather than
    /// assumed. It defaults to nothing, because a default would be a guess about
    /// the owner's filesystem made inside a pure function — and guessing `true`
    /// is precisely the bug: it is what let the model check answer for both.
    public static func refusal(
        forBackend backend: BrainBackend,
        isSetUpForCalls: Bool
    ) -> Refusal? {
        guard backend.isLocal else {
            return isSetUpForCalls ? nil : .notSetUpForCalls
        }
        return .backendTooSlow(model: backend.modelName, alsoNeedsSetup: !isSetUpForCalls)
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
