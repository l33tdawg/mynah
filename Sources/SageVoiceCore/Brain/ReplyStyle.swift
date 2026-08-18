import Foundation

/// How the owner wants to be answered.
///
/// This exists because two correct rules were in conflict. The brevity rules —
/// 40 words, no markdown, no bullets — were written for text-to-speech, where a
/// synthesiser reads "-" aloud as a hyphen and 200 words is unlistenable. Then
/// the appliance shipped over Signal text, the owner asked for ramen shops near
/// KLCC, and got prose that had been trimmed for a voice nobody was hearing.
///
/// The owner's framing, and it is the right one: the answer style should follow
/// how they asked to be answered. Voice notes on means it will be spoken, so
/// brevity wins. Voice notes off means it will be read on a phone screen, so
/// completeness wins.
public enum ReplyStyle: String, Sendable, Codable, CaseIterable {
    /// Read aloud. Short, no markup.
    case spoken
    /// Read on screen. Complete, with lists and tappable links.
    case written

    /// Written.
    ///
    /// Voice notes are off by default, so this is what a new owner gets. It is
    /// also the safer default of the two: a long answer to someone expecting a
    /// short one is an annoyance, while a 40-word answer to someone who asked
    /// for a list of shops with links has silently dropped what they asked for.
    public static let `default` = ReplyStyle.written

    /// **Spoken replies are built, tested, and deliberately not shipped.**
    ///
    /// Mynah answering by voice note works — the synthesizer, the segmenter and
    /// the attachment path are all in place and covered. It is switched off
    /// because the owner judged it a step past what people will actually use:
    /// *"we already have user sends voice notes (great), and calling working —
    /// the agent replies not in text but in voice might be a step too far"*.
    /// Having the capability is not a reason to turn it on for everybody.
    ///
    /// This is the switch, and it is one line. Nothing was deleted, the tests
    /// still exercise `.spoken`, and turning it back on is flipping this to
    /// `true` and restoring the Settings row.
    ///
    /// **Gated here rather than by hiding the toggle**, because hiding a control
    /// does not change a preference somebody already saved. An owner who turned
    /// spoken replies on yesterday would otherwise be stuck with them and no
    /// way back — the setting removed, the behaviour left running.
    public static let spokenRepliesAreAvailable = false

    /// Whether replies are spoken back as voice notes.
    ///
    /// The setting the owner actually sees is "answer with voice notes", not
    /// "reply style" — they are choosing a medium, and the style follows from
    /// it. This keeps that mapping in one place.
    public init(voiceNotes: Bool) {
        self = (voiceNotes && Self.spokenRepliesAreAvailable) ? .spoken : .written
    }

    public var usesVoiceNotes: Bool { self == .spoken }

    /// Hard token ceiling per model turn for this style.
    ///
    /// The cap exists to stop a reasoning runaway — qwen3.5:4b was measured
    /// generating 4,069 tokens over 190 s and returning empty content — so it
    /// cannot simply be removed. But 1,024 was sized against a 40-word spoken
    /// answer, and a written reply listing six shops with full map URLs spends
    /// most of that on the URLs alone: one
    /// `https://www.google.com/maps/search/?api=1&query=...` is around 30
    /// tokens before the place name.
    ///
    /// So the ceiling follows the style. Raising it for written costs nothing
    /// when the reply is short, because it is a ceiling and not a target.
    ///
    /// **Raised again in 1.5.0, because a document travels as a tool argument.**
    /// `write_note` carries the whole report in `content`, so the ceiling is not
    /// bounding a reply here — it is bounding the document. Measured on this
    /// Mac: asked to compare local and hosted models and make a PDF, qwen3.5:4b
    /// spent 704 characters thinking and then wrote a two-page report, and at
    /// 2,048 the tool call was cut off mid-argument. A truncated call is not a
    /// short answer, it is *no* answer — the call is dropped, the loop falls
    /// through to the tools-withheld wrap-up, and the owner is told the thing
    /// cannot be done at all. That is the failure this number caused, and it is
    /// worse than a slow turn.
    public var maximumGeneratedTokens: Int {
        switch self {
        case .spoken: return 1024
        case .written: return 4096
        }
    }

    /// The HOW YOU SPEAK section of the system prompt.
    var howYouSpeak: String {
        switch self {
        case .spoken:
            return """
            HOW YOU SPEAK
            - Your reply is read aloud by a speech synthesiser. Answer in at most 40 words, \
            one or two sentences.
            - Lead with the answer in the first six words. No preamble, no restating the question.
            - Give only what was asked. Do not add background, history or detail the owner did not \
            ask for — offer to go deeper instead, and let them decide.
            - Plain spoken English only. No markdown, no bullet points, no headings, no code blocks, \
            no emoji, no raw IDs or hashes unless the owner asked for one specifically. The one \
            exception is the text you pass to write_note: that is a document, not speech, so markdown \
            belongs there.
            - Do not narrate what you are about to do, and do not list the tools you used.
            """
        case .written:
            return """
            HOW YOU WRITE
            - Your reply is read on a phone screen. Give the whole answer. If the owner asked for \
            several things, give them all of them.
            - Lead with the answer. No preamble, no restating the question, no "based on my research".
            - When you are listing places, shops, links or options, put each on its own line \
            starting with a dash. Keep each line to one line.
            - Write every web address in full, starting with https://, so the owner can tap it. \
            Never tell them to search for something themselves.
            - No headings, no bold, no code blocks, no emoji, and no raw IDs or hashes unless the \
            owner asked for one. Short lines and dashes are the whole format.
            - Do not narrate what you are about to do, and do not list the tools you used.
            """
        }
    }
}

/// Where the reply-style preference lives.
///
/// A small file rather than a flag, because the owner sets this in Mynah and the
/// daemon is a separate long-running process — they need somewhere to meet. Same
/// directory and same owner-only permissions as their provider keys and notes.
public struct ReplyPreferences: Sendable {

    private let fileURL: URL

    public init(fileURL: URL = ReplyPreferences.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// In the appliance directory — `~/Library/Application Support/SAGE Voice
    /// Bridge` on a Mac, unchanged, and `$XDG_DATA_HOME/SAGE Voice Bridge`
    /// (`~/.local/share/…` when unset) off Darwin.
    ///
    /// **Spelled through `ApplianceSupportDirectory` rather than by hand here,
    /// because this file has two readers.** Mynah writes the owner's choice and
    /// `sage-voiced` reads it once per turn; a path spelled twice is the voice
    /// notes switch reading as set on the screen while the daemon answers in the
    /// other style — the same shape of failure as a pause that stops nothing.
    /// It was spelled by hand until 2.5.0, which off Darwin also left a stray
    /// `~/Library` in a Linux owner's home: a tree no package manager owns and
    /// no backup covers, holding the settings file its neighbours had already
    /// stopped putting there.
    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ApplianceSupportDirectory.url(
            for: "reply-preferences.json",
            layout: layout,
            homeDirectory: homeDirectory,
            environment: environment
        )
    }

    private struct Stored: Codable {
        var voiceNotes: Bool
    }

    /// The saved style, or the default when nothing is saved or the file is
    /// unreadable.
    ///
    /// Never throws. A preferences file that will not parse should cost the
    /// owner their preference, not their appliance.
    public func style() -> ReplyStyle {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .default
        }
        return ReplyStyle(voiceNotes: stored.voiceNotes)
    }

    public func save(voiceNotes: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyFileSecurity.write(encoder.encode(Stored(voiceNotes: voiceNotes)), to: fileURL)
    }
}
