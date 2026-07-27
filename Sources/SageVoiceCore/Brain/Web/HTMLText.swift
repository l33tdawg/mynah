import Foundation

/// Turning result-page markup into something speakable.
///
/// Search snippets arrive with `<b>` around the matched terms and entities for
/// anything non-ASCII. Read aloud, `&amp;` and `<b>` are noise; fed to a 4B
/// model they are tokens spent on nothing.
enum HTMLText {

    /// Tags stripped, entities decoded, whitespace collapsed.
    static func plain(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: [.regularExpression]
        )
        return collapseWhitespace(decodeEntities(withoutTags))
    }

    /// The handful of entities that actually appear in search snippets, plus
    /// numeric escapes.
    ///
    /// Not a complete HTML5 entity table — that is over two thousand names, and
    /// a wrong `&hellip;` in a spoken sentence costs nothing, while carrying
    /// the table costs a file nobody will ever read.
    static func decodeEntities(_ text: String) -> String {
        var output = text
        let named: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&hellip;", "…"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&rsquo;", "’"),
            ("&lsquo;", "‘"),
            ("&ldquo;", "“"),
            ("&rdquo;", "”")
        ]
        for (entity, replacement) in named {
            output = output.replacingOccurrences(of: entity, with: replacement, options: [.caseInsensitive])
        }
        output = decodeNumericEntities(output)

        // Last, and only once: an `&amp;amp;` in the source should become
        // `&amp;`, not `&`. Running this first would double-decode.
        return output
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return text }

        var output = text
        let range = NSRange(output.startIndex..., in: output)
        // Back to front, so earlier replacements do not invalidate later ranges.
        for match in regex.matches(in: output, range: range).reversed() {
            guard
                let whole = Range(match.range, in: output),
                let prefixRange = Range(match.range(at: 1), in: output),
                let digitsRange = Range(match.range(at: 2), in: output)
            else { continue }

            let isHex = !output[prefixRange].isEmpty
            let digits = String(output[digitsRange])
            guard
                let value = UInt32(digits, radix: isHex ? 16 : 10),
                let scalar = Unicode.Scalar(value)
            else { continue }

            output.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return output
    }

    /// Runs of whitespace and newlines become single spaces.
    static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
