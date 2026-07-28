import XCTest
@testable import SageVoiceCore

/// "Where your words go", answered by the process that actually sends them.
///
/// Settings answered it from `BrainSelectionStore` — what the owner picked in
/// the app — and nothing outside MynahMac reads that. The daemon builds its own
/// backend from its launch flags, so after the appliance was switched to
/// DeepSeek by hand, Settings still said "Fully on this Mac", the pill still
/// said "This Mac", and the privacy section still said nothing leaves the
/// machine, while every voice note went to a third party.
///
/// On a product whose whole pitch is where-your-words-go, that is the one
/// question that must never be wrong.
final class ApplianceStatusTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appliance-status-\(UUID().uuidString)", isDirectory: true)
        file = directory.appendingPathComponent("appliance-status.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheApplianceReportsWhatItActuallyResolved() {
        ApplianceStatus.publish(
            ApplianceStatus(
                provider: "deepseek",
                model: "deepseek-v4-flash",
                keepsWordsOnDevice: false
            ),
            to: file
        )

        let asSettingsSeesIt = ApplianceStatus.current(from: file)
        XCTAssertEqual(asSettingsSeesIt?.provider, "deepseek")
        XCTAssertEqual(asSettingsSeesIt?.model, "deepseek-v4-flash")
        XCTAssertEqual(asSettingsSeesIt?.destination, "deepseek")
        XCTAssertFalse(asSettingsSeesIt?.keepsWordsOnDevice ?? true)
    }

    /// The claim that matters most, and the only one worth making unconditional.
    func testALocalApplianceSaysTheWordsStayPut() {
        ApplianceStatus.publish(
            ApplianceStatus(provider: "ollama", model: "qwen3.5:4b", keepsWordsOnDevice: true),
            to: file
        )
        XCTAssertEqual(ApplianceStatus.current(from: file)?.destination, "This Mac")
    }

    /// "Nobody has answered a phone here" is a different sentence from any
    /// provider name, and must not be papered over with a default.
    func testNeverHavingRunIsItsOwnAnswer() {
        XCTAssertNil(ApplianceStatus.current(from: file))
    }

    func testACorruptReportIsTreatedAsNoReport() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        XCTAssertNil(
            ApplianceStatus.current(from: file),
            "a damaged file must not be reported as a provider"
        )
    }

    /// It records which provider the owner's words reached, so it gets the same
    /// treatment as the rest of that directory.
    func testTheReportIsOwnerOnly() throws {
        ApplianceStatus.publish(
            ApplianceStatus(provider: "ollama", model: "qwen3.5:4b", keepsWordsOnDevice: true),
            to: file
        )
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode, 0o600)
    }

    /// Publishing must never be able to stop the daemon starting. That lesson
    /// cost an outage.
    func testPublishingToAnImpossiblePathDoesNotThrow() {
        ApplianceStatus.publish(
            ApplianceStatus(provider: "ollama", model: "m", keepsWordsOnDevice: true),
            to: URL(fileURLWithPath: "/dev/null/nope/status.json")
        )
    }

    func testTheStartTimeSurvivesTheRoundTrip() {
        let started = Date(timeIntervalSince1970: 1_785_000_000)
        ApplianceStatus.publish(
            ApplianceStatus(
                provider: "deepseek", model: "deepseek-v4-flash",
                keepsWordsOnDevice: false, startedAt: started
            ),
            to: file
        )
        let read = ApplianceStatus.current(from: file)?.startedAt
        XCTAssertNotNil(read)
        XCTAssertEqual(read!.timeIntervalSince1970, started.timeIntervalSince1970, accuracy: 1)
    }
}
