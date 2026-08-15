import XCTest
@testable import SageVoiceCore

/// An agent's message reaching the owner's phone whole.
///
/// From his report on 15 August 2026: *"messages that come via the hook bus
/// whatever thing seem truncated and i always have to ask mynah to resend me
/// the full thing"*, with a screenshot of a status update from
/// `claude-code/sage` cut off at `REL…` — one sentence in.
///
/// The old bound was 160 characters and its stated reason was *"enough to know
/// whether to go and read it"*. He always went and read it, so the excerpt was
/// buying nothing and costing a question every time.
///
/// His remedy, given in the same breath: *"if needed we should just summarize
/// it or send multiple messages / use more than 1 turn to send it"*. Splitting
/// is the half taken — see `AnnouncementParts` for why summarising is not.
final class RelayedMessageLengthTests: XCTestCase {

    private func item(
        sender: String = "claude-code/sage",
        intent: String? = nil,
        body: String,
        expectsAResult: Bool = true
    ) -> AgentInboxItem {
        AgentInboxItem(
            id: "m1",
            content: UntrustedAgentContent(sender: sender, trust: .anotherAgentHere, body: body),
            intent: intent,
            arrived: nil,
            expectsAResult: expectsAResult
        )
    }

    /// The message from his screenshot, near enough. Under the old bound it was
    /// cut mid-word; it must now arrive whole.
    func testARealAgentMessageArrivesWhole() {
        let body = """
        Update from claude-code/sage, sent because @l33tdawg asked me to keep you in the loop. \
        Informational — nothing here is a request and nothing needs a reply. RELEASE: v11.18.13 \
        is tagged and includes a new MCP wake channel that is directly relevant to a voice-bridge \
        style companion. No action required on your side; this is context for when you next look \
        at the wake path.
        """
        let line = ProactiveWatch.line(forMessage: item(body: body))
        XCTAssertTrue(line.contains("RELEASE: v11.18.13 is tagged"), "the middle was cut: \(line)")
        XCTAssertTrue(line.contains("this is context for when you next look at the wake path"))
        XCTAssertFalse(line.contains("…"), "nothing this size should be truncated at all")
    }

    /// Nothing relayed is truncated any more, however long. Length is decided at
    /// delivery, by splitting.
    func testALongMessageIsNotCutAtAll() {
        let body = String(repeating: "word ", count: 4_000)
        let line = ProactiveWatch.line(forMessage: item(body: body))
        XCTAssertGreaterThan(line.count, 19_000)
        XCTAssertFalse(line.contains("…"))
    }

    /// The sender still leads the line, and it is the agent's name rather than
    /// its provider — SAGE 11.18.12 sends the name, and this is where the owner
    /// reads it.
    func testTheLineNamesTheSender() {
        let line = ProactiveWatch.line(forMessage: item(body: "short"))
        XCTAssertTrue(line.hasPrefix("claude-code/sage sent work"), line)
    }

    /// Newlines are still flattened — the digest is one message before it is
    /// split, and a payload full of blank lines would break its shape.
    func testTheRelayIsStillOneLine() {
        let line = ProactiveWatch.line(forMessage: item(body: "one\n\ntwo\n\nthree"))
        XCTAssertFalse(line.contains("\n"), line)
        XCTAssertTrue(line.contains("one two three"))
    }

    /// Task titles keep the old short bound: a title is a phrase, and 160 is a
    /// guard against a pathological one rather than a budget anything real
    /// spends. One constant doing two jobs is what made raising the other look
    /// like it had to argue with this.
    func testTaskTitlesKeepTheShortBound() {
        XCTAssertEqual(ProactiveWatch.excerptCharacters, 160)
        XCTAssertLessThanOrEqual(
            ProactiveWatch.flattened(String(repeating: "x", count: 4_000)).count,
            ProactiveWatch.excerptCharacters + 1
        )
    }
}

/// Sending something long as several messages instead of one cut short.
final class AnnouncementPartsTests: XCTestCase {

    /// The common case by far, and the one that must not acquire a `(1/1)`.
    func testAShortMessageIsSentUnchanged() {
        XCTAssertEqual(AnnouncementParts.split("Two tasks moved."), ["Two tasks moved."])
    }

    func testAnEmptyMessageIsNotSent() {
        XCTAssertEqual(AnnouncementParts.split("   \n  "), [])
    }

    /// Every part is labelled, so the owner can see one message arriving in
    /// pieces rather than wondering whether the rest is coming.
    func testEveryPartIsNumbered() {
        let parts = AnnouncementParts.split(String(repeating: "word ", count: 600))
        XCTAssertGreaterThan(parts.count, 1)
        for (index, part) in parts.enumerated() {
            XCTAssertTrue(
                part.hasPrefix("(\(index + 1)/\(parts.count)) "),
                "part \(index + 1) is unlabelled: \(part.prefix(40))"
            )
        }
    }

    /// **Nothing is lost.** The whole point of splitting over truncating.
    func testTheWholeMessageSurvivesTheSplit() {
        let sentences = (1...80).map { "Sentence number \($0) about the release." }
        let original = sentences.joined(separator: " ")
        let rejoined = AnnouncementParts.split(original)
            .map { part in part.drop(while: { $0 != ")" }).dropFirst().trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        for sentence in sentences {
            XCTAssertTrue(rejoined.contains(sentence), "lost: \(sentence)")
        }
    }

    /// No part may exceed the per-message budget, or splitting has not
    /// accomplished anything.
    func testNoPartExceedsTheBudget() {
        let parts = AnnouncementParts.split(String(repeating: "word ", count: 900))
        for part in parts {
            XCTAssertLessThanOrEqual(part.count, AnnouncementParts.perMessage + 20)
        }
    }

    /// Prose breaks at a sentence, not mid-word.
    func testProseBreaksAtASentence() {
        let text = (1...60).map { "This is sentence \($0) and it runs on a while." }
            .joined(separator: " ")
        let parts = AnnouncementParts.split(text)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts.dropLast() {
            XCTAssertTrue(
                part.hasSuffix("."),
                "a part ended mid-sentence: …\(part.suffix(40))"
            )
        }
    }

    /// A paragraph break is a better seam than a sentence, so it wins.
    func testAParagraphBreakIsPreferred() {
        let first = String(repeating: "alpha ", count: 150)
        let second = String(repeating: "beta ", count: 150)
        let parts = AnnouncementParts.split(first + "\n\n" + second)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertFalse(parts[0].contains("beta"), "the split crossed the paragraph break")
    }

    /// Text with no seam at all — a hash, a pasted token — still has to go
    /// somewhere rather than looping forever or arriving as one wall.
    func testTextWithNoBoundaryStillSplits() {
        let parts = AnnouncementParts.split(String(repeating: "x", count: 3_000))
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { !$0.isEmpty })
    }

    /// **Splitting stops before it becomes a flood.** Thirty notifications from
    /// one relayed message is the behaviour that makes somebody mute the
    /// thread — and a muted thread loses every message, not just the long one.
    func testAnAbsurdMessageIsCappedAndSaysSo() {
        let parts = AnnouncementParts.split(String(repeating: "word ", count: 20_000))
        XCTAssertEqual(parts.count, AnnouncementParts.mostParts)
        XCTAssertTrue(parts.last!.contains("more characters"), parts.last!.suffix(80).description)
        XCTAssertTrue(parts.last!.contains("Ask me for the rest"))
    }

    /// The daemon has to actually split — `main.swift` cannot be imported, so
    /// this is the scan precedent `AfterTheCallTests` set. Without it the
    /// splitter can be perfect and never reached, which is exactly the state
    /// the owner reported.
    func testTheDaemonSplitsWhatItAnnounces() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: root.appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            main.contains("for part in AnnouncementParts.split(message)"),
            "the proactive announcement is sent as one message again, so a long one is cut"
        )
    }
}
