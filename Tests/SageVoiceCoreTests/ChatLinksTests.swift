import XCTest
@testable import MynahMac

/// The owner asked Mynah for a credit card application link, got two URLs back,
/// and could not click either of them.
final class ChatLinksTests: XCTestCase {

    private func links(in text: String) -> [URL] {
        ChatLinks.attributed(text).runs.compactMap(\.link)
    }

    // MARK: - The thing that was reported

    /// The real answer from the screenshot, both URLs, one of them long enough
    /// to wrap across three rendered lines — which is exactly the one that is
    /// hardest to select by hand and therefore the one worth clicking.
    func testTheURLsInARealAnswerAreClickable() {
        let answer = """
        - Main CIMB Credit Card Portal (English): \
        https://www.cimb.com.my/en/personal/day-to-day-banking/cards/credit-card.html
        - General Credit Card Application Form: \
        https://www.cimb.com.my/en/personal/forms-enq/day-to-day-banking/credit-card/cimb-credit-card-application.html
        """

        XCTAssertEqual(
            links(in: answer).map(\.absoluteString),
            [
                "https://www.cimb.com.my/en/personal/day-to-day-banking/cards/credit-card.html",
                "https://www.cimb.com.my/en/personal/forms-enq/day-to-day-banking/"
                    + "credit-card/cimb-credit-card-application.html",
            ]
        )
    }

    /// A hyphenated path must not be cut at a hyphen, which is where a naive
    /// word-boundary split would end it and produce a link that 404s.
    func testALongHyphenatedPathSurvivesWhole() throws {
        let url = try XCTUnwrap(
            links(in: "See https://www.cimb.com.my/en/personal/forms-enq/day-to-day-banking/x.html now").first
        )
        XCTAssertTrue(url.absoluteString.hasSuffix("/x.html"))
    }

    // MARK: - What must not become a link

    /// The rest of that same answer is full of numbers, abbreviations and
    /// slashes. None of it is a link, and underlining any of it would teach the
    /// owner that the underline means nothing.
    func testProseIsLeftAlone() {
        for line in [
            "- Standard Tier: RM24,000/year",
            "- Platinum Tier: ~RM60,000–RM80,000/year (varies by bank policy)",
            "Welcome bonus requirements usually involve meeting a spend target "
                + "(e.g., RM100,000–RM200,000 within the first year).",
            "The \"One Cashback Plus\" branding may vary slightly by tier.",
        ] {
            XCTAssertEqual(links(in: line), [], "\"\(line)\" produced a link")
        }
    }

    /// The message is model output, and a model can be talked into writing
    /// anything. A link is the only thing in this window that acts on a click.
    func testOnlyTheThreeSafeSchemesAreFollowable() throws {
        XCTAssertTrue(ChatLinks.isFollowable(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(ChatLinks.isFollowable(try XCTUnwrap(URL(string: "http://example.com"))))
        XCTAssertTrue(ChatLinks.isFollowable(try XCTUnwrap(URL(string: "mailto:a@example.com"))))

        // The one that matters: a click must not be able to reach into the
        // owner's own disk.
        XCTAssertFalse(ChatLinks.isFollowable(try XCTUnwrap(URL(string: "file:///Users/me/.ssh/id_ed25519"))))
        XCTAssertFalse(ChatLinks.isFollowable(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertFalse(ChatLinks.isFollowable(try XCTUnwrap(URL(string: "ftp://example.com"))))
    }

    /// And the refusal has to hold through the renderer, not only in the
    /// predicate — a scheme filter nothing calls is not a filter.
    func testAFileURLInAnAnswerIsNotArmed() {
        XCTAssertEqual(links(in: "Your key is at file:///Users/me/.ssh/id_ed25519 — open it"), [])
    }

    // MARK: - Nothing else changes

    /// Detection only adds attributes. If this ever rewrites the characters,
    /// the owner is reading something other than what Mynah said, which is a
    /// worse bug than the one being fixed here.
    func testTheWordsAreNotAltered() {
        let answer = "Here are the direct links: https://www.cimb.com.my/en/personal/x.html "
            + "and a note about *emphasis*, _underscores_ and [brackets](that are not markdown)."
        XCTAssertEqual(String(ChatLinks.attributed(answer).characters), answer)
    }

    /// An answer with no URL in it comes back as ordinary text rather than as
    /// one giant link, which is the failure mode of a too-eager detector.
    func testAnAnswerWithoutLinksHasNone() {
        XCTAssertEqual(links(in: "I couldn't find an application form for that card."), [])
    }
}
