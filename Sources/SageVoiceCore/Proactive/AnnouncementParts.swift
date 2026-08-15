import Foundation

/// Sending something long as several messages instead of one cut short.
///
/// **The owner asked for this by describing the symptom first**: *"messages
/// that come via the hook bus whatever thing seem truncated and i always have
/// to ask mynah to resend me the full thing"*, and then the remedy: *"if needed
/// we should just summarize it or send multiple messages / use more than 1 turn
/// to send it"*.
///
/// Of the two he offered, splitting is the one taken, and the reason is a rule
/// `ProactiveWatch` already holds: *"Nothing is invented. The message names what
/// changed and stops; it does not ask the model to have an opinion about it,
/// which would cost a turn on every check and could hallucinate on any of
/// them."* A summary of another agent's message is Mynah's opinion of somebody
/// else's words, produced unprompted, on a path with no owner watching — the
/// exact shape that rule exists to refuse. Splitting invents nothing.
///
/// ## Where it splits
///
/// At the largest boundary that fits, in order: paragraph, then sentence, then
/// word, then — only for text with none of those, which in practice means a
/// pasted token or a hash — mid-word. Every part carries `(n/m)` so the owner
/// can see one arriving in pieces rather than wondering whether the rest is
/// coming.
public enum AnnouncementParts {

    /// How much goes in one message.
    ///
    /// Not a transport limit: WhatsApp and Signal both take far more, and
    /// nothing in this product has ever chunked. It is a readability limit —
    /// a wall of text on a phone is its own kind of truncation, and the owner
    /// reads these in the same thread as his own notes.
    public static let perMessage = 1200

    /// Above this, splitting stops being kind and starts being a flood.
    ///
    /// Ten parts. Beyond it the tail is dropped with a count, because thirty
    /// notifications from one relayed message is the behaviour that makes
    /// somebody mute the thread — and a muted thread loses every message, not
    /// just the long one.
    public static let mostParts = 10

    /// One message in, the messages to actually send out.
    ///
    /// Never empty for non-empty input, and returns the original unchanged when
    /// it already fits — the overwhelmingly common case, which must not acquire
    /// a `(1/1)` label.
    public static func split(
        _ text: String,
        perMessage: Int = AnnouncementParts.perMessage,
        mostParts: Int = AnnouncementParts.mostParts
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > perMessage else { return trimmed.isEmpty ? [] : [trimmed] }

        var pieces = pieces(of: trimmed, perMessage: perMessage)
        var dropped = 0
        if pieces.count > mostParts {
            dropped = pieces.dropFirst(mostParts).reduce(0) { $0 + $1.count }
            pieces = Array(pieces.prefix(mostParts))
        }

        let total = pieces.count
        var labelled = pieces.enumerated().map { "(\($0.offset + 1)/\(total)) \($0.element)" }
        if dropped > 0, let last = labelled.popLast() {
            labelled.append(last + "\n\n…and \(dropped) more characters. Ask me for the rest.")
        }
        return labelled
    }

    /// The split itself, unlabelled.
    private static func pieces(of text: String, perMessage: Int) -> [String] {
        var remaining = Substring(text)
        var pieces: [String] = []

        while !remaining.isEmpty {
            if remaining.count <= perMessage {
                pieces.append(String(remaining).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
            let window = remaining.prefix(perMessage)
            let cut = boundary(in: window) ?? window.endIndex
            let piece = remaining[remaining.startIndex..<cut]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            remaining = remaining[cut...].drop(while: { $0 == " " || $0 == "\n" })
        }
        return pieces.filter { !$0.isEmpty }
    }

    /// The best place to break inside a window, largest boundary first.
    ///
    /// Returns nil when the window contains none of them, which leaves the
    /// caller cutting at the ceiling — right for a 3,000-character hash, and
    /// not reachable by prose.
    private static func boundary(in window: Substring) -> Substring.Index? {
        if let paragraph = window.range(of: "\n\n", options: .backwards) {
            return paragraph.upperBound
        }
        // A sentence end followed by a space, so "v11.18.13 is" does not split
        // at the version number. Searched backwards for the last one that fits.
        for ending in [". ", "? ", "! "] {
            if let sentence = window.range(of: ending, options: .backwards) {
                return sentence.upperBound
            }
        }
        if let space = window.lastIndex(of: " ") {
            return window.index(after: space)
        }
        return nil
    }
}
