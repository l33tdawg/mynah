import XCTest
@testable import SageVoiceCore

/// The two halves of "one link, one endpoint process".
///
/// The Go half — reaping a leftover at startup, and the watch this flag turns on
/// — is tested in `webrtc/siblings_test.go`. This is the half that lives in the
/// Mac app: the endpoint is *told* to stop with its daemon, because the failure
/// that reaches the owner otherwise is a second answerer for their own link.
final class AnEndpointStopsWithItsDaemonTests: XCTestCase {

    private func arguments(screenOnly: Bool, applianceID: String? = nil) -> [String] {
        CallHost.endpointArguments(
            relayURL: "https://call.sage.delivery",
            secretPath: "/Users/someone/.sage/call-relay.secret",
            token: String(repeating: "a", count: 32),
            appliancePath: "/Users/someone/Library/Application Support/SAGE Voice Bridge/call.sock",
            screenOnly: screenOnly,
            applianceID: applianceID
        )
    }

    /// Without this the endpoint keeps polling the owner's link after a crash or
    /// a force quit, and an old build's endpoint answers the next question.
    func testTheEndpointIsToldToStopWithItsDaemon() {
        XCTAssertTrue(arguments(screenOnly: false).contains("-exit-with-parent"))
        XCTAssertTrue(arguments(screenOnly: true).contains("-exit-with-parent"))
    }

    /// The pairing and a spoken call are different endpoints serving different
    /// links, and the flag is the only thing that distinguishes them to the
    /// process — so it has to follow the host that was asked for.
    func testOnlyTheGlassesPairingIsScreenOnly() {
        XCTAssertTrue(arguments(screenOnly: true).contains("-screen-only"))
        XCTAssertFalse(arguments(screenOnly: false).contains("-screen-only"))
    }

    /// The flags added here are past every valued argument, and the endpoint
    /// reads its link from `-token`: a rebuild that pushed a value out of place
    /// would leave an endpoint that starts, authenticates, and serves a link
    /// nobody was sent.
    func testTheLinkIsStillCarriedWhole() throws {
        let arguments = arguments(screenOnly: true, applianceID: "appliance-identity")
        XCTAssertEqual(arguments.firstIndex(of: "-token").map { arguments[$0 + 1] },
                       String(repeating: "a", count: 32))
        XCTAssertEqual(arguments.firstIndex(of: "-relay").map { arguments[$0 + 1] },
                       "https://call.sage.delivery")
        XCTAssertEqual(arguments.firstIndex(of: "-appliance-id").map { arguments[$0 + 1] },
                       "appliance-identity")
        // The exact tail, so a reordering that moved a value next to the wrong
        // flag is a failing test rather than a Mac that serves a link nobody
        // was sent.
        let appliance = try XCTUnwrap(arguments.firstIndex(of: "-appliance"))
        XCTAssertEqual(Array(arguments[appliance...]).filter { $0.hasPrefix("-") },
                       ["-appliance", "-screen-only", "-exit-with-parent", "-appliance-id"])
    }
}
