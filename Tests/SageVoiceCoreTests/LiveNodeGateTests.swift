import XCTest
@testable import SageVoiceCore

/// **A defence nobody switched on.**
///
/// Four tests read the SAGE on this Mac, and they exist for one reason: they are
/// the only tests here that can catch code reading a shape the node stopped
/// emitting. That family cost 1.7.5 four separate fixes, and every one of them
/// had passing tests — because a stub agrees with whatever the code expects, so
/// the bug is invisible to it by construction.
///
/// They were gated on an environment variable that appeared nowhere in
/// `scripts/` or `.github/`, under two different names. A skipped test counts as
/// a pass. So the defence written for the exact defect this project keeps
/// hitting was skipped in every build that has ever shipped, and the release
/// gate's skip ceiling quietly had room for it.
///
/// These tests are about the wiring, not the node — they need no node to run.
final class LiveNodeGateTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The release turns them on. Without this line the four tests skip in the
    /// one run where they matter most — the build that gets signed.
    func testTheReleaseSwitchesTheLiveNodeTestsOn() throws {
        let release = try text("scripts/release.sh")
        XCTAssertTrue(
            release.contains("export \(LiveNode.primaryVariable)=1"),
            "scripts/release.sh never sets \(LiveNode.primaryVariable), so the only tests that can "
                + "see a node-shape change skip in every release"
        )
        XCTAssertTrue(
            release.contains("live-node tests: ON") && release.contains("live-node tests: OFF"),
            "the release must say which way it went; a silent 'off' is how this went unnoticed "
                + "for five releases"
        )
    }

    /// **One name, read in one place.** Two spellings of one switch is what made
    /// the gap survive a search: three sites said `MYNAH_LIVE_NODE_TESTS` and a
    /// fourth said `SAGE_LIVE_NODE`, so finding either one made the other look
    /// covered.
    func testNoTestReachesForTheEnvironmentVariableItself() throws {
        let directory = root.appendingPathComponent("Tests/SageVoiceCoreTests")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        for file in files where file.lastPathComponent != "LiveNode.swift" {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for spelling in ["MYNAH_LIVE_NODE_TESTS", "SAGE_LIVE_NODE"] {
                // This file names them in prose, which is the point of it.
                guard file.lastPathComponent != "LiveNodeGateTests.swift" else { continue }
                XCTAssertFalse(
                    source.contains(#"environment["\#(spelling)"]"#),
                    "\(file.lastPathComponent) reads \(spelling) directly instead of going through "
                        + "LiveNode, which is how one switch became two names that hid each other"
                )
            }
        }
    }

    /// The old spelling still works. A name that silently stops working is the
    /// same failure in different clothes, and `SAGE_LIVE_NODE` is in the owner's
    /// shell history.
    func testTheOlderNameIsStillHonoured() throws {
        let helper = try text("Tests/SageVoiceCoreTests/LiveNode.swift")
        XCTAssertTrue(
            helper.contains("SAGE_LIVE_NODE"),
            "dropping the old name means a command the owner has already typed silently stops "
                + "running the tests it used to"
        )
    }
}
