import Foundation

/// Teaching the recogniser the owner's own words, from what Mynah remembers.
///
/// ## The gap this fills
///
/// Everything downstream of here already existed and had **no callers**:
/// `DictationMemory`, `ProfileMemoryCompiler.enrich`, `ASRPromptBuilder`,
/// `CorrectionEngine`. What was missing was a *source* — nothing had ever
/// produced a `DictationMemory`. So this is the bridge, and only the bridge:
/// remembered text in, typed vocabulary memories out, and the existing compiler
/// does the rest.
///
/// The point is that the owner's node already holds the words being misheard.
/// Agent names, project names, domains, people — thousands of them, written
/// down correctly, by him. An appliance that mines its own memory for the
/// spelling of "VANTARAQ" is a different product from one with a settings pane
/// where you type your jargon in by hand, and it gets better the longer it is
/// used rather than the more it is configured.
///
/// ## What it looks for
///
/// Coinages, not words. Three shapes, chosen because they are the ones a
/// general-purpose recogniser reliably gets wrong and ordinary prose reliably
/// does not contain:
///
///   * **Internal capitals** — `QuietType`, `CometBFT`, `SageVoiceCore`. Whisper
///     renders these as separate words, which is exactly the measured failure
///     (`QuietType` → "Quiet Type", `CometBFT` → "Comet BFT").
///   * **Shouted names** — `VANTARAQ`, `SAGE`, `CEREBRUM`. Four characters or
///     more, so ordinary acronyms like "AI" and "US" are left alone.
///   * **Dotted or hyphenated identifiers** — `voice-interface`, `sage-voiced`.
///
/// Everything else is deliberately ignored. A vocabulary that included ordinary
/// English would be a rewriting engine pointed at the owner's speech, and
/// `CorrectionEngine` already carries scars from that: it refuses to learn
/// "but" and "bro" globally because a one-token rewrite in either direction
/// corrupts genuine speech everywhere.
public enum SageDictationVocabulary {

    /// How many terms reach the profile.
    ///
    /// The constraint is real and small: Whisper's initial prompt is about 224
    /// tokens, and the node holds five figures of memories. But the binding
    /// limit here is not the prompt — see `DictationProfileStore` for why the
    /// prompt is not used — it is that `CorrectionEngine` does substring
    /// rewriting over every entry for every transcript. Each term is a pass
    /// over the text, so this bounds latency rather than tokens.
    public static let defaultLimit = 64

    /// The shortest thing worth teaching. Three characters catches `BFT` and
    /// `SDK`; two would catch "AI", "US" and "OK", which nothing mishears.
    static let shortestTerm = 3

    /// Vocabulary memories mined from remembered text, best first.
    ///
    /// - Parameters:
    ///   - texts: memory contents, as `sage_recall` returns them.
    ///   - limit: how many terms to keep.
    public static func memories(
        fromRemembered texts: [String],
        limit: Int = defaultLimit
    ) -> [DictationMemory] {
        ranked(fromRemembered: texts, limit: limit).map { term, weight in
            DictationMemory(
                type: .vocabulary,
                // `ProfileMemoryCompiler` reads `term` and `preferred`, and
                // derives the spoken forms itself — including the
                // internal-capitals split. Supplying them here would be a
                // second implementation of a rule that already exists.
                payload: ["term": term, "preferred": term, "category": "sage_memory"],
                source: "sage",
                confidence: weight
            )
        }
    }

    /// Terms and their confidence, best first. Exposed for tests and for
    /// anything that wants the ranking without the memory wrapper.
    static func ranked(
        fromRemembered texts: [String],
        limit: Int = defaultLimit
    ) -> [(term: String, confidence: Double)] {
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]

        for text in texts {
            // Deduplicated per memory: a term repeated six times in one note is
            // one piece of evidence about how the owner writes it, not six.
            var seenHere: Set<String> = []
            for term in coinages(in: text) {
                let key = term.lowercased()
                guard seenHere.insert(key).inserted else { continue }
                counts[key, default: 0] += 1
                // First spelling wins, and recall returns most-relevant first,
                // so the winner is the one from the memory that mattered most.
                if spelling[key] == nil { spelling[key] = term }
            }
        }

        // Ranked by how many separate memories mention it.
        //
        // Chosen over recency and over relevance-to-the-current-utterance, and
        // the reason is the failure mode rather than the accuracy: a term the
        // owner has written down repeatedly is one he says repeatedly, and a
        // wrong entry for it is wrong constantly. Recency would let a single
        // note about a one-off name outrank a project he has discussed for
        // months, and relevance cannot be computed before the utterance exists
        // — which is precisely when we must not be compiling a profile.
        //
        // Ties break on length, longest first, because a longer coinage is both
        // more distinctive and more likely to be mangled.
        let ordered = counts.keys.sorted { left, right in
            if counts[left] != counts[right] { return counts[left]! > counts[right]! }
            return left.count > right.count
        }

        let top = ordered.prefix(max(0, limit))
        let highest = Double(top.first.flatMap { counts[$0] } ?? 1)
        return top.compactMap { key in
            guard let term = spelling[key] else { return nil }
            // Normalised to 0.5…1. Never zero: every mined term is real
            // evidence, and `enrich` sorts on this rather than filtering, so a
            // low score means "later in the list" and not "ignored".
            let share = Double(counts[key] ?? 1) / max(1, highest)
            return (term, 0.5 + 0.5 * share)
        }
    }

    /// The coinages in one piece of text.
    static func coinages(in text: String) -> [String] {
        var found: [String] = []
        // Split on whitespace and sentence punctuation only — hyphens and dots
        // are kept because they are part of `voice-interface` and `sage.dev`.
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;:!?()[]{}\"'“”‘’"))

        for raw in text.components(separatedBy: separators) {
            // A trailing full stop is punctuation; an interior one is part of
            // the identifier.
            var token = raw
            while let last = token.last, last == "." || last == "-" { token.removeLast() }
            guard token.count >= shortestTerm, isCoinage(token) else { continue }
            found.append(token)
        }
        return found
    }

    static func isCoinage(_ token: String) -> Bool {
        guard token.count >= shortestTerm else { return false }
        // Must be word-ish: letters, digits, and interior - or . only.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard token.contains(where: { $0.isLetter }) else { return false }
        // A bare number, a date, a version.
        guard !token.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return false }

        let letters = token.filter { $0.isLetter }
        let uppercase = letters.filter { $0.isUppercase }

        // Shouted: VANTARAQ, SAGE, CEREBRUM. Four or more so AI and US are out.
        if uppercase.count == letters.count && letters.count >= 4 { return true }

        // Internal capitals: QuietType, CometBFT. The first character is
        // excluded because an ordinary capitalised word starting a sentence is
        // not a coinage.
        if token.dropFirst().contains(where: { $0.isUppercase }) { return true }

        // Hyphenated or dotted identifiers: voice-interface, sage-voiced.
        if token.contains("-") || token.contains(".") {
            // Both sides have to be wordish, so "e.g" and "i.e" do not qualify.
            let parts = token.split(whereSeparator: { $0 == "-" || $0 == "." })
            return parts.count >= 2 && parts.allSatisfy { $0.count >= 2 }
        }

        return false
    }
}
