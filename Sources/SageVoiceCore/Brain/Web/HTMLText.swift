import Foundation

/// Turning result-page markup into something speakable.
///
/// Search snippets arrive with `<b>` around the matched terms and entities for
/// anything non-ASCII. Read aloud, `&amp;` and `<b>` are noise; fed to a 4B
/// model they are tokens spent on nothing.
enum HTMLText {

    /// Extracts the useful prose from a whole page rather than a search
    /// snippet. Prefer an article/main element, then remove the chrome and code
    /// that otherwise consume the tool-result budget before the article begins.
    static func readablePage(_ html: String, limit: Int) -> String {
        let outline = headingOutline(in: html)
        let preferred = firstCapture(
            in: html,
            pattern: #"<(?:article|main)\b[^>]*>([\s\S]*?)</(?:article|main)>"#
        ) ?? html
        var content = preferred
        for element in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form"] {
            content = content.replacingOccurrences(
                of: #"<\#(element)\b[^>]*>[\s\S]*?</\#(element)>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        content = content.replacingOccurrences(
            of: #"</?(?:p|div|section|h[1-6]|li|br|tr)\b[^>]*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        let body = plain(content)
        let prefix = outline.isEmpty ? "" : "Page outline: \(outline)\n\n"
        let remaining = max(0, limit - prefix.count)
        let boundedBody = body.count > remaining
            ? WebSearchToolSource.truncate(body, to: remaining)
            : body
        return prefix + boundedBody
    }

    /// A server-rendered shell can expose its headings in metadata while the
    /// article body still exists only after JavaScript runs. The outline is
    /// useful, but it is not proof that the page itself was readable; the page
    /// reader uses this distinction to decide whether to render externally.
    static func hasBodyBeyondOutline(_ text: String) -> Bool {
        guard text.hasPrefix("Page outline:") else { return !text.isEmpty }
        guard let divider = text.range(of: "\n\n") else { return false }
        return !text[divider.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

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

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Carries headings from the whole document ahead of the bounded body.
    /// Long round-ups otherwise lose every item below the first few thousand
    /// characters when the tool loop applies its on-device context ceiling.
    private static func headingOutline(in text: String) -> String {
        var headings: [String] = []
        if let regex = try? NSRegularExpression(
            pattern: #"<h[1-4]\b[^>]*>([\s\S]*?)</h[1-4]>"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(text.startIndex..., in: text)
            headings += regex.matches(in: text, range: range).compactMap { match in
                guard let captured = Range(match.range(at: 1), in: text) else { return nil }
                return plain(String(text[captured]))
            }
        }
        headings += text.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("#") else { return nil }
            let heading = value.drop(while: { $0 == "#" || $0 == " " })
            return heading.isEmpty ? nil : plain(String(heading))
        }

        var seen = Set<String>()
        let unique = headings.filter { !$0.isEmpty && seen.insert($0).inserted }
        let joined = unique.joined(separator: " · ")
        return joined.count > 1_500 ? WebSearchToolSource.truncate(joined, to: 1_500) : joined
    }
}
