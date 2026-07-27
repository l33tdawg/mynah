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

        let full = NSRange(text.startIndex..., in: text)
        var result = ""
        var cursor = text.startIndex

        for match in regex.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[range])
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
        "io", "ai", "app", "dev", "xyz", "co",
        "my", "sg", "th", "ph", "jp", "kr", "hk", "tw", "id", "vn",
        "uk", "de", "fr", "es", "nl", "au", "nz", "ca"
    ]
}
