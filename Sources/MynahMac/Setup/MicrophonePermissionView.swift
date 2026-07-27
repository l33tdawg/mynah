import AVFoundation
import AppKit
import Combine
import Observation
import OSLog
import SwiftUI

// MARK: - Dormant on purpose — read before wiring this in
//
// Nothing in this file is reachable from the shipping app, and that is the
// deliberate resolution of a real contradiction between two screens rather than
// an oversight in the wiring.
//
// Verified across the whole product: the only `AVCaptureDevice` calls anywhere
// are the two in this file. `ConversationModel.shared` is built with `voice:
// nil`, so `canHoldToTalk` is false and the hold-to-talk control never renders;
// `SageVoiceCore` contains no recorder at all. The owner speaks into their
// *phone*, and the voice note arrives over Signal already recorded. Settings
// tells them so in as many words — "Mynah never listens through this Mac's
// microphone" (`Main/SettingsView.swift`).
//
// Putting this stage in the onboarding flow today would therefore demand a
// microphone permission from a non-technical owner for a capability that does
// not exist, and would make that Settings sentence a lie. On a product whose
// entire pitch is where your words go, that is the most expensive thing the app
// could do.
//
// TO LIGHT IT UP, in this order: implement `VoiceCapture` (declared in
// `Main/ConversationModel.swift`) over `MicrophoneAccess` below plus a recorder
// and a `SageVoiceCore` transcriber; pass it as `ConversationModel(voice:)`;
// present this view from Talk the first time the owner reaches for the
// hold-to-talk control; and change the Settings copy in the same commit. It
// takes an optional `Rail`, so it works as a sheet or a stage without changing.
// It is compiled and previewed on every build so it cannot rot while it waits.

// MARK: - Access

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

    private static let log = Logger(subsystem: "local.sage.voicebridge", category: "microphone")

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

// MARK: - Screen

/// Asking for the microphone, and rescuing the owner when the answer was no.
///
/// The explanation comes *before* the system prompt, never after: macOS's box is
/// four words and a Deny button, and an owner who has not been told why is
/// looking at a dialog from an app they installed ten seconds ago. By the time
/// they read the reason it is too late — the prompt is spent.
struct MicrophonePermissionView: View {

    /// The fixed onboarding rail, when this screen is part of the flow.
    ///
    /// Absent when it is a sheet or opened from Settings. A progress rail on a
    /// screen that is not one of the steps tells the owner they are somewhere
    /// they are not.
    struct Rail: Equatable, Sendable {
        let titles: [String]
        let index: Int

        init(titles: [String], index: Int) {
            self.titles = titles
            self.index = index
        }
    }

    var rail: Rail?
    /// Owned by the caller — usually `@State` — so leaving and returning to this
    /// screen does not forget that the owner has already been to System Settings.
    var access: MicrophoneAccess
    var onContinue: () -> Void
    var onBack: (() -> Void)?
    /// When present, the escape hatch is "Not now" and the caller records the
    /// skipped step somewhere the owner can find it again. When absent the
    /// escape hatch becomes "Continue without it" and moves the flow on itself.
    /// Either way there is a way out — a screen that can only be left by
    /// granting a permission macOS may have already refused is a trap.
    var onSkip: (() -> Void)?

    init(
        rail: Rail? = nil,
        access: MicrophoneAccess,
        onContinue: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        onSkip: (() -> Void)? = nil
    ) {
        self.rail = rail
        self.access = access
        self.onContinue = onContinue
        self.onBack = onBack
        self.onSkip = onSkip
    }

    var body: some View {
        Group {
            if let rail {
                StageShell(
                    stageTitles: rail.titles,
                    currentIndex: rail.index,
                    glyph: glyph,
                    title: title,
                    subtitle: subtitle
                ) {
                    content
                } actions: {
                    actions
                }
            } else {
                panel
            }
        }
        .mynahAnimation(Motion.snap, value: access.status)
        .onAppear { access.refresh() }
        // Changing the switch in System Settings does not notify the app, so the
        // moment MYNAH comes back to the front is the only signal there is that
        // the owner may have just fixed it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh()
        }
    }

    // MARK: Sheet layout

    /// The same column as a stage, without the rail and with a sheet's title
    /// size. `.display` is one-per-onboarding-stage; a sheet that borrowed it
    /// would claim to be a step in a flow it is not part of.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeroGlyph(glyph)
            Spacer().frame(height: s7)
            Text(title)
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: s4)
            Text(subtitle)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)
                .mynahProse()
            Spacer().frame(height: s8)
            content
            Spacer().frame(height: s8)
            actions
        }
        .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)
        .padding(.horizontal, s8)
        .padding(.vertical, s8)
        .frame(maxWidth: .infinity)
        .background(Palette.surface.canvas)
    }

    // MARK: Copy

    /// One glyph for every state including the refusals.
    ///
    /// Not `mic.slash` when access is denied: a switch the owner can flip in ten
    /// seconds should not be drawn as a fault. The words carry the state.
    private var glyph: String {
        access.status == .granted ? "checkmark" : "mic"
    }

    private var title: String {
        switch access.status {
        case .notAsked, .asking:
            return "Mynah needs the microphone."
        case .granted:
            return "Mynah can hear you."
        case .denied:
            return "macOS is holding the microphone back."
        case .restricted:
            return "The microphone is switched off on this Mac."
        case .cannotAsk:
            return "Mynah can't ask for the microphone."
        }
    }

    private var subtitle: String {
        switch access.status {
        case .notAsked, .asking:
            return "So you can talk to Mynah here at the Mac, the same way you do from your phone."
        case .granted:
            return "Talk to it here or send it a voice note — either works now."
        case .denied:
            return "macOS only asks once, and that answer was no. You can turn it back on "
                + "yourself, and it takes about ten seconds."
        case .restricted:
            return "Something else decides this — Screen Time, or a profile from whoever set "
                + "this Mac up. Mynah can't change it, and neither can you from here."
        case .cannotAsk:
            return "You can still turn it on by hand, and everything else works either way."
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch access.status {
        case .notAsked:
            MynahCard(density: .hero) {
                VStack(alignment: .leading, spacing: s4) {
                    Text("It listens only while you're talking to it, never in the background, "
                        + "and what it hears becomes words on this Mac.")
                        .mynahFont(.body)
                        .foregroundStyle(Palette.ink.secondary)
                        .mynahProse()
                    Text("macOS asks next. That box comes from macOS, not from Mynah, and it "
                        + "only appears once.")
                        .mynahFont(.body)
                        .foregroundStyle(Palette.ink.secondary)
                        .mynahProse()
                }
            }
            .frame(maxWidth: MynahWidth.stageColumn)

        case .asking:
            HStack(spacing: s4) {
                ThinkingIndicator()
                Text("Waiting for your answer to the box macOS just put up.")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
            }
            .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)

        case .granted:
            MynahCard(density: .hero) {
                StatusLine("Microphone", value: "On", tone: .good)
            }
            .frame(maxWidth: MynahWidth.stageColumn)

        case .denied, .cannotAsk:
            VStack(alignment: .leading, spacing: s4) {
                MynahCard {
                    NumberedStepList(steps: Self.settingsSteps)
                }
                if access.hasOpenedSettings {
                    InlineBanner(
                        tone: .caution,
                        headline: "Turned it on and Mynah still can't hear?",
                        explanation: "macOS only hands the microphone to an app the next time it "
                            + "starts. Quit Mynah, open it again, and it will be listening."
                    )
                }
            }
            .frame(maxWidth: MynahWidth.stageColumn)

        case .restricted:
            MynahCard(density: .hero) {
                Text("Ask whoever set this Mac up to allow Mynah. Until then you can still send "
                    + "it voice notes from your phone — that doesn't use this Mac's microphone "
                    + "at all.")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
                    .mynahProse()
            }
            .frame(maxWidth: MynahWidth.stageColumn)
        }
    }

    private static let settingsSteps = [
        "Open Privacy & Security in System Settings.",
        "Click Microphone.",
        "Turn on Mynah."
    ]

    // MARK: Actions

    private var actions: some View {
        ActionRow(quietTitle: escape?.title, quietAction: escape?.action) {
            HStack(spacing: s4) {
                if let secondary {
                    MynahButton(secondary.title, kind: .secondary, action: secondary.action)
                }
                MynahButton(primaryTitle, isEnabled: primaryIsEnabled, action: primaryAction)
            }
        }
    }

    /// One secondary, never two.
    ///
    /// "Check again" outranks "Back" where both apply: the owner in that state
    /// has just walked to System Settings and come back, and the thing they want
    /// is proof it took. Three controls crowded against the primary is how an
    /// action row stops reading as a decision and starts reading as a toolbar.
    private var secondary: (title: String, action: () -> Void)? {
        // Offered only where the owner has somewhere to have been. Elsewhere it
        // would re-read a value nothing has touched.
        if access.status == .denied || access.status == .cannotAsk {
            return ("Check again", { access.refresh() })
        }
        if let onBack { return ("Back", onBack) }
        return nil
    }

    private var primaryTitle: String {
        switch access.status {
        case .notAsked, .asking: return "Ask for the microphone"
        case .granted: return "Continue"
        case .denied, .cannotAsk: return "Open Privacy & Security"
        case .restricted: return "Carry on without it"
        }
    }

    private var primaryIsEnabled: Bool {
        access.status != .asking
    }

    private func primaryAction() {
        switch access.status {
        case .notAsked:
            Task { await access.request() }
        case .asking:
            break
        case .granted, .restricted:
            onContinue()
        case .denied, .cannotAsk:
            access.openPrivacySettings()
        }
    }

    /// The way out, and it is never absent while the microphone is unresolved.
    private var escape: (title: String, action: () -> Void)? {
        switch access.status {
        // Nothing left to postpone, and nothing to escape from.
        case .granted, .restricted:
            return nil
        case .notAsked, .asking, .denied, .cannotAsk:
            if let onSkip { return ("Not now", onSkip) }
            return ("Continue without it", onContinue)
        }
    }
}

// MARK: - Previews

#Preview("Microphone — before asking") {
    MicrophonePreview(status: .notAsked)
}

#Preview("Microphone — asking") {
    MicrophonePreview(status: .asking)
}

#Preview("Microphone — granted") {
    MicrophonePreview(status: .granted)
}

#Preview("Microphone — denied") {
    MicrophonePreview(status: .denied)
}

#Preview("Microphone — denied, been to Settings") {
    MicrophonePreview(status: .denied, hasOpenedSettings: true)
}

#Preview("Microphone — managed Mac") {
    MicrophonePreview(status: .restricted)
}

#Preview("Microphone — can't ask") {
    MicrophonePreview(status: .cannotAsk)
}

#Preview("Microphone — as a stage") {
    MicrophonePreview(
        status: .notAsked,
        rail: MicrophonePermissionView.Rail(
            titles: SetupModel.Stage.allCases.map(\.title),
            index: SetupModel.Stage.ready.rawValue
        )
    )
}

#Preview("Microphone — no way to defer") {
    MicrophonePreview(status: .denied, offersSkip: false)
}

private struct MicrophonePreview: View {
    let status: MicrophoneAccess.Status
    var hasOpenedSettings = false
    var rail: MicrophonePermissionView.Rail?
    var offersSkip = true

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
        .frame(width: 1300, height: 760)
    }

    private var pane: some View {
        // Pinned, so opening a preview never reads this machine's real
        // authorisation, never shows a system prompt, and never launches System
        // Settings on the developer's Mac.
        MicrophonePermissionView(
            rail: rail,
            access: MicrophoneAccess(pinned: status, hasOpenedSettings: hasOpenedSettings),
            onContinue: {},
            onBack: rail == nil ? nil : {},
            onSkip: offersSkip ? {} : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.canvas)
    }
}
