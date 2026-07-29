import AVFoundation
import AppKit
import Observation
import OSLog
import SageVoiceCore

// MARK: - Microphone permission
//
// Lifted out of `Setup/MicrophonePermissionView.swift` when that file was
// deleted, and the split is the point.
//
// It held two things: this type, which is live and is what
// `MicrophoneVoiceCapture` asks before it opens the microphone, and a complete
// setup *screen* nothing had ever presented. Deleting the screen was right —
// the microphone is asked for the first time the owner presses record, where
// the system prompt arrives with obvious context, and a fifth setup stage for
// an optional feature is precisely what came off the gate when phone linking
// did. Deleting the type along with it was not: it took the build with it,
// because one file held one dead thing and one live one.

/// Everything MYNAH knows about whether it may use the microphone.
///
/// A type rather than three `@State` booleans in the view, because the rules
/// macOS enforces here are unforgiving and every one of them has to be honoured
/// in one place:
///
/// * **The prompt appears once, ever.** After a refusal `requestAccess` returns
///   `false` immediately with nothing on screen. A screen whose only button
///   re-asks therefore leaves a non-technical owner clicking something that
///   cannot ever work, with no way to discover that System Settings is the only
///   route left. That is the trap this screen exists to get them out of.
/// * **Asking without a reason string kills the process.** TCC aborts an app
///   that calls `requestAccess` with no `NSMicrophoneUsageDescription` in its
///   bundle — not an error, a crash. A binary run outside an app bundle has no
///   Info.dictionary at all, so the check below is what stops a debug run from
///   dying the moment someone opens this screen.
/// * **Granting it in System Settings does not reach a running app.** macOS
///   hands the microphone over on the next launch, which is why the denied
///   screen says so out loud instead of leaving the owner to conclude that
///   turning the switch on did nothing.
@MainActor
@Observable
final class MicrophoneAccess {

    enum Status: Equatable, Sendable {
        /// macOS has never asked. The one state where asking is possible.
        case notAsked
        /// The system prompt is on screen.
        case asking
        case granted
        case denied
        /// Switched off by a profile or Screen Time. System Settings will not
        /// help, so the screen must not send the owner there.
        case restricted
        /// MYNAH cannot ask on this Mac, because asking would end the process.
        case cannotAsk
    }

    private(set) var status: Status

    /// Whether the owner has been sent to System Settings during this visit.
    /// Gates the "you may have to open Mynah again" note — showing it before
    /// they have been anywhere is noise, showing it after is the answer to the
    /// question they are about to ask.
    private(set) var hasOpenedSettings = false

    /// Previews and tests pin a state. Nothing in the app uses this.
    private let isPinned: Bool

    private static let log = MynahLog(category: "microphone")

    /// Straight to the Microphone list, not to the top of Privacy & Security.
    /// Every extra step is somewhere to get lost, and the owner is being sent
    /// out of the app precisely because they are already stuck.
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!

    init() {
        isPinned = false
        status = Self.systemStatus()
    }

    init(pinned status: Status, hasOpenedSettings: Bool = false) {
        isPinned = true
        self.status = status
        self.hasOpenedSettings = hasOpenedSettings
    }

    private static func systemStatus() -> Status {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            log.notice("no microphone usage description in this bundle; not asking")
            return .cannotAsk
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notAsked
        @unknown default: return .denied
        }
    }

    /// Re-reads what macOS thinks, after the owner has been away changing it.
    func refresh() {
        guard !isPinned, status != .asking else { return }
        // `.asking` is excluded because the framework still reports
        // `notDetermined` while its own prompt is up — refreshing then would
        // throw the screen back to its opening state under the owner's cursor.
        status = Self.systemStatus()
    }

    /// Shows the system prompt, once, and only when one would actually appear.
    func request() async {
        guard !isPinned, status == .notAsked else { return }
        status = .asking
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        status = granted ? .granted : .denied
    }

    func openPrivacySettings() {
        hasOpenedSettings = true
        NSWorkspace.shared.open(Self.privacySettingsURL)
    }
}
