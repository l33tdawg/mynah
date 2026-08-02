import AppKit
import SwiftUI

// MARK: - The two cards a transcript is made of
//
// Left and right, because that convention is thirty years old and nobody has to
// be taught it: the owner's words on the right, Mynah's on the left.
//
// What the sides do *not* carry is which of the two matters. This window is not
// really a chat — the owner asks something, the appliance goes away and works,
// and comes back — and what anybody scans it for is the answers. So the two
// cards sit at different heights on the elevation ramp rather than being
// mirror images of each other: the question recessed into the page, the answer
// raised off it.
//
// Sunken and raised rather than, say, `surface.well` for the question, because
// those two hold their relationship in *both* schemes. `well` is ink at a low
// alpha, which is darker than the canvas in light and lighter than it in dark —
// so a hierarchy built on it would read correctly to half the owners and
// backwards to the other half.
//
// These are local to the transcript on purpose. `MynahCard` is the app's card
// and it fills the width it is given, which is right for a settings panel and
// wrong here: every answer would be exactly 520pt wide and "Done." would sit in
// a mostly empty box. If this pairing is worth keeping, it belongs in the design
// system as a variant that shrinks to its content.

/// The time a message was said, under the message.
///
/// **The owner asked for these to measure the appliance**: *"would be useful to
/// know the time it took to respond ... that would tell us how 'fast' the model
/// is"*. Two stamps a few seconds apart answer that without anybody computing
/// anything, which is why the time goes on *both* sides rather than only under
/// the answers.
///
/// Absent rather than guessed when there is no stamp. Every message written
/// before the store recorded times has none, and the whole value of these is
/// that they are measurements — one invented time in the column and the number
/// the owner reads off two of them is fiction.
struct MessageStamp: View {
    let at: Date?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        if let at {
            Text(at.formatted(date: .omitted, time: .shortened))
                .mynahFont(.label)
                .monospacedDigit()
                .foregroundStyle(Palette.ink.tertiary)
                .frame(
                    maxWidth: .infinity,
                    alignment: alignment == .trailing ? .trailing : .leading
                )
                .accessibilityLabel("at \(at.formatted(date: .omitted, time: .shortened))")
        }
    }
}

/// What the owner said, in the words that were recorded.
///
/// Quiet by construction: no border, and a surface *below* the page rather than
/// above it. The owner already knows what they asked — it is here so the answer
/// has something to be an answer to.
struct AskedCard: View {
    let text: String
    /// When it was said, when the record knows. See `MessageStamp`.
    var at: Date?
    /// How much of the column the card may never occupy.
    ///
    /// A flexible spacer rather than `.frame(maxWidth:)`: a maximum width
    /// *expands* to its limit, so every card would be identical and three words
    /// would sit in a box built for thirty.
    let inset: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: s2) {
            bubble
            MessageStamp(at: at, alignment: .trailing)
        }
    }

    private var bubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: inset)
            // The owner's own words get the same treatment: they paste links in
            // too, and one bubble where a URL is clickable and the one above it
            // where it isn't would read as a bug in whichever came second.
            Text(ChatLinks.attributed(text))
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, s5)
                .padding(.vertical, s4)
                .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.card))
                // An edge, even on the quiet one. `sunken` sits only about 2.7%
                // below `canvas` in light mode — the ramp's tightest step — and
                // a borderless bubble at that distance barely reads as a card at
                // all, which is the one thing that was asked for. It is the same
                // recipe as the composer field directly below it, and that is a
                // useful echo: this is the shape the owner's own words take.
                .mynahBorder(r.card)
                // Which side a card sits on is worth nothing to VoiceOver, which
                // reads the whole transcript as one undifferentiated run.
                .accessibilityLabel("You said: \(text)")
        }
    }
}

/// What came back — or, while it is still coming, where it will land.
///
/// The one raised thing in the column, and the same shell for every outcome, so
/// an answer arrives *in place* rather than replacing a waiting row that was a
/// different size and shape.
struct AnsweredCard<Content: View>: View {
    let inset: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: s3) {
                content
            }
            .padding(.horizontal, s5)
            .padding(.vertical, s5)
            .background(Palette.surface.raised, in: RoundedRectangle.mynah(r.card))
            .mynahBorder(r.card)
            Spacer(minLength: inset)
        }
    }
}

/// Mynah's words inside an answer card, with any URLs in them clickable, and
/// the one accessibility label that says who is speaking.
///
/// The label stays the plain string: VoiceOver reading a two-line URL aloud
/// character by character helps nobody, and the link is reachable from the
/// rotor regardless.
struct AnsweredText: View {
    let text: String

    var body: some View {
        // One `Text` for the whole reply is what made a list of four tasks read
        // as a paragraph with hyphens in it. `AnswerLayout` keeps the shapes the
        // model wrote in — see its type comment.
        AnswerLayout(text: text)
    }
}

/// Where a run of messages came from — the phone, or this window.
///
/// The one piece of chrome the transcript carries, and it earns its place:
/// without it the owner cannot tell which of these Mynah answered on their phone
/// and which they typed here a minute ago. Centred, small and grey, in the
/// manner of a day divider — not a pill, not a badge, and not an imitation of
/// Signal's own header.
struct ConversationSourceLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .mynahFont(.label)
            .foregroundStyle(Palette.ink.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, s2)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - One exchange from the phone

/// Something asked and what came back, grouped out of a flat run of turns.
///
/// The unit here is the exchange, not the message. A column of question-and-what-
/// happened reads as "things I asked and what came of them", which is what
/// somebody opens this window for; a column of alternating bubbles reads as a
/// chat, which is a thing to scroll rather than a thing to scan.
///
/// Grouping is by adjacency and nothing else: everything said in a row by one
/// side, then everything the other side said next. No content is inspected, no
/// time is inferred, and nothing is invented — the record has neither
/// timestamps per turn nor any marker of what belongs with what. This is the
/// pairing a reader's eye already does, made explicit so the layout can hold a
/// pair together.
struct TranscriptExchange: Identifiable, Equatable, Sendable {
    /// The first message's position, which is stable for as long as the record
    /// is only appended to.
    let id: Int
    var asked: [TranscriptMessage]
    var answered: [TranscriptMessage]

    /// A conversation split into exchanges, oldest first.
    ///
    /// An exchange may have nothing asked in it: the daemon trims from the
    /// front, so a conversation can quite legitimately begin with an answer
    /// whose question is no longer anywhere. Drawing that answer alone is
    /// honest; inventing a question for it would not be.
    static func group(_ messages: [TranscriptMessage]) -> [TranscriptExchange] {
        var exchanges: [TranscriptExchange] = []
        var index = messages.startIndex
        while index < messages.endIndex {
            let start = index
            var asked: [TranscriptMessage] = []
            while index < messages.endIndex, messages[index].speaker == .owner {
                asked.append(messages[index])
                index += 1
            }
            var answered: [TranscriptMessage] = []
            while index < messages.endIndex, messages[index].speaker == .mynah {
                answered.append(messages[index])
                index += 1
            }
            exchanges.append(
                TranscriptExchange(id: messages[start].id, asked: asked, answered: answered)
            )
        }
        return exchanges
    }
}

/// One exchange from the phone, drawn.
///
/// Two messages sent one after the other stay two cards — they were two
/// messages, and merging them would be the app rewriting what was said. What the
/// grouping buys is the spacing: tight inside an exchange, open between them, so
/// the eye takes a pair as one thing without any box being drawn around it.
struct TranscriptExchangeView: View {
    let exchange: TranscriptExchange
    let inset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: s4) {
            if !exchange.asked.isEmpty {
                VStack(alignment: .leading, spacing: s3) {
                    ForEach(exchange.asked) { message in
                        AskedCard(text: message.text, at: message.at, inset: inset)
                    }
                }
            }
            if !exchange.answered.isEmpty {
                VStack(alignment: .leading, spacing: s3) {
                    ForEach(exchange.answered) { message in
                        AnsweredCard(inset: inset) {
                            AnsweredText(text: message.text)
                            DocumentChips(files: message.files)
                            // No duration on this side: the daemon records when
                            // a turn was written, never how long it took. A
                            // number derived from two stamps here would be the
                            // gap between messages, which is mostly how long the
                            // owner took to read.
                            MessageStamp(at: message.at)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - A document Mynah wrote

/// The file itself, under the answer that mentions it.
///
/// **The window has no attachment channel, and that gap was the whole problem.**
/// The phone gets a PDF as a Signal attachment; here, `write_note` saves into
/// `Notes/documents` and the answer says so — which leaves the owner reading
/// "I've made you a PDF" with nowhere to press. *"if you send the same message
/// in the app it would send back a clickable pdf that it has saved to its
/// 'directory'."*
///
/// One click opens it in whatever the Mac uses for that kind of file. The
/// second, quiet control reveals it in the Finder, because the first thing
/// somebody wants after reading a generated document is to put it somewhere of
/// their own.
struct DocumentChip: View {
    let file: URL

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: s3) {
            Image(systemName: Self.symbol(for: file))
                .mynahIcon(.inline)
                .foregroundStyle(Palette.ink.secondary)
            Text(file.lastPathComponent)
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isHovering {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } label: {
                    Image(systemName: "folder")
                        .mynahIcon(.inline)
                        .foregroundStyle(Palette.ink.tertiary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, s4)
        .padding(.vertical, s3)
        .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.control))
        .mynahBorder(r.control)
        .contentShape(RoundedRectangle.mynah(r.control))
        .onTapGesture { NSWorkspace.shared.open(file) }
        .onHover { isHovering = $0 }
        .mynahAnimation(Motion.fade, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(file.lastPathComponent)")
        .accessibilityAddTraits(.isButton)
    }

    /// The icon macOS itself would use, near enough. A generic page for anything
    /// unrecognised rather than a guess — a Word icon on a PDF is a small lie
    /// that makes the owner distrust the rest of the row.
    static func symbol(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "docx", "doc": return "doc.text"
        case "pptx", "ppt": return "rectangle.on.rectangle"
        case "md", "txt": return "text.alignleft"
        default: return "doc"
        }
    }
}

/// Every document a turn produced, or nothing at all.
struct DocumentChips: View {
    let files: [URL]

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: s3) {
                ForEach(files, id: \.path) { file in
                    DocumentChip(file: file)
                }
            }
            .padding(.top, s2)
        }
    }
}

// MARK: - Something that arrived on its own

/// A reply from one of the owner's other agents.
///
/// **Not an answer card, because it is not an answer.** Nobody on this screen
/// asked for it: the owner sent work to another agent some time ago and it has
/// come back now, possibly in the middle of a different conversation. Drawing it
/// as Mynah's reply would attach it to whatever question happens to sit above
/// it, which is how somebody reads an answer to the wrong question.
///
/// So it takes the notice shape instead — an eyebrow that names where it came
/// from, and a dismiss control, because a message with no question above it
/// stays on screen until somebody says they have read it.
struct AgentArrivalCard: View {
    let arrival: ConversationModel.AgentArrival
    let inset: CGFloat
    var onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: s3) {
                HStack(spacing: s3) {
                    Image(systemName: "tray.and.arrow.down")
                        .mynahIcon(.inline)
                        .foregroundStyle(Palette.ink.secondary)
                    Text("While you were working")
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                        .textCase(.uppercase)
                    Spacer(minLength: s4)
                    if isHovering {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .mynahIcon(.inline)
                                .foregroundStyle(Palette.ink.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                }
                Text(arrival.text)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                MessageStamp(at: arrival.at)
            }
            .padding(.horizontal, s5)
            .padding(.vertical, s5)
            .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.card))
            .mynahBorder(r.card)
            Spacer(minLength: inset)
        }
        .onHover { isHovering = $0 }
        .mynahAnimation(Motion.fade, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("A reply arrived: \(arrival.text)")
    }
}
