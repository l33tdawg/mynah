import Foundation
import SageVoiceCore

/// Taking this Mac back off the owner's Signal account.
///
/// The owner: *"there should be a button to unlink bro so we can relink to a
/// different phone number / device"*. Until now the screen rendered no button at
/// all, which was honest — `unlink()` threw `notSupportedYet` — and useless: a
/// Mac linked to the wrong phone could only be fixed by deleting files by hand.
///
/// ## Two steps, because they fail separately
///
/// **Unregister** takes this Mac off the owner's Signal account, so it stops
/// appearing under Linked Devices on their phone. It needs the network.
///
/// **Delete the local data** removes the long-term keys from this Mac, which is
/// what actually makes `SignalTooling.linkedNumber()` go nil and the settings
/// row read "Not set" again.
///
/// The second must happen even when the first cannot, or a Mac that is offline
/// can never be unlinked. But it must then *say so*, because a device left on
/// the account is one the owner has to remove from their phone themselves — and
/// a stale "Mynah" in that list, silently left behind, is exactly the kind of
/// thing somebody discovers a year later and cannot explain.
///
/// ## Why `unregister` is safe here and would not be everywhere
///
/// signal-cli's own help says it "unregisters the **current** device". On a
/// primary account that would deregister the owner's number from Signal
/// entirely, which is not a mistake anybody recovers from casually. It is safe
/// in this app because Mynah is only ever a *linked* device: setup runs
/// `signal-cli link`, never `register`, so the account on this Mac is always
/// secondary and "the current device" is only ever this Mac.
///
/// `--delete-account` is never passed. That flag deletes the number from
/// Signal's servers, and nothing in an appliance's settings screen should be one
/// argument away from it.
struct SignalUnlink: Sendable {

    /// Generous. `unregister` is a network round trip on whatever connection the
    /// owner has, and the cost of being impatient is a device left on their
    /// account.
    static let unregisterTimeout: TimeInterval = 45

    /// Local file deletion. Slow only if the disk is in trouble.
    static let deleteTimeout: TimeInterval = 20

    let helper: URL
    let runner: any ProbeCommandRunning

    init(helper: URL, runner: any ProbeCommandRunning = ProbeCommandRunner()) {
        self.helper = helper
        self.runner = runner
    }

    /// What actually happened, in the two parts the owner might need to act on.
    struct Outcome: Sendable, Equatable {
        /// The device is off the owner's Signal account.
        var removedFromAccount: Bool
        /// The keys are gone from this Mac, which is what "Not set" means.
        var localDataDeleted: Bool

        /// What to tell the owner, or nil when it went cleanly.
        ///
        /// Every branch names the next action. A message that reports a failure
        /// and stops leaves somebody staring at a screen with nothing to press.
        var note: String? {
            switch (removedFromAccount, localDataDeleted) {
            case (true, true):
                return nil
            case (false, true):
                return "This Mac is unlinked and ready for a different phone. It may still be "
                    + "listed on your phone under Signal → Settings → Linked Devices — remove "
                    + "\"Mynah\" there when you get a moment."
            case (true, false), (false, false):
                return "Mynah could not remove the Signal account from this Mac, so it is still "
                    + "linked. Try once more, and if it keeps failing, turn answering off and "
                    + "reopen Mynah before trying again."
            }
        }

        /// Whether the owner can now link a different phone.
        var canRelink: Bool { localDataDeleted }
    }

    /// - Parameter account: the number as signal-cli knows it, unredacted. This
    ///   is the one place the full number is needed rather than displayed.
    func run(account: String) async -> Outcome {
        let unregistered = await succeeded(
            arguments: ["-a", account, "unregister"],
            timeout: Self.unregisterTimeout
        )

        // `--ignore-registered` only when the server step did not happen. Passing
        // it always would delete a linked Mac's keys while leaving the device on
        // the account every time, which is the messy outcome this orders itself
        // to avoid.
        var arguments = ["-a", account, "deleteLocalAccountData"]
        if !unregistered { arguments.append("--ignore-registered") }
        let deleted = await succeeded(arguments: arguments, timeout: Self.deleteTimeout)

        return Outcome(removedFromAccount: unregistered, localDataDeleted: deleted)
    }

    /// A launched process that exits non-zero is a failure; one that could not be
    /// launched at all is also a failure. Neither is an exception — an appliance
    /// that throws out of a settings button teaches the owner the button is
    /// dangerous.
    private func succeeded(arguments: [String], timeout: TimeInterval) async -> Bool {
        guard let result = await runner.run(executable: helper, arguments: arguments, timeout: timeout) else {
            return false
        }
        return !result.timedOut && result.exitCode == 0
    }
}
