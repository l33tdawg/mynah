import Foundation

/// Spacing for a reply that has to survive being drawn as one run of text.
///
/// **The window and the phone cannot share a fix here.** `AnswerLayout` gives
/// the Mac real bullets, hanging indents and a gap between a paragraph and the
/// list under it, because it is laying out views. Signal is handed a string and
/// draws it at one line height, so a four-item list arrives as a wall:
///
///     The todo list now has four items:
///     - Apply for UOB Visa Infinite — contact a UOB agent
///     to start the application (planned)
///     - Send car for servicing on Tuesday (planned)
///
/// *"list replies are still all bunched together."*
///
/// So the spacing has to be in the characters or it is nowhere. One blank line
/// between a list and the prose around it, and one between items — which is the
/// only lever a plain-text medium offers.
public enum SignalReplyText {

    /// Markers a model actually reaches for. Kept in step with `AnswerBlock` in
    /// the app, which parses the same shapes for the window.
    private static let bulletMarkers = ["- ", "* ", "• ", "– ", "— "]

    /// The formatting ranges that make the marker at the front of a reply bold.
    ///
    /// **Signal's own bold, not a Unicode lookalike.** `signal-cli` takes
    /// `start:length:STYLE` ranges on `send`, so `MYNAH >>` is genuinely bold
    /// rather than spelled in mathematical alphanumerics — which are tofu in any
    /// font missing them, and are read out letter by letter by a screen reader.
    ///
    /// Counted in **UTF-16 code units**, which is what signal-cli documents and
    /// what Signal's wire format uses. `count` is a character count, and the two
    /// disagree the moment a marker contains an emoji — which would put the bold
    /// over the wrong text rather than failing loudly.
    ///
    /// A function of its own, not four lines inside `send`, because it is the
    /// part with a rule in it and because nothing else in a daemon that holds a
    /// socket open can be tested.
    public static func styles(forPrefix prefix: String) -> [String] {
        let marker = prefix.trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty else { return [] }
        return ["0:\(marker.utf16.count):BOLD"]
    }

    public static func spacingOutLists(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: isListItem) else { return text }

        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Never two blanks in a row: the model sometimes spaces its own
            // lists, and doubling that leaves a reply full of holes.
            if trimmed.isEmpty {
                if out.last?.isEmpty == false { out.append("") }
                continue
            }
            // A blank line before a list item, and before whatever follows the
            // list — the two seams that were missing. Not between every line, or
            // ordinary prose ends up double-spaced.
            if let previous = out.last, !previous.isEmpty,
               isListItem(line) || isListItem(previous) {
                out.append("")
            }
            out.append(trimmed)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    static func isListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if bulletMarkers.contains(where: trimmed.hasPrefix) { return true }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return false }
        let rest = trimmed.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return false }
        return rest.dropFirst().first == " "
    }
}
