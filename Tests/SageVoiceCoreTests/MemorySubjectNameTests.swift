import XCTest
@testable import SageVoiceCore

/// **That a key is never shown where a name belongs.**
///
/// SAGE names an agent's default home domain after the agent: `local-` and the
/// 64 hex characters of its public key. On the task board that arrived as a
/// chip reading `local-1ab7aa106b3580b5ad01042038bb9094c2adf8…`, truncated
/// mid-hash, sitting under "Book hotel for Wednesday 19th" — where the chip's
/// only job is to say which pile the task went in.
final class MemorySubjectNameTests: XCTestCase {

    /// Mynah's real id, from `~/Library/Application Support/SAGE Voice
    /// Bridge/appliance-agent.key` on the owner's Mac.
    private let mynah = "1ab7aa106b3580b5ad01042038bb9094c2adf83586967a7bbbd5e8e298ebaede"

    // MARK: The owner's own

    func testTheAppliancesHomeSubjectGetsAName() {
        XCTAssertEqual(
            MemorySubjectName.display("local-\(mynah)", applianceAgentID: mynah),
            "Mynah's own"
        )
    }

    /// The node is not consistent about case in every surface, and a label that
    /// depends on it would work on one screen and not the next.
    func testTheMatchIgnoresCase() {
        XCTAssertEqual(
            MemorySubjectName.display("LOCAL-\(mynah.uppercased())", applianceAgentID: mynah),
            "Mynah's own"
        )
    }

    /// Owner-facing strings in this product say "subject". SAGE's word is
    /// "domain", the code may use it, and the screens may not.
    func testTheNameDoesNotUseTheNodesWord() {
        XCTAssertFalse(MemorySubjectName.ownHome.lowercased().contains("domain"))
    }

    // MARK: Everybody else's

    /// A stranger's home subject is shortened, not renamed. Inventing a
    /// friendly name for an agent the owner may not recognise would be worse
    /// than a short true one.
    func testAnotherAgentsHomeSubjectIsShortenedRatherThanNamed() {
        let other = "a71125ee218a1a7dcbc98d60000000000000000000000000000000000000000"
        let shown = MemorySubjectName.display("local-\(other)", applianceAgentID: mynah)

        XCTAssertEqual(shown, "local-a71125ee…")
        XCTAssertNotEqual(shown, MemorySubjectName.ownHome, "a stranger was labelled as Mynah")
    }

    /// **The one that stops this being a find-and-replace on "local-".** A
    /// domain somebody named `local-notes` is a name its author chose, not a
    /// key, and truncating it would destroy the only readable thing about it.
    func testAnOrdinarySubjectThatHappensToStartWithLocalIsLeftAlone() {
        for name in ["local-notes", "local-", "local-team-2026"] {
            XCTAssertEqual(
                MemorySubjectName.display(name, applianceAgentID: mynah),
                name,
                "\"\(name)\" is a chosen name and was rewritten as though it were a key"
            )
        }
    }

    func testAnOrdinarySubjectIsUntouched() {
        XCTAssertEqual(
            MemorySubjectName.display("voice-interface", applianceAgentID: mynah),
            "voice-interface"
        )
    }

    // MARK: When we do not know who we are

    /// A missing key must not make every home subject read as Mynah's. Better a
    /// short hash than somebody else's memories labelled as the owner's.
    func testWithoutAnIdentityNothingIsClaimedAsMynahs() {
        for id in [nil, ""] {
            XCTAssertNotEqual(
                MemorySubjectName.display("local-\(mynah)", applianceAgentID: id),
                MemorySubjectName.ownHome,
                "claimed a subject as Mynah's while holding no identity"
            )
        }
    }

    // MARK: The predicate

    func testIsOwnHomeAgreesWithTheLabel() {
        XCTAssertTrue(MemorySubjectName.isOwnHome("local-\(mynah)", applianceAgentID: mynah))
        XCTAssertFalse(MemorySubjectName.isOwnHome("voice-interface", applianceAgentID: mynah))
    }
}
