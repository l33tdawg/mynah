import Foundation

/// Turns a spoken title into a filename, and back into something readable.
///
/// The whole security argument for `NotesToolSource` rests on `slug(from:)`, so
/// it is deliberately small enough to read in one sitting and hard to get wrong
/// by accident: it *keeps* an allowed set rather than *removing* a denied one.
/// A denylist of `..`, `/`, `\`, `:`, `%2e%2e`, `\u{2025}` and whatever comes
/// next is a list somebody has to keep adding to; an allowlist of alphanumerics
/// is a list nobody has to maintain.
enum NoteSlug {

    /// Unicode alphanumerics, not ASCII ones.
    ///
    /// The owner photographs Japanese signage and asks about it, so a title can
    /// legitimately be 書道 — and collapsing every non-ASCII title to the same
    /// slug would silently overwrite one note with another. `.` and `/` are not
    /// alphanumeric under any encoding, so this stays as safe as the ASCII
    /// version while being usable in more than one language.
    private static let allowed = CharacterSet.alphanumerics

    static func slug(from title: String) -> String {
        var pieces: [String] = []
        var current = ""

        for scalar in title.unicodeScalars {
            if allowed.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }

        let joined = pieces.joined(separator: "-").lowercased()
        guard !joined.isEmpty else {
            // Every character was punctuation or emoji. A fixed name means the
            // next such note replaces this one, which is worse than a suffix but
            // better than writing a file called "" — and it is rare enough that
            // paying for a counter here is not worth the state it needs.
            return "note"
        }
        return truncateSlug(joined, to: NotesToolSource.maximumSlugLength)
    }

    /// Cuts at a hyphen where possible, so a truncated slug does not end in half
    /// a word that reads as corruption in an attachment row.
    private static func truncateSlug(_ slug: String, to limit: Int) -> String {
        guard slug.count > limit else { return slug }
        let clipped = slug.prefix(limit)
        guard let lastHyphen = clipped.lastIndex(of: "-"), lastHyphen != clipped.startIndex else {
            return String(clipped)
        }
        return String(clipped[..<lastHyphen])
    }

    /// The filename shown back to the model when it asks what notes exist.
    ///
    /// Lossy — the original casing and punctuation are gone — which is fine,
    /// because it is fed straight back through `slug(from:)` when the model asks
    /// to read one. Round-tripping is the property that has to hold, not
    /// fidelity to what the owner said.
    static func readableTitle(fromFilename filename: String) -> String {
        let stem = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
        return stem.replacingOccurrences(of: "-", with: " ")
    }

    /// A title for a note the model did not name: the first heading or the first
    /// line of the document.
    static func titleFromContent(_ content: String) -> String {
        let firstLine = content
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let stripped = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "note" : String(stripped.prefix(NotesToolSource.maximumSlugLength))
    }

    /// Cuts a document at a line boundary. A markdown file that stops mid-table
    /// renders as garbage; one that stops after a paragraph reads as unfinished,
    /// which is what it is.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = text.prefix(limit)
        guard let lastNewline = clipped.lastIndex(of: "\n"), lastNewline != clipped.startIndex else {
            return String(clipped)
        }
        return String(clipped[..<lastNewline])
    }
}
