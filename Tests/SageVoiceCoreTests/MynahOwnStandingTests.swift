import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **The Memories page says who Mynah is, and where what it learns goes.**
///
/// #6, and the premise it sat blocked under for three releases was wrong. It was
/// filed as blocked on `GET /v1/agents` returning 401, which was read as "the
/// appliance cannot report its own standing". A 401 on a *roster* says nothing
/// of the kind: `sage_status` is signed, so its answer is necessarily about
/// whoever asked, and pending-review agents are supported by it too — without
/// probing any memory route they are forbidden from touching.
///
/// The screen needs this for a reason 1.7.4 made concrete. Mynah spent months
/// filing every episodic turn into `voice-interface`, a subject belonging to
/// another agent, and this page could not have shown the difference: it knew
/// what it had *read* and nothing about the agent doing the reading. An
/// appliance writing into somebody else's subject looked exactly like one filing
/// correctly.
final class MynahOwnStandingTests: XCTestCase {

    /// The owner's real node, captured. See `ApplianceStanding` for why every
    /// fixture standing in for SAGE in this repository is now a capture.
    private func capturedStatus() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/sage_status-11.17.9-appv26-appliance.json"),
            encoding: .utf8
        )
    }

    func testItNamesTheSubjectMynahActuallyFilesInto() throws {
        let standing = try XCTUnwrap(ApplianceStanding.fromStatus(try capturedStatus()))

        XCTAssertEqual(
            MemoriesView.standingSentence(standing),
            "Files into mynah-home, and may also write to sage-v3.6.0-audit and user-interaction."
        )
    }

    /// **The line that would have exposed the 1.7.4 defect.**
    ///
    /// `voice-interface` is readable on the owner's node and is not writable —
    /// it belongs to a different agent — and Mynah wrote every episodic turn
    /// into it anyway. Naming the *writable* set rather than the readable one is
    /// what makes this sentence load-bearing instead of decorative: readable is
    /// seventeen subjects on this node, most of them the owner's working life,
    /// and printing those would say nothing about where anything goes.
    func testItNamesWhatMynahMayWriteAndNotWhatItMayRead() throws {
        let standing = try XCTUnwrap(ApplianceStanding.fromStatus(try capturedStatus()))
        let sentence = MemoriesView.standingSentence(standing)

        XCTAssertTrue(
            standing.readableDomains.contains("voice-interface"),
            "the capture must still contain the subject this test is about"
        )
        XCTAssertFalse(
            standing.writableDomains.contains("voice-interface"),
            "voice-interface is another agent's; if it became writable this test means nothing"
        )
        XCTAssertFalse(
            sentence.contains("voice-interface"),
            "the page names a subject Mynah cannot write to as somewhere it files things: \(sentence)"
        )
        // And it is not merely omitting everything.
        XCTAssertTrue(sentence.contains("mynah-home"), sentence)
    }

    /// A review state outranks the description, because it is the only part that
    /// asks the owner to do anything.
    func testAnUnapprovedApplianceSaysSoInsteadOfDescribingItself() {
        let pending = ApplianceStanding(
            registrationStatus: "pending_review",
            approvalRequired: true,
            canWrite: false,
            homeDomain: "mynah-home"
        )
        let sentence = MemoriesView.standingSentence(pending)

        XCTAssertTrue(sentence.contains("CEREBRUM"), sentence)
        XCTAssertFalse(
            sentence.contains("Files into"),
            "it told the owner where things are being saved while nothing is being saved: \(sentence)"
        )
    }

    /// Refused writes are the other half of "nothing is landing", and the node
    /// states them separately from approval.
    func testARefusedWriteIsAlsoReportedRatherThanDescribed() {
        let refused = ApplianceStanding(
            approvalRequired: false, canWrite: false, homeDomain: "mynah-home"
        )
        XCTAssertTrue(MemoriesView.standingSentence(refused).contains("nothing is being saved"))
    }

    /// An agent with a home and nothing else keeps the short sentence.
    func testTheCommonCaseIsOneClause() {
        let plain = ApplianceStanding(homeDomain: "mynah-home", writableDomains: ["mynah-home"])
        XCTAssertEqual(MemoriesView.standingSentence(plain), "Files into mynah-home.")
    }

    /// Answered, and owning nothing. Says that rather than an empty list.
    func testAnAgentWithNoSubjectSaysSo() {
        let homeless = ApplianceStanding(homeDomain: "", writableDomains: [])
        XCTAssertEqual(MemoriesView.standingSentence(homeless), "No subject of its own yet.")
    }

    /// **"Subject", never "domain".** SAGE's word stays in the code; the owner
    /// reads what the rest of the app already says to them. One mechanism
    /// explained in two vocabularies is worse than either — the rule
    /// `ApplianceWriteReadiness` follows and `OneVerbForMemoryTests` polices.
    ///
    /// The subject *names* are the node's and are printed verbatim, so the check
    /// is on the prose around them.
    func testTheSentenceUsesTheOwnersVocabulary() throws {
        let sentences = [
            MemoriesView.standingSentence(try XCTUnwrap(ApplianceStanding.fromStatus(try capturedStatus()))),
            MemoriesView.standingSentence(ApplianceStanding(approvalRequired: true)),
            MemoriesView.standingSentence(ApplianceStanding(homeDomain: "", writableDomains: []))
        ]
        for sentence in sentences {
            for leak in ["domain", "mask", "capabilit", "app-v2", "RBAC", "agent_id"] {
                XCTAssertFalse(
                    sentence.lowercased().contains(leak.lowercased()),
                    "\"\(sentence)\" uses the node's word rather than the owner's: \(leak)"
                )
            }
        }
    }
}
