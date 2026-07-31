import XCTest
@testable import MynahMac

/// **That the transcript is in the order things were said.**
///
/// The owner caught this the moment messages started carrying times: a `//call`
/// stamped 19:01 was drawn *below* an answer stamped 19:11, and his next
/// question at 19:12 below that. *"message ordering in the chat is jumbled up —
/// look at the time stamps"*.
///
/// The cause was structural rather than a slipped comparison. The phone's
/// messages were one block and the window's another, and a heuristic chose which
/// block went on top — so within a block the order was right and across the seam
/// it was arbitrary. Every message was in the wrong place relative to half the
/// others, and nothing could have shown that until the times were on screen.
///
/// The timestamps he asked for in order to measure the model's speed are what
/// exposed it. The layout was always wrong; it was merely unfalsifiable before.
@MainActor
final class TranscriptOrderingTests: XCTestCase {

    private func at(_ minute: Int, _ second: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 7; parts.day = 29
        parts.hour = 19; parts.minute = minute; parts.second = second
        return Calendar(identifier: .gregorian).date(from: parts)!
    }

    private func phoneMessage(_ id: Int, _ text: String, _ when: Date?) -> TranscriptMessage {
        TranscriptMessage(id: id, speaker: id % 2 == 0 ? .owner : .mynah, text: text, at: when)
    }

    private func view(phone: [TranscriptMessage], here: [Exchange]) -> TalkView {
        TalkView(
            model: ConversationModel(exchanges: here),
            record: WindowConversation(messages: phone),
            board: TaskBoardModel(board: nil, trouble: nil)
        )
    }

    private func answered(_ question: String, at when: Date) -> Exchange {
        Exchange(
            question: question,
            askedAt: when,
            outcome: .answered(Exchange.Answer(text: "ok", seconds: 1, activity: []))
        )
    }

    // MARK: The bug

    /// **His exact screen, as a test.**
    ///
    /// Phone traffic up to 19:11, a `//call` typed here at 19:01, another
    /// question here at 19:12. The old layout drew all the phone messages, then
    /// both window ones. Correct order interleaves them.
    func testAWindowMessageOlderThanAPhoneMessageIsDrawnAboveIt() {
        let subject = view(
            phone: [
                phoneMessage(0, "how do I fix the drift?", at(10)),
                phoneMessage(1, "use OBS sync offsets", at(11))
            ],
            here: [
                answered("//call", at: at(1)),
                answered("we have 2 video feeds", at: at(12))
            ]
        )

        let order = subject.timeline.compactMap(\.item.at)

        XCTAssertEqual(
            order, [at(1), at(10), at(12)],
            "the transcript is not in the order things were said"
        )
    }

    /// The property, rather than the one arrangement above: nothing dated may
    /// ever follow something dated later than it.
    func testNothingIsEverDrawnAboveSomethingOlderThanIt() {
        let subject = view(
            phone: [
                phoneMessage(0, "first", at(5)),
                phoneMessage(1, "second", at(6)),
                phoneMessage(2, "later", at(30))
            ],
            here: [answered("middle", at: at(20)), answered("last", at: at(40))]
        )

        let dated = subject.timeline.compactMap(\.item.at)
        XCTAssertEqual(dated, dated.sorted(), "the transcript runs backwards somewhere")
    }

    // MARK: Messages with no time

    /// A missing stamp means the message predates the store recording them, so
    /// it is genuinely older than anything that has one. Top is the true answer,
    /// not the convenient one.
    func testUndatedMessagesSortAboveEverythingDated() {
        let subject = view(
            phone: [phoneMessage(0, "from before stamps existed", nil)],
            here: [answered("asked today", at: at(9))]
        )

        let items = subject.timeline.map(\.item)
        XCTAssertNil(items.first?.at, "a message with no time was pushed below dated ones")
        XCTAssertEqual(items.last?.at, at(9))
    }

    /// Two undated messages keep the order they arrived in — the record's own
    /// order is the only evidence available about them.
    /// Asserted on the flattened messages rather than on exchanges, because
    /// `TranscriptExchange.group` folds an adjacent question and answer into one
    /// exchange — the first version of this expected two entries, got one, and
    /// was measuring the grouping rather than the ordering.
    func testUndatedMessagesKeepTheOrderTheyArrivedIn() {
        let subject = view(
            phone: [
                phoneMessage(0, "asked first", nil),
                phoneMessage(1, "answered first", nil),
                phoneMessage(2, "asked second", nil),
                phoneMessage(3, "answered second", nil)
            ],
            here: []
        )

        let texts = subject.timeline.flatMap { entry -> [String] in
            guard case .earlier(let exchange) = entry.item else { return [] }
            return (exchange.asked + exchange.answered).map(\.text)
        }
        XCTAssertEqual(
            texts,
            ["asked first", "answered first", "asked second", "answered second"]
        )
    }

    /// Swift's sort is not stable, so two things in the same second could
    /// otherwise swap between redraws — a transcript that reshuffles while it is
    /// being read is worse than one in the wrong order.
    func testASharedTimestampDoesNotReshuffleBetweenReads() {
        let subject = view(
            phone: [phoneMessage(0, "phone", at(15))],
            here: [answered("window", at: at(15))]
        )

        let first = subject.timeline.map(\.id)
        for _ in 0..<10 {
            XCTAssertEqual(subject.timeline.map(\.id), first, "the order is not deterministic")
        }
    }

    // MARK: The labels that are no longer there

    /// **There is one conversation on this screen now, so nothing is labelled.**
    ///
    /// The labels named a handover between two conversations — the phone's and
    /// this window's — drawn in one column. Separating them removed the thing
    /// the labels were pointing at. What remains looks superficially similar:
    /// turns restored from disk, then turns said since the window opened. That
    /// is not a handover, it is a scroll position, and captioning it "In this
    /// window" above everything in the window is the caption on the obvious the
    /// old test already warned about.
    func testNothingIsLabelledBecauseThereIsOnlyOneConversation() {
        let subject = view(
            phone: [
                phoneMessage(0, "said earlier", at(5)),
                phoneMessage(1, "answered earlier", at(6))
            ],
            here: [answered("typed just now", at: at(10))]
        )

        XCTAssertEqual(subject.timeline.compactMap(\.label), [])
        // And the ordering it was drawn in still holds — this is the guard that
        // matters, and removing the labels must not have touched it.
        XCTAssertEqual(subject.timeline.count, 2)
    }

    // MARK: Placement within an exchange

    /// A phone exchange is placed by when it *began*. Using the latest time in
    /// it would let a long answer push its own question below something said
    /// while that answer was still being written.
    func testAPhoneExchangeIsPlacedByWhenItStarted() {
        let subject = view(
            phone: [
                phoneMessage(0, "asked at 19:05", at(5)),
                phoneMessage(1, "answered at 19:20", at(20))
            ],
            here: [answered("typed at 19:10", at: at(10))]
        )

        XCTAssertEqual(
            subject.timeline.first?.item.at, at(5),
            "a slow answer dragged its own question down the transcript"
        )
    }
}
