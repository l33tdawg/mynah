import XCTest
@testable import SageVoiceCore
#if canImport(FoundationNetworking)
// `URLRequest`, `URLSession` and `HTTPURLResponse` are in Foundation on a Mac
// and in this second module everywhere else. Same convention as the twenty-eight
// files under Sources/ that already reach for the network.
import FoundationNetworking
#endif

/// Regression tests for the two security defects found in adversarial review
/// of the Phase 1 subsystems. Both were reproduced with working exploits before
/// the fix; these tests exist so they cannot come back.
final class SecurityRegressionTests: XCTestCase {

    // MARK: - Allowlist: multi-entry command injection

    private let owner = "+60123456789"
    private let colleague = "+60199998888"

    /// The exploit: allowlist contains the owner AND a colleague (the documented
    /// multi-entry use case). The owner texts the colleague from their phone.
    /// signal-cli mirrors that to us as a `.syncSent` envelope. Under the old
    /// rule the destination was merely checked for allowlist membership, so a
    /// private message to a human was executed as a fleet command — and the
    /// agent's reply was delivered into the colleague's thread.
    func testOwnerMessageToAllowlistedColleagueIsNotACommand() throws {
        let allowlist = try SignalSenderAllowlist(
            commaSeparated: "\(owner),\(colleague)"
        )

        let message = SignalIncomingMessage(
            kind: .syncSent,
            account: owner,
            source: owner,
            sourceNumber: owner,
            destination: colleague,
            destinationNumber: colleague,
            timestamp: 1,
            text: "shut down the staging cluster before you leave"
        )

        XCTAssertFalse(
            allowlist.permits(message),
            "A message the owner sent to another human must never be executed as a command"
        )
    }

    /// Note to Self — the owner messaging their own account — is the one
    /// `.syncSent` shape that IS a command to this daemon.
    func testNoteToSelfIsStillAccepted() throws {
        let allowlist = try SignalSenderAllowlist(
            commaSeparated: "\(owner),\(colleague)"
        )

        let message = SignalIncomingMessage(
            kind: .syncSent,
            account: owner,
            source: owner,
            sourceNumber: owner,
            destination: owner,
            destinationNumber: owner,
            timestamp: 2,
            text: "what is on my backlog?"
        )

        XCTAssertTrue(allowlist.permits(message))
    }

    /// Fail closed: without an `account` we cannot prove the envelope was Note
    /// to Self, so it must be denied rather than falling back to the weaker
    /// allowlist-membership check.
    func testSyncWithoutAccountIsDenied() throws {
        let allowlist = try SignalSenderAllowlist(commaSeparated: owner)

        let message = SignalIncomingMessage(
            kind: .syncSent,
            account: nil,
            source: owner,
            sourceNumber: owner,
            destination: owner,
            destinationNumber: owner,
            timestamp: 3,
            text: "deploy to production"
        )

        XCTAssertFalse(allowlist.permits(message))
    }

    func testNoteToSelfOnlyIsTheDefaultPolicy() {
        XCTAssertEqual(
            SignalSenderAllowlist.Policy.strict.syncDestinationRule,
            .noteToSelfOnly,
            "The safe rule must be the default; the weaker one has to be opted into explicitly"
        )
    }

    /// A direct message from a non-allowlisted number is denied regardless.
    func testStrangerIsDenied() throws {
        let allowlist = try SignalSenderAllowlist(commaSeparated: owner)

        let message = SignalIncomingMessage(
            kind: .direct,
            account: owner,
            source: "+15550001111",
            sourceNumber: "+15550001111",
            timestamp: 4,
            text: "list all your agents"
        )

        XCTAssertFalse(allowlist.permits(message))
    }

    // MARK: - Loopback: redirect bypass

    /// The exploit: the guard checked only the URL we dialled. URLSession
    /// follows 3xx by default and re-sends the body, so a process answering on
    /// the configured loopback port could 307 the owner's transcript off-box.
    func testLoopbackPredicateRejectsSpoofedHosts() {
        let hostile = [
            "http://127.0.0.1.evil.com/steal",
            "http://127.0.0.1@evil.com/steal",
            "http://2130706433/steal",
            "https://localhost/steal",          // wrong scheme
            "http://evil.example/steal",
        ]
        for raw in hostile {
            XCTAssertFalse(
                LoopbackSecurity.isLoopback(URL(string: raw)),
                "\(raw) must not be treated as loopback"
            )
        }
        XCTAssertTrue(LoopbackSecurity.isLoopback(URL(string: "http://127.0.0.1:50060/v1")))
        XCTAssertTrue(LoopbackSecurity.isLoopback(URL(string: "http://localhost:11434/api/chat")))
    }

    /// A response that came back from somewhere other than loopback means the
    /// body already left the machine — that must surface loudly, not silently.
    func testResponseOriginOffBoxIsRejected() {
        let expected = URL(string: "http://127.0.0.1:8792/api/speech")!
        let redirected = HTTPURLResponse(
            url: URL(string: "https://evil.example/steal")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        XCTAssertThrowsError(
            try LoopbackSecurity.verifyResponseOrigin(redirected, expected: expected)
        )
    }

    func testResponseOriginOnLoopbackPasses() throws {
        let expected = URL(string: "http://127.0.0.1:50060/v1/audio/transcriptions")!
        let ok = HTTPURLResponse(url: expected, statusCode: 200, httpVersion: nil, headerFields: nil)
        XCTAssertNoThrow(try LoopbackSecurity.verifyResponseOrigin(ok, expected: expected))
    }
}
