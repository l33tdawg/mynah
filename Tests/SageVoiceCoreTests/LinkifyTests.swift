import XCTest
@testable import SageVoiceCore

/// Tappable links in the reply.
///
/// The owner's phone showed a list of ramen shops with "check their website
/// mamaison.com.my" and "search via maps.google.com" — every address bare, none
/// of them tappable, because Signal linkifies text with a scheme and the model
/// does not write one.
///
/// The governing risk runs the other way from most of this codebase. A missed
/// domain leaves the owner exactly where they already were; a false positive
/// puts a dead link in their chat and makes a word look like an address. So
/// these tests spend more effort on what must *not* be linked.
final class LinkifyTests: XCTestCase {

    func testTheBareDomainsFromTheThreadBecomeTappable() {
        XCTAssertEqual(
            Linkify.promotingBareDomains(in: "check their website mamaison.com.my for current location"),
            "check their website https://mamaison.com.my for current location"
        )
        XCTAssertEqual(
            Linkify.promotingBareDomains(in: "search for their nearest branch via maps.google.com."),
            "search for their nearest branch via https://maps.google.com."
        )
        XCTAssertEqual(
            Linkify.promotingBareDomains(in: "Kyoto KatsU (kyotokatsu.com). Multiple locations"),
            "Kyoto KatsU (https://kyotokatsu.com). Multiple locations"
        )
    }

    /// Trailing punctuation belongs to the sentence, not the address. A link
    /// ending in "." resolves for some clients and not others.
    func testSentencePunctuationStaysOutsideTheLink() {
        XCTAssertEqual(
            Linkify.promotingBareDomains(in: "See siammodular.com, then sweelee.ph."),
            "See https://siammodular.com, then https://sweelee.ph."
        )
    }

    /// Already a link. Rewriting it would produce https://https://…
    func testRealURLsAreLeftAlone() {
        let already = "Festival of Modular: https://tfom.info/ and http://example.com/page"
        XCTAssertEqual(Linkify.promotingBareDomains(in: already), already)
    }

    func testTheSourcesAnnotationSurvivesUntouched() {
        let reply = "Festival of Modular, Daikanyama.\n(sources: https://tfom.info/, https://example.com)"
        XCTAssertEqual(Linkify.promotingBareDomains(in: reply), reply)
    }

    // MARK: What must not be linked

    /// The appliance writes markdown notes and says their filenames out loud.
    /// `.md` is a real TLD (Moldova), which is exactly the trap.
    func testTheNotesItWritesAreNotTurnedIntoLinks() {
        for filename in [
            "Your note tokyo-trip.md is saved.",
            "I saved eurorack-store-urls-japan-thailand-philippines.md for you.",
            "the script is deploy.sh and the config is settings.py"
        ] {
            XCTAssertEqual(
                Linkify.promotingBareDomains(in: filename),
                filename,
                "a filename was turned into a dead link"
            )
        }
    }

    /// Ordinary sentences that happen to contain dots.
    func testProseIsNotLinked() {
        for sentence in [
            "It's at 10 a.m. tomorrow.",
            "Version 11.13.9 is deployed.",
            "e.g. the backlog is empty",
            "Ton Chan Ramen - Located at LOT 1.18, 1st Floor Wisma Cosway"
        ] {
            XCTAssertEqual(
                Linkify.promotingBareDomains(in: sentence),
                sentence,
                "\"\(sentence)\" gained a link"
            )
        }
    }

    /// An email address is not a website, and half of one is nothing at all.
    func testEmailAddressesAreNotHalfLinked() {
        let text = "mail dhillon.andrew@gmail.com about it"
        XCTAssertEqual(Linkify.promotingBareDomains(in: text), text)
    }

    // MARK: Paths and shape

    func testAPathOnTheDomainIsKept() {
        XCTAssertEqual(
            Linkify.promotingBareDomains(in: "see sweelee.ph/pages/our-locations for branches"),
            "see https://sweelee.ph/pages/our-locations for branches"
        )
    }

    /// Where the owner actually is. "mamaison.com.my" is the string that
    /// prompted the whole feature.
    func testTheRegionalDomainsTheOwnerUsesAreCovered() {
        for domain in ["shop.com.my", "store.sg", "thai-modular.th", "sweelee.ph", "five-g.jp"] {
            XCTAssertTrue(
                Linkify.promotingBareDomains(in: "visit \(domain) today").contains("https://\(domain)"),
                "\(domain) was left bare"
            )
        }
    }

    func testAnEmptyOrPlainReplyIsUnchanged() {
        XCTAssertEqual(Linkify.promotingBareDomains(in: ""), "")
        XCTAssertEqual(
            Linkify.promotingBareDomains(in: "Your note is saved with three packing bullet points."),
            "Your note is saved with three packing bullet points."
        )
    }

    /// The transform runs on every outgoing message, so it must be stable —
    /// applying it twice must not change the result again.
    func testItIsIdempotent() {
        let once = Linkify.promotingBareDomains(in: "check mamaison.com.my and kyotokatsu.com")
        XCTAssertEqual(Linkify.promotingBareDomains(in: once), once)
    }
}
