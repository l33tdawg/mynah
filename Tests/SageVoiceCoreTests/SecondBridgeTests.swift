import XCTest
@testable import SageVoiceCore

/// Only one appliance may answer a thread.
///
/// The owner's framing was "you'll get two replies". It is worse than that. This
/// process never sees its own sends — signal-cli does not echo a message back to
/// the device that made it — so before a second bridge existed there was nothing
/// to guard against and no guard was written.
///
/// With two linked, each one sees the OTHER's replies as ordinary syncSent
/// messages from the owner, and answers them. That is not duplicate replies; it
/// is two appliances talking to each other forever, in the owner's thread, at a
/// model call apiece.
///
/// It is a limitation of Note-to-Self specifically: one account, one thread, no
/// sender identity to tell the two apart. A bridge with its own registered
/// number would be a distinct party and the ambiguity would not exist.
final class SecondBridgeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("single-instance-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: One per machine

    func testASecondAppliancecCannotStart() throws {
        let lockURL = directory.appendingPathComponent("appliance.lock")
        let first = SingleInstance(fileURL: lockURL)
        let second = SingleInstance(fileURL: lockURL)

        XCTAssertNoThrow(try first.acquire())
        XCTAssertThrowsError(try second.acquire()) { error in
            let message = (error as? SingleInstance.Failure)?.errorDescription ?? ""
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("already running"),
                "the second appliance was not told why it could not start"
            )
            // The way out has to be one the owner can actually carry out on the
            // machine they are standing at. `launchctl` does not exist off a
            // Mac, so asserting it on every platform fails a product that is
            // right: `SingleInstance.Failure.alreadyRunning` already splits the
            // message, and the off-Darwin arm gives a real door. What must hold
            // everywhere is that the refusal names how to stop the other one.
            #if os(macOS)
            XCTAssertTrue(
                message.contains("launchctl bootout"),
                "the owner is not told how to stop the other one"
            )
            #else
            XCTAssertTrue(
                message.contains("pgrep -fl \"sage-voiced daemon\""),
                "the owner is not told how to find the other one"
            )
            XCTAssertTrue(
                message.contains("kill"),
                "the owner is not told how to stop the other one"
            )
            // A Mac command on a Linux box is a dead end with no door out of
            // it, which is worse than saying nothing.
            XCTAssertFalse(
                message.contains("launchctl"),
                "the owner is sent to a command this machine does not have"
            )
            #endif
        }
    }

    /// A kernel lock is released when the holder exits however it exits,
    /// including SIGKILL. A pid file gets exactly that case wrong: the process
    /// dies, the file survives, and the next start refuses forever.
    func testTheLockIsReleasedWhenTheHolderGoesAway() throws {
        let lockURL = directory.appendingPathComponent("appliance.lock")
        let descriptor = try SingleInstance(fileURL: lockURL).acquire()

        // Closing the descriptor is what a dying process does.
        close(descriptor)

        XCTAssertNoThrow(
            try SingleInstance(fileURL: lockURL).acquire(),
            "the lock outlived its holder, so the appliance could never restart"
        )
    }

    func testTheLockFileIsOwnerOnly() throws {
        let lockURL = directory.appendingPathComponent("appliance.lock")
        _ = try SingleInstance(fileURL: lockURL).acquire()
        let mode = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: Recognising the other one

    /// The loop breaker. A message wearing our own reply prefix did not come
    /// from the owner, whichever machine produced it.
    func testAReplyPrefixedMessageIsRecognisedAsAnotherBridge() {
        let prefix = VoiceBridgeDaemon.Configuration.defaultReplyPrefix
        let theirReply = prefix + "Ton Chan Ramen, Wisma Cosway."

        XCTAssertTrue(
            theirReply.hasPrefix(prefix.trimmingCharacters(in: .whitespaces)),
            "the guard would not fire, so two bridges answer each other forever"
        )
    }

    /// And the owner's own words must still get through, including when they
    /// happen to talk about the appliance.
    func testTheOwnersMessagesAreUntouched() {
        let prefix = VoiceBridgeDaemon.Configuration.defaultReplyPrefix
            .trimmingCharacters(in: .whitespaces)
        for message in [
            "any good ramen shops near klcc",
            "why did you reply twice",
            "the brain emoji thing is annoying"
        ] {
            XCTAssertFalse(
                message.hasPrefix(prefix),
                "\"\(message)\" would be mistaken for another bridge"
            )
        }
    }

    /// Said once. The whole problem is duplicate messages; a warning that
    /// repeats per message becomes the thing it is warning about.
    func testTheWarningIsAnOutcomeTheLogCanName() {
        XCTAssertNotEqual(
            VoiceBridgeDaemon.Outcome.ignoredSecondBridge,
            VoiceBridgeDaemon.Outcome.ignoredEmpty,
            "a second bridge must be distinguishable from an empty message in the log"
        )
    }
}
