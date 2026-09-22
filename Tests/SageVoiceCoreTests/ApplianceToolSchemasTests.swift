import XCTest
@testable import SageVoiceCore

/// **The fixture and the tool that ships must be the same schema.**
///
/// `Tests/Fixtures/appliance-tool-schemas.json` exists because the routing sweep
/// builds its catalogues from SAGE's `tools/list`, and `schedule_work` is not
/// SAGE's — so without this the sweep would measure a catalogue that is missing
/// the tool the change added, and its rows would describe something nobody runs.
///
/// Two copies of a description is exactly the arrangement this repository has
/// been burned by twice: the sweep's own tool list drifted out of the appliance
/// for months under a comment saying it could not, and the spoken hints needed
/// `SpokenToolHintsTests` for the same reason. So the pair is pinned here rather
/// than trusted — the fixture is generated from
/// `ScheduledWorkToolSource.listTools()`, and this fails the moment the two stop
/// agreeing. Regenerate it with the dump in the same commit as any wording
/// change: `PROMPT`/`SCHEMA` are written to /tmp by the sweep's own instructions
/// in `scripts/measure-tool-routing.py`.
final class ApplianceToolSchemasTests: XCTestCase {

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/appliance-tool-schemas.json")
    }

    func testTheFixtureIsExactlyWhatTheAppliancePublishes() async throws {
        let fixture = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtureURL)
        ) as? [String: Any]
        let stored = try XCTUnwrap(fixture?["tools"], "the fixture has no tools")

        let live = try await ScheduledWorkToolSource().listTools()
        let published = try PromptStableJSON.data(from: ["tools": live.map(\.brainTool.ollamaWireObject)])
        let written = try PromptStableJSON.data(from: ["tools": stored])

        XCTAssertEqual(
            String(data: published, encoding: .utf8),
            String(data: written, encoding: .utf8),
            """
            Tests/Fixtures/appliance-tool-schemas.json no longer matches the tool this \
            repository publishes, so the routing sweep is measuring a description nobody \
            ships. Regenerate the fixture from ScheduledWorkToolSource.listTools().
            """
        )
    }

    /// And the sweep is looking at the right file, by name.
    func testTheSweepReadsThisFixture() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/measure-tool-routing.py"),
            encoding: .utf8
        )
        XCTAssertTrue(
            script.contains("Tests/Fixtures/appliance-tool-schemas.json"),
            "the sweep stopped reading the fixture, so its catalogues lost the tool this fixture is for"
        )
        XCTAssertTrue(
            script.contains("schedule_work"),
            "the sweep's allowlist does not know about the appliance's own tool"
        )
    }
}
