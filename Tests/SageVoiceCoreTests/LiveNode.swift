import Foundation
import XCTest

/// The one switch that turns on every test which talks to the SAGE on this Mac.
///
/// ## Why this exists
///
/// Four tests were written to catch the 1.7.5 defect family — code reading a
/// SAGE shape the node had stopped emitting, where a vanished key reads as a
/// legal falsy value and nothing anywhere fails. They are the only tests in this
/// suite that can see that class of bug at all, because it is invisible to a
/// stub: a fixture agrees with whatever the code expects, by construction.
///
/// **None of them had ever run on a release.** Two names gated one opt-in —
/// three sites read `MYNAH_LIVE_NODE_TESTS` and a fourth read `SAGE_LIVE_NODE` —
/// and neither name appeared anywhere in `scripts/` or `.github/`. So the
/// defence written for the exact failure that cost 1.7.5 four fixes was skipped
/// in every build that has ever shipped, and the skip counted as a pass.
///
/// One name now, read in one place. `SAGE_LIVE_NODE` is still honoured because
/// it is in the owner's shell history and a name that silently stops working is
/// the same failure wearing different clothes.
enum LiveNode {

    static let primaryVariable = "MYNAH_LIVE_NODE_TESTS"

    /// Whether this run may talk to the node.
    static var isOn: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment[primaryVariable] == "1" || environment["SAGE_LIVE_NODE"] == "1"
    }

    /// Skips unless the live node is switched on.
    ///
    /// The message names the variable, because a skip nobody can act on is a
    /// hole nobody closes.
    static func required(_ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(
            isOn,
            "set \(primaryVariable)=1 to run against the SAGE on this machine — \(what)",
            file: file, line: line
        )
    }
}
