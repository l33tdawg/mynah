import Foundation

/// Separates what should be said from what should be sent.
///
/// A URL read aloud is useless twice over: nobody can write down a maps link
/// while holding a phone to their ear, and a synthesiser pronouncing one costs
/// several seconds of the caller's time to deliver nothing they can act on.
/// "Google dot com slash maps slash place slash…" is the sound of a call wasting
/// itself.
///
/// So links leave by the channel that can carry them. The Signal thread is right
/// there, already open, and a link in it is one tap — which is what the caller
/// wanted from the moment they asked.
public enum SpokenReply {

    /// What to speak, and what to send.
    public struct Split: Sendable, Equatable {
        public let spoken: String
        public let links: [String]
    }

    public static func split(_ reply: String) -> Split {
        let links = SourceLinks.extract(from: reply)
        guard !links.isEmpty else {
            return Split(spoken: reply, links: [])
        }

        var spoken = reply
        for link in links {
            spoken = spoken.replacingOccurrences(of: link, with: "")
        }

        // Tidy what removal left behind. A URL usually sits inside punctuation —
        // "(https://…)", "at https://…." — and taking it out leaves brackets
        // around nothing and doubled spaces, both of which a synthesiser reads
        // as pauses in the wrong places.
        spoken = spoken
            .replacingOccurrences(of: "\\(\\s*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[\\s*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<\\s*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([.,;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+\\n", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Say that it was sent, or the caller is left waiting for something they
        // have already been given and cannot see.
        let notice = links.count == 1
            ? "I've sent the link to your chat."
            : "I've sent the links to your chat."
        spoken = spoken.isEmpty ? notice : spoken + " " + notice

        return Split(spoken: spoken, links: links)
    }

    /// The message the links go out in.
    ///
    /// Bare, one per line. Signal makes a bare URL tappable and adds a preview;
    /// wrapping them in a sentence produces neither, and the caller is mid-call
    /// and not reading prose.
    public static func message(links: [String]) -> String? {
        guard !links.isEmpty else { return nil }
        return links.joined(separator: "\n")
    }
}
