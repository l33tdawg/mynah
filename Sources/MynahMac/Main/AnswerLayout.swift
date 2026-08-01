import SwiftUI

/// An answer, broken into the shapes it was written in.
///
/// **The model writes lists and the window was drawing them as prose.** A reply
/// arrived as
///
///     Four open tasks, bro:
///     - Book hotel for Wednesday the 19th
///     - Apply for the TDAC before travelling
///     All still planned, none started.
///
/// and every line of it went into one `Text`, so the hyphens stayed hyphens, the
/// list ran at the same rhythm as the sentence above and below it, and the four
/// items had nothing to separate them from the paragraph they were embedded in.
/// It is readable the way a wall of text is readable.
///
/// *"can we adjust the response text spacing so its easier to read and list
/// items appear with bullets etc?"*
///
/// Deliberately **not a Markdown renderer.** Nothing here is asked to handle
/// headings, emphasis, tables or code fences, because the model is not being
/// asked for those and a half-built Markdown parser is a source of surprises in
/// a window whose whole job is showing what was actually said. Three shapes,
/// each one something a reply genuinely arrives in.
enum AnswerBlock: Equatable, Identifiable {
    case paragraph(String)
    /// A `- foo` / `* foo` / `• foo` line, with the marker removed.
    case bullet(String)
    /// A `1. foo` line, with the number kept — the model chose it, and
    /// renumbering somebody else's list is how "step 3" stops matching.
    case numbered(marker: String, text: String)

    var id: String {
        switch self {
        case .paragraph(let text): return "p:\(text)"
        case .bullet(let text): return "b:\(text)"
        case .numbered(let marker, let text): return "n:\(marker):\(text)"
        }
    }

    var isListItem: Bool {
        switch self {
        case .paragraph: return false
        case .bullet, .numbered: return true
        }
    }

    /// Splits a reply into blocks, one per line.
    ///
    /// Line-based on purpose. Reflowing wrapped prose into paragraphs would mean
    /// guessing which newlines the model meant as breaks, and getting that wrong
    /// silently reformats what somebody said.
    static func parse(_ text: String) -> [AnswerBlock] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                for marker in ["- ", "* ", "• ", "– ", "— "] where line.hasPrefix(marker) {
                    return .bullet(String(line.dropFirst(marker.count)))
                }
                if let numbered = numberedItem(line) { return numbered }
                return .paragraph(line)
            }
    }

    /// `1.` / `2)` at the start of a line, and nothing more elaborate. A bare
    /// year — "1998 was the year" — is not a list, so the digits must be
    /// followed by a separator and a space.
    private static func numberedItem(_ line: String) -> AnswerBlock? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")",
              rest.dropFirst().first == " " else { return nil }
        return .numbered(
            marker: "\(digits)\(separator)",
            text: String(rest.dropFirst(2))
        )
    }
}

/// One answer, laid out.
///
/// The spacing carries the structure: items in a run sit close together because
/// they belong to one list, and a paragraph gets a full gap because it is a
/// change of subject. Uniform spacing would say neither.
struct AnswerLayout: View {
    let text: String

    private var blocks: [AnswerBlock] { AnswerBlock.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                row(block)
                    .padding(.top, gapAbove(index))
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mynah said: \(text)")
    }

    /// Tight between siblings in one list, roomy between anything else.
    private func gapAbove(_ index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = blocks[index - 1]
        let current = blocks[index]
        return previous.isListItem && current.isListItem ? s2 : s4
    }

    @ViewBuilder
    private func row(_ block: AnswerBlock) -> some View {
        switch block {
        case .paragraph(let text):
            prose(text)
        case .bullet(let text):
            item(marker: "•", text: text)
        case .numbered(let marker, let text):
            item(marker: marker, text: text)
        }
    }

    /// A hanging indent, which is the whole difference between a list and some
    /// lines that happen to start with a dot: the second line of a long item
    /// aligns under the first word rather than under the bullet.
    private func item(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: s3) {
            Text(marker)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.tertiary)
                .frame(minWidth: 14, alignment: .leading)
            prose(text)
        }
    }

    private func prose(_ text: String) -> some View {
        Text(ChatLinks.attributed(text))
            .mynahFont(.body)
            .foregroundStyle(Palette.ink.primary)
            // 15pt body at 1.0 leading is tight for a paragraph that runs the
            // width of this bubble. Three points is the difference between
            // scanning it and reading it twice.
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
