import Foundation
import SageVoiceCore

/// Writes a long download's progress to the log at deciles.
///
/// `URLSession` reports progress per chunk, which across 353 MB is thousands of
/// callbacks. Logging each one would bury every other line in `mynah.log` — the
/// file somebody reads precisely when something has gone wrong — under a
/// progress bar rendered as text.
///
/// Ten lines is the amount that answers the only question the log is asked about
/// a background download: is it moving, and how far did it get before it
/// stopped. A transfer that died at 30% says so; one that never started leaves
/// no milestone at all.
final class DownloadMilestones: @unchecked Sendable {

    private let log: MynahLog
    private let lock = NSLock()
    private var reported = -1

    init(category: String) {
        self.log = MynahLog(category: category)
    }

    func info(_ message: String) {
        log.info(message)
        // A finished or failed download resets the ledger, so a later retry
        // reports its own progress instead of being silenced by the first
        // attempt's high-water mark.
        lock.lock()
        reported = -1
        lock.unlock()
    }

    /// Logs the first time each tenth is crossed. 100% is deliberately not one
    /// of them — the outcome line that follows says more than a percentage, and
    /// two lines meaning "done" is one too many.
    func milestone(_ fraction: Double) {
        let decile = Int(fraction * 10)
        guard decile > 0, decile < 10 else { return }

        lock.lock()
        let crossed = decile > reported
        if crossed { reported = decile }
        lock.unlock()

        guard crossed else { return }
        log.info("voice: downloading the voice model, \(decile * 10)%")
    }
}
