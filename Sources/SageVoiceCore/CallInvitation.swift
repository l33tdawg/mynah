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

    /// Why a call cannot happen, in words the owner can act on.
    public enum Refusal: Sendable, Equatable {
        case backendTooSlow(model: String)
        case noAddress
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
            case .noAddress:
                return "I couldn't work out an address for this Mac on your network."
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

    /// This Mac's address on the local network.
    ///
    /// A LAN address, deliberately, for the first version: the phone and the
    /// appliance are on the same Wi-Fi, media never leaves the house, and no
    /// relay sees that a call happened. Reaching it from outside needs a tunnel
    /// and a TURN server, which are the next piece rather than this one.
    public static func localAddress(
        runner: ProbeCommandRunning = ProbeCommandRunner()
    ) async -> String? {
        for interface in ["en0", "en1"] {
            let result = await runner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/ipconfig"),
                arguments: ["getifaddr", interface],
                timeout: 5
            )
            let address = result?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !address.isEmpty { return address }
        }
        return nil
    }

    /// The sentence sent to the owner with the link.
    ///
    /// Says what will happen before they tap: a certificate warning is coming,
    /// and a page that asks for a microphone after an unexplained security
    /// warning is a page people close.
    public static func invitation(url: String) -> String {
        """
        Tap to talk to me: \(url)

        Your phone will warn about the certificate — that's expected, it's this Mac's own. \
        Continue, then allow the microphone.
        """
    }
}
