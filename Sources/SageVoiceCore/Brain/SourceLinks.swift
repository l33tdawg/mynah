import Foundation

/// Carries the URLs a turn found into the turns that follow it.
///
/// `VoiceBridgeDaemon.conversationOnly` drops tool results from history, for a
/// measured reason: with last turn's tool output in context, a 4B model decides
/// it already has the facts and stops calling tools — observed live as turns 3,
/// 4 and 5 recycling turn 2's answer, including for "can you save a memory?".
///
/// That fix threw out something it did not mean to. `web_search` returns titles,
/// snippets *and* URLs; the model speaks a summary and the URLs die with the
/// turn. So when the owner said "can you give me links for these please", the
/// links to the thing just discussed no longer existed anywhere in context — the
/// model had to search again from a conversation that by then held two subjects,
/// and returned a mixture of the Tokyo festival it had just described and the
/// Chiang Mai shops from before the owner corrected it.
///
/// A bare URL is the safe half of what was thrown out. It carries no facts, so
/// it cannot be recycled as an answer the way a memory dump can — nothing about
/// "https://tfom.info" tells a model what is on the owner's backlog. It is
/// exactly the part the owner asked for and the only part they could not get.
enum SourceLinks {

    /// Per turn. Web search returns five results; six leaves room for one from
    /// a SAGE tool without letting a pathological result flood the context this
    /// was carved out of in the first place.
    static let maximumPerTurn = 6

    /// URLs in first-appearance order, deduplicated.
    ///
    /// Ordered rather than a `Set` because history is a prompt prefix, and a
    /// prefix that reorders itself between turns is a cache that never hits —
    /// the bug that cost this appliance 17 seconds a turn until it was found.
    static func extract(from text: String, limit: Int = SourceLinks.maximumPerTurn) -> [String] {
        let pattern = "https?://[^\\s<>\"'\\)\\]]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var found: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            // Trailing punctuation belongs to the sentence, not the URL.
            let url = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            guard !url.isEmpty, !seen.contains(url) else { continue }
            seen.insert(url)
            found.append(url)
            if found.count == limit { break }
        }
        return found
    }

    /// The links appended to the assistant turn that used them.
    ///
    /// Attached to the answer rather than kept in a side table so that trimming
    /// history by turns drops a turn's links with the turn — one lifetime, no
    /// ledger to keep in step, and no chance of citing a source for something
    /// that has already scrolled out of context.
    static func annotated(_ reply: String, links: [String]) -> String {
        guard !links.isEmpty else { return reply }
        return reply + "\n(sources: " + links.joined(separator: ", ") + ")"
    }
}
