import Foundation

/// Makes the URLs in a reply tappable.
///
/// Signal linkifies text that carries a scheme. The model writes bare domains —
/// "check their website mamaison.com.my", "search for their nearest branch via
/// maps.google.com" — so the owner gets a phone screen full of addresses they
/// have to retype. Asking the model to always write `https://` helps and is not
/// reliable; rewriting the reply on the way out is.
///
/// This is a presentation fix applied to outgoing text only. Nothing here
/// reaches the model, so it cannot affect routing, and history keeps whatever
/// the model actually said.
enum Linkify {

    /// Promotes bare domains to `https://` URLs.
    ///
    /// Conservative by construction: a false positive turns a word into a dead
    /// link in the owner's chat, which is worse than the bare domain it
    /// replaced. So a match needs a known TLD, a plausible label in front of it,
    /// and no scheme already attached.
    static func promotingBareDomains(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            // A run of dot-separated labels ending in a known TLD, optionally
            // followed by a path. `(?<![\w@/.])` keeps it away from anything
            // already inside a URL, an email address, or a version number.
            // The trailing guard is `(?!\.?\w)`, not `(?![\w.])`. The stricter
            // form rejected any domain at the end of a sentence — "via
            // maps.google.com." — which is most of them. This still refuses to
            // match a prefix of something longer: "foo.com.invalid" fails
            // because ".invalid" is a dot followed by word characters.
            pattern: "(?<![\\w@/.])((?:[a-zA-Z0-9-]+\\.)+(?:\(knownTLDs.joined(separator: "|")))(?:/[^\\s<>\"')\\]]*)?)(?!\\.?\\w)",
            options: [.caseInsensitive]
        ) else {
            return text
        }

        // Spans that already belong to a URL. A bare domain inside a query
        // string is a *parameter*, not a link:
        // "…/translate?u=example.com" became "…/translate?u=https://example.com",
        // which changes where the link goes. The lookbehind cannot see this
        // because the domain is separated from the scheme by "?u=".
        let existing = SourceLinks.extract(from: text, limit: 100)
        var protectedRanges: [Range<String.Index>] = []
        for url in existing {
            var searchFrom = text.startIndex
            while let found = text.range(of: url, range: searchFrom..<text.endIndex) {
                protectedRanges.append(found)
                searchFrom = found.upperBound
            }
        }

        let full = NSRange(text.startIndex..., in: text)
        var result = ""
        var cursor = text.startIndex

        for match in regex.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            guard !protectedRanges.contains(where: { $0.overlaps(range) }) else { continue }
            let candidate = String(text[range])
            guard !isIdentifierShaped(candidate) else { continue }
            result += text[cursor..<range.lowerBound]
            // Trailing sentence punctuation belongs to the sentence.
            let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            let tail = candidate.dropFirst(trimmed.count)
            result += "https://\(trimmed)\(tail)"
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Whether this looks like an identifier that happens to contain dots.
    ///
    /// SAGE memory ids are short hex, and they get spoken in sentences: "the
    /// memory is 7f3a.9c21.co" linkified into a dead host. A hostname whose every
    /// label before the TLD is pure hexadecimal is an identifier, not a site.
    ///
    /// Costs a real domain made only of hex letters — `cafe.co` will not linkify.
    /// That trade is deliberate and one-directional: a missed link leaves the
    /// owner exactly where they were, while a fabricated one puts a dead address
    /// in their chat and makes them think the appliance found something.
    static func isIdentifierShaped(_ candidate: String) -> Bool {
        let host = candidate.split(separator: "/").first.map(String.init) ?? candidate
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return false }
        let beforeTLD = labels.dropLast()
        guard !beforeTLD.isEmpty else { return false }
        return beforeTLD.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isHexDigit }
        }
    }

    /// TLDs worth promoting.
    ///
    /// An allowlist rather than a general pattern, because the general pattern
    /// links things that are not addresses. Two categories are deliberately
    /// absent even though they are real TLDs: file extensions the appliance
    /// genuinely says out loud (`.md` for the notes it writes, `.sh`, `.py`),
    /// and short English words (`.it`, `.is`, `.me`, `.so`) that appear mid
    /// sentence after an abbreviation.
    ///
    /// Weighted to where the owner actually is and travels — `.my`, `.sg`,
    /// `.th`, `.ph`, `.jp` — because "mamaison.com.my" is the exact string that
    /// prompted this.
    private static let knownTLDs: [String] = [
        "com", "org", "net", "edu", "gov", "info", "biz",
        // No "app": macOS bundles are the more common shape in this product's
        // own sentences — "open Mynah.app", "verify SAGE.app" — and turning the
        // owner's application into a link is worse than missing a .app site.
        "io", "ai", "dev", "xyz", "co",
        "my", "sg", "th", "ph", "jp", "kr", "hk", "tw", "id", "vn",
        "uk", "de", "fr", "es", "nl", "au", "nz", "ca"
    ]
}
