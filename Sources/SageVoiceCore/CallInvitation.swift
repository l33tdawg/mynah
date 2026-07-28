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
    public static func help(callingAvailable: Bool, model: String) -> String {
        let calling = callingAvailable
            ? "//call — I set up a voice call and send you a link. Tap it and talk; you can interrupt me any time."
            : "//call — a voice call. Not available on \(model), which runs on this Mac and takes the best part "
                + "of a minute to answer. Switch to an API model in Mynah and it will work. Voice notes work either way."

        return """
            Things you can say:

            \(calling)

            //help — this.

            Anything else is just a question. Talk normally — text or a voice \
            note, whichever suits. I remember what we have talked about.
            """
    }

    /// Why a call cannot happen, in words the owner can act on.
    public enum Refusal: Sendable, Equatable {
        case backendTooSlow(model: String)
        case couldNotStart(String)

        public var sentence: String {
            switch self {
            case .backendTooSlow(let model):
                // Not a limitation to hide. A local 4B takes 40-60 seconds to
                // produce a first token on this hardware; in a message that is
                // a wait, and in a call it is a dead line. Saying which model
                // and what to do about it beats "calling is unavailable".
                return "Calling needs a fast model, and \(model) runs on this Mac — it takes "
                    + "the best part of a minute to answer, which works in messages and not in a "
                    + "call. Switch to an API model and try again. Voice notes still work either way."
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
    public static func refusal(forBackend backend: BrainBackend) -> Refusal? {
        backend.isLocal ? .backendTooSlow(model: backend.modelName) : nil
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
