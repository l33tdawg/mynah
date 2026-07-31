import XCTest
@testable import SageVoiceCore

/// The thirteen minutes a brand-new node spends unable to remember.
///
/// The fixtures are real `/abci_info` bodies taken from a fresh vendored 11.16.1
/// node, not hand-written shapes: both numbers arrive as JSON *strings*, which
/// is the detail a plausible-looking fixture gets wrong.
final class SageActivationCountdownTests: XCTestCase {

    private func body(appVersion: String?, height: String) -> Data {
        let version = appVersion.map { "\"app_version\": \"\($0)\"," } ?? ""
        return Data("""
        {"jsonrpc":"2.0","id":-1,"result":{"response":{
          "data":"sage","version":"11.16.1",\(version)
          "last_block_height":"\(height)",
          "last_block_app_hash":"z1XmbavoBl8iP+VkUSGkz8UGTgT13CvHEbVyWLcedpE="
        }}}
        """.utf8)
    }

    // MARK: - Parsing

    func testParsesStringEncodedNumbers() {
        let state = SageActivationProbe.parse(body(appVersion: "23", height: "17"))
        XCTAssertEqual(state?.appVersion, 23)
        XCTAssertEqual(state?.height, 17)
    }

    /// A body with no `app_version` must read as 0, not fail to parse. It means
    /// "not v24", which is the only thing the caller acts on.
    func testMissingAppVersionReadsAsZeroRatherThanFailing() {
        let state = SageActivationProbe.parse(body(appVersion: nil, height: "9"))
        XCTAssertEqual(state?.appVersion, 0)
        XCTAssertEqual(state?.height, 9)
        XCTAssertFalse(state?.isActivated ?? true)
    }

    func testGarbageIsNotAState() {
        XCTAssertNil(SageActivationProbe.parse(Data("{}".utf8)))
        XCTAssertNil(SageActivationProbe.parse(Data("not json".utf8)))
    }

    /// The bytes a real node actually sent, not a fixture written from memory.
    ///
    /// Captured with `curl` from a fresh vendored 11.16.1 node mid-countdown —
    /// app-v23, height 93, still waiting on the governed upgrade. A hand-written
    /// fixture is a record of what someone believed the shape was; this is a
    /// record of what it is.
    func testParsesACaptureFromARealPreActivationNode() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SageVoiceCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/abci_info-11.16.1-preactivation.json")
        let data = try Data(contentsOf: url)
        let state = try XCTUnwrap(SageActivationProbe.parse(data))

        XCTAssertEqual(state.appVersion, 23)
        XCTAssertEqual(state.height, 93)
        XCTAssertFalse(state.isActivated, "app-v23 is exactly the state that cannot write")
        XCTAssertEqual(state.blocksRemaining, 111)
        XCTAssertEqual(state.ownerDescription, "Getting SAGE ready — about 8 minutes left.")
    }

    // MARK: - The verdict comes from the version, never the height

    /// The whole safety property of this type. The height is an estimate; the
    /// version is consensus. A node past the estimated height that has *not*
    /// flipped must not be reported as ready.
    func testPastTheEstimatedHeightButStillOnV23IsNotActivated() {
        let state = SageActivationState(appVersion: 23, height: 900)
        XCTAssertFalse(state.isActivated)
        XCTAssertEqual(state.blocksRemaining, 0)
        XCTAssertEqual(state.ownerDescription, "Getting SAGE ready — nearly there.")
    }

    /// And the converse: activated early is still activated.
    func testActivatedBeforeTheEstimatedHeightIsActivated() {
        let state = SageActivationState(appVersion: 24, height: 12)
        XCTAssertTrue(state.isActivated)
        XCTAssertEqual(state.blocksRemaining, 0)
        XCTAssertNil(state.estimatedSecondsRemaining)
        XCTAssertEqual(state.fractionComplete, 1)
        XCTAssertEqual(state.ownerDescription, "SAGE is ready.")
    }

    // MARK: - Counting down, not up

    func testCountsDownAsHeightRises() {
        let early = SageActivationState(appVersion: 23, height: 4)
        let later = SageActivationState(appVersion: 23, height: 150)
        XCTAssertEqual(early.blocksRemaining, 200)
        XCTAssertEqual(later.blocksRemaining, 54)
        XCTAssertLessThan(later.blocksRemaining, early.blocksRemaining)
        XCTAssertGreaterThan(later.fractionComplete, early.fractionComplete)
    }

    /// Genesis on a real node: ~204 blocks at ~4s is the thirteen minutes this
    /// whole feature exists to explain.
    func testAFreshNodeReportsRoughlyThirteenMinutes() throws {
        let state = SageActivationState(appVersion: 23, height: 1)
        let seconds = try XCTUnwrap(state.estimatedSecondsRemaining)
        XCTAssertEqual(seconds / 60, 13.5, accuracy: 1.0)
    }

    func testFractionIsClampedToUnitRange() {
        XCTAssertEqual(SageActivationState(appVersion: 23, height: 0).fractionComplete, 0)
        XCTAssertEqual(SageActivationState(appVersion: 23, height: 5_000).fractionComplete, 1)
    }

    // MARK: - Owner-facing wording

    /// Never "0 minutes". A countdown that hits zero while the node is still
    /// working has started lying at the last moment.
    func testTheLastMinuteNeverReadsAsZero() {
        for height in (SageActivationState.estimatedActivationHeight - 14)...SageActivationState.estimatedActivationHeight {
            let line = SageActivationState(appVersion: 23, height: height).ownerDescription
            XCTAssertFalse(line.contains("0 minutes"), "said '\(line)' at height \(height)")
            XCTAssertFalse(line.contains("about 1 minutes"), "said '\(line)' at height \(height)")
        }
    }

    func testWordingRoundsUpRatherThanDown() {
        // 100 blocks left ≈ 400s ≈ 6.67 min, which must not read as "6".
        XCTAssertEqual(
            SageActivationState(appVersion: 23, height: 104).ownerDescription,
            "Getting SAGE ready — about 7 minutes left."
        )
    }

    // MARK: - Endpoint resolution

    func testDefaultsToCometBFTsLoopbackRPC() {
        let url = SageActivationProbe.defaultEndpoint(environment: [:])
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:26657/abci_info")
    }

    /// CometBFT writes `tcp://`, which `URLSession` will not fetch.
    func testRewritesTheTCPSchemeTheNodeActuallyWrites() {
        let url = SageActivationProbe.defaultEndpoint(
            environment: ["SAGE_CMT_RPC_ADDR": "tcp://127.0.0.1:36657"]
        )
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:36657/abci_info")
    }

    /// Same rule as `SAGE_API_URL`: a reading taken from a stranger's node is
    /// somebody else's chain reported as the owner's.
    func testANonLoopbackOverrideIsIgnoredRatherThanObeyed() {
        let url = SageActivationProbe.defaultEndpoint(
            environment: ["SAGE_CMT_RPC_ADDR": "tcp://198.51.100.7:26657"]
        )
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:26657/abci_info")
    }
}
