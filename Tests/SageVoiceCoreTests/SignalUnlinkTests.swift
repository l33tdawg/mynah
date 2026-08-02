import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **Unlinking has two halves and they fail separately.**
///
/// The owner: *"there should be a button to unlink bro so we can relink to a
/// different phone number / device"*. Taking this Mac off his Signal account
/// needs the network; deleting the keys from this Mac does not. A Mac that is
/// offline must still be unlinkable, or the button is useless exactly when
/// somebody is travelling with a new SIM — and it must then say what is left to
/// do, because a device silently abandoned on a Signal account is something
/// discovered a year later and never explained.
final class SignalUnlinkTests: XCTestCase {

    /// Answers by command, and records what it was asked, so the arguments are
    /// assertable — the difference between passing `--ignore-registered` and not
    /// is the difference between a tidy unlink and a messy one.
    private final class StubRunner: ProbeCommandRunning, @unchecked Sendable {
        var results: [String: ProbeCommandResult] = [:]
        private(set) var invocations: [[String]] = []

        func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> ProbeCommandResult? {
            invocations.append(arguments)
            guard let command = arguments.first(where: {
                $0 == "unregister" || $0 == "deleteLocalAccountData"
            }) else { return nil }
            return results[command]
        }
    }

    private let helper = URL(fileURLWithPath: "/opt/homebrew/bin/signal-cli")
    private let number = "+60123456789"

    private func ok() -> ProbeCommandResult {
        ProbeCommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    private func failed() -> ProbeCommandResult {
        ProbeCommandResult(exitCode: 1, standardOutput: "", standardError: "connection refused")
    }

    // MARK: It went cleanly

    func testBothHalvesSucceed() async {
        let runner = StubRunner()
        runner.results = ["unregister": ok(), "deleteLocalAccountData": ok()]

        let outcome = await SignalUnlink(helper: helper, runner: runner).run(account: number)

        XCTAssertTrue(outcome.removedFromAccount)
        XCTAssertTrue(outcome.localDataDeleted)
        XCTAssertTrue(outcome.canRelink)
        XCTAssertNil(outcome.note, "a clean unlink has nothing to tell anybody")
    }

    /// `--ignore-registered` deletes the keys while leaving the device on the
    /// account. Passing it when the server step already worked would make the
    /// messy outcome the every-time outcome.
    func testItDoesNotIgnoreRegistrationWhenUnregisterWorked() async {
        let runner = StubRunner()
        runner.results = ["unregister": ok(), "deleteLocalAccountData": ok()]

        _ = await SignalUnlink(helper: helper, runner: runner).run(account: number)

        let delete = runner.invocations.first { $0.contains("deleteLocalAccountData") }
        XCTAssertNotNil(delete)
        XCTAssertFalse(delete?.contains("--ignore-registered") ?? true)
    }

    /// **Never one argument away from deleting his Signal number.**
    /// `unregister --delete-account` removes the account from Signal's servers,
    /// and nothing reachable from a settings button should be able to reach it.
    func testItNeverDeletesTheAccountFromSignal() async {
        let runner = StubRunner()
        runner.results = ["unregister": ok(), "deleteLocalAccountData": ok()]

        _ = await SignalUnlink(helper: helper, runner: runner).run(account: number)

        for arguments in runner.invocations {
            XCTAssertFalse(arguments.contains("--delete-account"), "\(arguments)")
        }
    }

    // MARK: Offline

    /// The half that needs the network failed. The Mac is still unlinked — that
    /// is what lets somebody on a plane link a different phone — and the owner is
    /// told the one thing left for them to do.
    func testAnOfflineMacStillUnlinks() async {
        let runner = StubRunner()
        runner.results = ["unregister": failed(), "deleteLocalAccountData": ok()]

        let outcome = await SignalUnlink(helper: helper, runner: runner).run(account: number)

        XCTAssertFalse(outcome.removedFromAccount)
        XCTAssertTrue(outcome.canRelink)
        XCTAssertEqual(
            outcome.note?.contains("Linked Devices"),
            true,
            "a device left on his account is a step only he can finish: \(outcome.note ?? "nil")"
        )
    }

    func testItIgnoresRegistrationOnlyWhenUnregisterFailed() async {
        let runner = StubRunner()
        runner.results = ["unregister": failed(), "deleteLocalAccountData": ok()]

        _ = await SignalUnlink(helper: helper, runner: runner).run(account: number)

        let delete = runner.invocations.first { $0.contains("deleteLocalAccountData") }
        XCTAssertTrue(delete?.contains("--ignore-registered") ?? false)
    }

    // MARK: Nothing happened

    /// The keys are still on disk, so the Mac is still linked. Reporting success
    /// here would leave the owner scanning a code that cannot work.
    func testAFailedDeleteIsNotAnUnlink() async {
        let runner = StubRunner()
        runner.results = ["unregister": ok(), "deleteLocalAccountData": failed()]

        let outcome = await SignalUnlink(helper: helper, runner: runner).run(account: number)

        XCTAssertFalse(outcome.canRelink)
        XCTAssertEqual(outcome.note?.contains("still") , true, outcome.note ?? "nil")
    }

    /// A binary that will not launch at all is a failure, not a crash and not a
    /// silent success.
    func testAMissingBinaryIsAFailureRatherThanAThrow() async {
        let runner = StubRunner()   // every command answers nil

        let outcome = await SignalUnlink(helper: helper, runner: runner).run(account: number)

        XCTAssertFalse(outcome.removedFromAccount)
        XCTAssertFalse(outcome.localDataDeleted)
        XCTAssertFalse(outcome.canRelink)
        XCTAssertNotNil(outcome.note)
    }

    /// A wedged signal-cli that never returns must not leave the button spinning
    /// forever, and a timeout is not a success.
    func testATimeoutIsNotASuccess() async {
        let runner = StubRunner()
        runner.results = [
            "unregister": ProbeCommandResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: true),
            "deleteLocalAccountData": ok()
        ]

        let outcome = await SignalUnlink(helper: helper, runner: runner).run(account: number)

        XCTAssertFalse(outcome.removedFromAccount)
    }

    // MARK: Every dead end has a door

    /// Whatever happened, the owner is left with something to do rather than a
    /// description of a state.
    func testEveryOutcomeThatIsNotCleanNamesTheNextAction() {
        let outcomes = [
            SignalUnlink.Outcome(removedFromAccount: false, localDataDeleted: true),
            SignalUnlink.Outcome(removedFromAccount: true, localDataDeleted: false),
            SignalUnlink.Outcome(removedFromAccount: false, localDataDeleted: false)
        ]

        for outcome in outcomes {
            guard let note = outcome.note else {
                return XCTFail("\(outcome) said nothing")
            }
            XCTAssertTrue(
                note.contains("remove") || note.contains("Try once more"),
                "no next action in: \(note)"
            )
        }
    }
}
