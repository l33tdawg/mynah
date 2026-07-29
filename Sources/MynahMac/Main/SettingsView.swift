import AppKit
import Observation
import OSLog
import SageVoiceCore
import SwiftUI

// MARK: - What the owner chose

/// The brain the owner picked, kept so the app can still answer "where do my
/// words go?" after a restart.
///
/// Setup holds the choice in `SetupModel` for the length of the flow and then
/// drops it; only the API key is written to disk. That is enough to *run* but
/// not enough to *report*, and a settings screen that cannot name where the
/// owner's speech goes is worse than no settings screen.
struct BrainChoice: Codable, Equatable, Sendable {
    var optionID: String
    var label: String
    var backendIdentifier: String
    var modelName: String?
    var keepsWordsOnDevice: Bool

    init(_ option: BrainSetupOption) {
        self.optionID = option.id.rawValue
        self.label = option.label
        self.backendIdentifier = option.backendIdentifier
        self.modelName = option.modelName
        self.keepsWordsOnDevice = option.keepsWordsOnDevice
    }

    /// Where the owner's words end up, in a name they would recognise.
    var destination: String {
        if keepsWordsOnDevice { return "This Mac" }
        return MynahCopy.company(forBackend: backendIdentifier) ?? "A company"
    }

    /// The provider a pasted key belongs to. Goes through the option's own seam
    /// rather than the backend string, which is what made "Google" resolve to
    /// nothing and hid the key rows entirely.
    var keyProvider: String? {
        BrainSetupOptionID(rawValue: optionID)?.keyProviderIdentifier
    }

    var needsAKey: Bool {
        guard let keyProvider else { return false }
        return APIKeyOnboarding.instructions(forProvider: keyProvider) != nil
    }
}

/// Reading `BrainChoice` back out of where the app already keeps the decision.
///
/// This used to be a second store with its own defaults key, written only by
/// this screen's previews — so the owner could finish setup and still be told
/// their brain "wasn't recorded", because the two halves of the app were writing
/// and reading different keys. There is now exactly one record of what the owner
/// picked, `BrainSelectionStore`, written once when they press "Start using
/// Mynah"; this is a read-through projection of it for display.
///
/// `UserDefaults` rather than the 0600 key file, in both cases: this records
/// *which* brain, which is a preference, not a credential. The credential stays
/// in `KeyStorage` where it is already protected.
enum BrainChoiceStore {

    static func record(_ option: BrainSetupOption, defaults: UserDefaults = .standard) {
        BrainSelectionStore.save(option, defaults: defaults)
    }

    static func current(defaults: UserDefaults = .standard) -> BrainChoice? {
        BrainSelectionStore.current(defaults).map(BrainChoice.init)
    }

    static func clear(defaults: UserDefaults = .standard) {
        BrainSelectionStore.clear(defaults)
    }
}

// MARK: - The phone seam

/// What Mynah knows about the phone it answers.
struct PhoneStatus: Sendable, Equatable {
    /// Whether the messaging bridge this Mac uses is present. Not whether a
    /// message has ever arrived — that is a different, and slower, question.
    var isReachable: Bool
    /// Redacted for display. The full number is never rendered.
    var linkedNumber: String?
    /// For the diagnostics report, never for the owner.
    var socketPath: String

    static let unknown = PhoneStatus(isReachable: false, linkedNumber: nil, socketPath: "")
}

/// How the app reads, and one day changes, which phone Mynah answers.
///
/// A protocol because the second half does not exist yet. Nothing in
/// `SageVoiceCore` can *unlink* a phone: the allowlist is read once from the
/// environment at daemon start (`SignalSenderAllowlist.fromEnvironment`) and
/// there is no writer. So `canUnlink` is `false` today and the settings screen
/// renders no button — an "Unlink" that quietly does nothing is the single
/// worst thing in the app this one is replacing.
protocol PhoneLinking: Sendable {
    var status: PhoneStatus { get }
    var canUnlink: Bool { get }
    func unlink() async throws
}

/// Reads the real state of the messaging bridge on this Mac.
struct SignalPhoneLink: PhoneLinking {

    enum Failure: Error { case notSupportedYet }

    var homeDirectory: String = NSHomeDirectory()
    var environment: [String: String] = ProcessInfo.processInfo.environment

    var status: PhoneStatus {
        let path = socketPath
        return PhoneStatus(
            isReachable: FileManager.default.fileExists(atPath: path),
            linkedNumber: redactedNumber,
            socketPath: path
        )
    }

    /// Nothing writes the allowlist, so nothing can un-write it.
    var canUnlink: Bool { false }

    func unlink() async throws {
        throw Failure.notSupportedYet
    }

    private var socketPath: String {
        switch SignalEndpoint.defaultUnixSocket(homeDirectory: homeDirectory) {
        case .unixSocket(let path): return path
        case .tcp(let host, let port): return "\(host):\(port)"
        }
    }

    private var redactedNumber: String? {
        if let linked = SignalTooling.linkedNumber() {
            return SignalSenderAllowlist.redact(linked)
        }
        guard let allowlist = try? SignalSenderAllowlist.fromEnvironment(environment: environment) else {
            return nil
        }
        let names = allowlist.identities
            .map { SignalSenderAllowlist.redact($0.description) }
            .sorted()
        return names.first
    }
}

// MARK: - How Mynah hears and speaks

/// The speech half of the appliance, as facts rather than settings.
///
// MARK: - Claims about where the owner's words go

/// The sentences in Settings that are promises rather than descriptions.
///
/// Named constants because they are **privacy claims**, and a privacy claim
/// should not be an anonymous literal inside a view body. Two reasons, and the
/// second one is why this type exists at all:
///
/// 1. A test can assert on the value. The alternative — reading this file off
///    disk and grepping it — cannot tell a claim from a comment *about* a
///    claim, so it fails on the honesty of the note recording what changed and
///    the only ways to make it pass are deleting that note or paraphrasing it
///    until the grep misses. Both make the codebase quieter about its own
///    history to satisfy a test.
/// 2. It puts every such promise in one place, where somebody adding a feature
///    can find the sentences their feature might have just falsified.
///
/// That is not hypothetical. `microphone` below used to read *"Your phone.
/// Mynah never listens through this Mac's microphone — it only hears the voice
/// notes you send it."* Shipping hold-to-talk made it false, and on a product
/// whose whole argument is where your words go, a Settings sentence one release
/// out of date is the most expensive thing this app can say.
enum PrivacyClaim {

    /// Deliberately not "never".
    ///
    /// "Never" was the wrong promise even before it became untrue — it is a
    /// claim about capability, and what an owner actually needs is a claim
    /// about *control*: nothing opens the microphone except them, holding a
    /// button. That survives the feature instead of being contradicted by it.
    static let microphone = "Your phone, or this Mac. Mynah opens the microphone only while "
        + "you hold the record button in the composer — never on its own, and there is no "
        + "wake word. Speech is turned into words on this Mac either way."

    /// What the update check tells a third party.
    static let updateCheckReach = "The update check asks GitHub once a day whether a newer "
        + "version has been released. That request tells GitHub a Mac asked, which is a third "
        + "party learning this machine exists — the one thing Mynah does that you did not ask "
        + "for by speaking. Turn it off and Mynah never contacts GitHub at all."

    /// **Restored after it was lost in a density pass, which is why it is here
    /// rather than inline.**
    ///
    /// The old privacy row ended "Nothing is downloaded or installed on its
    /// own." The rearrangement kept the outbound half — what GitHub learns —
    /// and dropped the inbound one, so on a section headed "what leaves this
    /// Mac" the question an owner actually has about an update check no longer
    /// had an answer. Everything left was true; the reassurance was simply
    /// gone, which is the most expensive shape a copy edit can take.
    static let updateCheckNoAutoInstall = "Nothing is downloaded or installed on its own — a "
        + "newer version is something you go and get."

    /// The About caption, composed rather than written out.
    ///
    /// This is the enrolment half of the guarantee, and it is the half that was
    /// missing. Asserting that every member of this type is rendered protects
    /// only what somebody remembered to put in it, and the sentence most likely
    /// to be dropped is the one nobody thought to enrol. Composing the caption
    /// *from* the members inverts that: a claim cannot be quietly deleted from
    /// the screen without deleting it from here, where a test can see it.
    static var aboutCaption: String { "\(updateCheckReach) \(updateCheckNoAutoInstall)" }
}

/// There is deliberately no microphone picker here, and the reason changed
/// with hold-to-talk. It used to be that nothing in this product recorded from
/// the Mac at all. `MicrophoneVoiceCapture` now does, while the owner holds the
/// composer's record button — so the honest reason is no longer "that does not
/// happen" but "macOS already owns that choice". Input device selection lives
/// in System Settings, and a second picker here would be a second answer to one
/// question, which is how the two pause stores happened.
struct SpeechFacts: Sendable, Equatable {
    var transcriberPath: String?
    var modelPath: String?

    var isReady: Bool { transcriberPath != nil && modelPath != nil }

    /// "Large (turbo)" from `ggml-large-v3-turbo-q5_0.bin`. The filename itself
    /// belongs in the diagnostics report, not on a settings row.
    var modelName: String? {
        guard let modelPath else { return nil }
        let file = (modelPath as NSString).lastPathComponent.lowercased()
        let size: String
        switch true {
        case file.contains("large"): size = "Large"
        case file.contains("medium"): size = "Medium"
        case file.contains("small"): size = "Small"
        case file.contains("base"): size = "Base"
        case file.contains("tiny"): size = "Tiny"
        default: return (modelPath as NSString).deletingPathExtension.components(separatedBy: "/").last
        }
        return file.contains("turbo") ? "\(size) (turbo)" : size
    }

    static func detect() -> SpeechFacts {
        if let executable = WhisperKitServerBundleLocator.bundledExecutable(),
           let model = WhisperKitModelLocator.localModelPath(
                named: "openai_whisper-large-v3-v20240930_626MB"
           ) {
            return SpeechFacts(
                transcriberPath: executable.path,
                modelPath: model.path
            )
        }
        let discovery = LocalASRDiscovery()
        return SpeechFacts(
            transcriberPath: discovery.firstExecutable()?.path,
            modelPath: discovery.firstModel()?.path
        )
    }
}

// MARK: - Model

/// Everything the settings screen has to go and find out.
///
/// The environment probe is slow enough to notice (it shells out and talks to a
/// local daemon), so it runs once behind the screen and only the Advanced
/// disclosure is gated on it. Nothing above the fold waits.
@MainActor
@Observable
final class SettingsModel {

    /// The result of re-checking a stored key, in the validator's own words.
    enum CheckState: Equatable {
        case idle
        case checking
        case good(String)
        case bad(String)
    }

    private let log = MynahLog(category: "settings")
    private let defaults: UserDefaults
    private let phoneLink: any PhoneLinking
    private let calls: CallSettingsStore
    private let callPreview = CallVoicePreview()

    private(set) var probe: EnvironmentProbeResult?
    private(set) var isProbing = false
    private(set) var brain: BrainChoice?

    /// What the appliance last reported it was running.
    ///
    /// Read fresh rather than cached: the owner may have restarted the daemon
    /// onto a different provider since this screen opened, and a stale answer to
    /// "where do my words go" is the failure this exists to fix.
    var appliance: ApplianceStatus? { ApplianceStatus.current() }

    private(set) var speech: SpeechFacts
    private(set) var phone: PhoneStatus
    private(set) var checkState: CheckState = .idle

    // MARK: Calls
    //
    // Mirrored out of `CallSettingsStore` rather than read through it on every
    // draw, because `@Observable` cannot see into `UserDefaults` and a row bound
    // straight to the store would not redraw when the owner changed it.

    private(set) var callVoices: CallVoiceCatalogue = .checking
    private(set) var callVoice: String
    private(set) var callSpeed: Double
    private(set) var sendsCallTranscript: Bool
    private(set) var isPlayingCallVoice = false
    /// One sentence for the owner when a preview will not play. The reason goes
    /// to the log; the synthesizer's own wording names ports and Python scripts.
    private(set) var callVoiceProblem: String?

    // MARK: Updates
    //
    // Mirrored out of the preferences file for the same reason the call
    // settings are: `@Observable` cannot see a file being written, so a row
    // bound straight through the store would not redraw when the owner set it.

    /// What the last check found. `nil` while the first one is still running,
    /// which is the only state that means "asking".
    private(set) var update: UpdateAvailability?
    private(set) var checksForUpdates: Bool

    /// What launchd says about the background helper, or `nil` before the first
    /// answer. Read rather than mirrored from the switch — see
    /// `backgroundHelperRow` for why those are not the same question.
    private(set) var helperState: BackgroundHelperState?
    private let backgroundServices: any SignalBackgroundServicing

    func refreshHelperState() async {
        helperState = await backgroundServices.state()
    }
    private let updatePreferences: URL

    init(
        defaults: UserDefaults = .standard,
        callPreferences: URL = CallPreferences.defaultFileURL(),
        updatePreferences: URL = UpdatePreferences.defaultFileURL(),
        phoneLink: any PhoneLinking = SignalPhoneLink(),
        backgroundServices: any SignalBackgroundServicing = SignalBackgroundServiceManager.shared
    ) {
        self.backgroundServices = backgroundServices
        // Call settings are a file rather than defaults, because the daemon has
        // to read them and it does not share this process's defaults domain.
        let calls = CallSettingsStore(fileURL: callPreferences)
        self.defaults = defaults
        self.phoneLink = phoneLink
        self.calls = calls
        self.brain = BrainChoiceStore.current(defaults: defaults)
        self.speech = SpeechFacts.detect()
        self.phone = phoneLink.status
        self.callVoice = calls.voice
        self.callSpeed = calls.speed
        self.sendsCallTranscript = calls.sendsTranscript
        self.updatePreferences = updatePreferences
        self.checksForUpdates = UpdatePreferences.load(from: updatePreferences).checksForUpdates
    }

    var canUnlinkPhone: Bool { phoneLink.canUnlink }

    /// The option behind `brain`, read from this model's own defaults.
    ///
    /// Not a computed property on `BrainChoice`: that type has no idea which
    /// suite it came from, and a preview's throwaway defaults would silently
    /// answer with the real Mac's stored choice.
    var brainOption: BrainSetupOption? {
        BrainSelectionStore.current(defaults)
    }

    /// Providers with a key stored on this Mac. Real, persisted fact — shown
    /// when the brain choice itself was never recorded, so the screen still has
    /// something true to say.
    var providersWithKeys: [String] {
        KeyStorage.load().keys.sorted()
    }

    func refresh() {
        brain = BrainChoiceStore.current(defaults: defaults)
        speech = SpeechFacts.detect()
        phone = phoneLink.status
    }

    func probeIfNeeded() async {
        guard probe == nil, !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
        probe = await EnvironmentProbe().run()
    }

    // MARK: Calls

    /// Asks the speech bridge again every time the screen appears.
    ///
    /// Not cached like the environment probe: an owner told "the natural voice
    /// isn't installed" will go and start it, and the first thing they do next is
    /// come back here. The previous answer stays on screen while this runs, so
    /// re-asking never flickers the row back to "looking".
    func loadCallVoices() async {
        let found = await KokoroVoices.load()
        callVoices = found
        guard case .installed(let names) = found, !names.contains(callVoice) else { return }
        // The stored voice is no longer served — a changed voice pack, or a
        // different bridge. Left alone it would leave the picker showing nothing
        // selected, which reports no preference at all. Falling back to the name
        // the daemon itself falls back to keeps the row and the call agreeing.
        setCallVoice(names.contains(KokoroHTTPSynthesizer.defaultKokoroVoice)
            ? KokoroHTTPSynthesizer.defaultKokoroVoice
            : names[0])
    }

    func setCallVoice(_ name: String) {
        callVoice = name
        calls.voice = name
        callVoiceProblem = nil
    }

    /// How fast it talks on a call.
    ///
    /// Clamped here as well as on read. A slider cannot produce a value outside
    /// its range today, but the preference is a file the owner can edit and the
    /// consequence of an absurd rate is a voice they cannot understand.
    func setCallSpeed(_ rate: Double) {
        let clamped = min(max(rate, CallPreferences.slowest), CallPreferences.fastest)
        callSpeed = clamped
        calls.speed = clamped
    }

    func setSendsCallTranscript(_ isOn: Bool) {
        sendsCallTranscript = isOn
        calls.sendsTranscript = isOn
    }

    func playCallVoice() async {
        guard !isPlayingCallVoice else { return }
        isPlayingCallVoice = true
        callVoiceProblem = nil
        defer { isPlayingCallVoice = false }
        do {
            try await callPreview.play(voice: callVoice, speed: callSpeed)
        } catch {
            log.error("voice preview failed: \(String(describing: error))")
            // Deliberately claims nothing about whether the voice would work on
            // a real call. A failed preview usually means the bridge went away,
            // in which case the call would fall back to the built-in voice too —
            // and reassuring the owner otherwise would be a guess.
            callVoiceProblem = "Mynah couldn't play that voice just now."
        }
    }

    // MARK: A newer Mynah

    /// Asks GitHub whether a newer version has been released.
    ///
    /// Nothing on this screen waits for this. The row draws as "asking" and is
    /// replaced when an answer arrives, or is not. Whether today's request has
    /// already been made is `UpdateCheck`'s decision, not this screen's — the
    /// same limit has to hold however many places end up calling it.
    func checkForUpdate() async {
        update = await UpdateCheck(preferencesFile: updatePreferences).run()
    }

    /// Turning the check off stops the requests, not merely the reporting.
    ///
    /// Turning it back on clears the day's timestamp on purpose: an owner who
    /// has just switched this on is asking to be told now, and being met with
    /// "hasn't managed to check yet" until tomorrow reads as a control that did
    /// nothing.
    func setChecksForUpdates(_ isOn: Bool) {
        checksForUpdates = isOn
        UpdatePreferences.amend(at: updatePreferences) { preferences in
            preferences.checksForUpdates = isOn
            if isOn { preferences.lastCheckedAt = nil }
        }
        update = nil
        Task { await checkForUpdate() }
    }

    // MARK: Re-checking the key

    /// Does what a real turn does, rather than asking the provider whether the
    /// key exists. `BrainKeyValidator` was written because the cheap check
    /// passed on a key every actual turn then failed with.
    func recheckKey() async {
        guard let brain else { return }
        checkState = .checking

        let result = await EnvironmentProbe().run()
        probe = result

        guard let optionID = BrainSetupOptionID(rawValue: brain.optionID),
              let option = BrainSetupPlanner().plan(for: result).option(withID: optionID) else {
            checkState = .bad("Mynah can't find that brain on this Mac any more. Set it up again.")
            return
        }
        guard option.isAvailable else {
            checkState = .bad(option.availability.reason
                ?? "Mynah can't use that brain on this Mac right now. Set it up again.")
            return
        }

        do {
            let backend = try BrainFactory.makeBackend(
                for: option,
                apiKey: option.keyProviderIdentifier.flatMap(KeyStorage.key(forProvider:))
            )
            let verdict = await BrainKeyValidator().validate(backend)
            checkState = verdict.isUsable
                ? .good(verdict.spokenDescription)
                : .bad(verdict.spokenDescription)
        } catch {
            log.error("re-check failed: \(String(describing: error))")
            checkState = .bad("Mynah couldn't set that brain up. Set it up again.")
        }
    }

    func unlinkPhone() async {
        do {
            try await phoneLink.unlink()
            phone = phoneLink.status
        } catch {
            log.error("unlink failed: \(String(describing: error))")
        }
    }

    // MARK: Diagnostics

    /// Everything a person helping the owner would ask for, in one paste.
    ///
    /// This is the one place in the app where paths and version strings are
    /// allowed, and it only ever reaches the pasteboard on an explicit press.
    func diagnostics() -> String {
        var lines: [String] = ["Mynah diagnostics", "Written \(Date().formatted(date: .abbreviated, time: .standard))", ""]

        lines.append("App \(Self.appVersion)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // "It never tells me about updates" is a report somebody will make, and
        // it has two completely different answers: the owner turned it off, or
        // GitHub is not answering.
        lines.append("Update check \(checksForUpdates ? "on" : "off"), \(updateSummary)")

        if let brain {
            lines.append("Brain \(brain.label) [\(brain.backendIdentifier)\(brain.modelName.map { " / \($0)" } ?? "")]")
            lines.append("Words go to \(brain.destination)")
        } else {
            lines.append("Brain not recorded")
        }
        lines.append("Stored keys \(providersWithKeys.isEmpty ? "none" : providersWithKeys.joined(separator: ", "))")

        lines.append("Transcriber \(speech.transcriberPath ?? "not found")")
        lines.append("Speech model \(speech.modelPath ?? "not found")")
        lines.append("Messaging socket \(phone.socketPath) \(phone.isReachable ? "(present)" : "(absent)")")

        // "It used the wrong voice" and "no transcript arrived" are both things
        // the owner will report, and both are answered by these two lines.
        let natural: String
        switch callVoices {
        case .checking: natural = "not checked"
        case .installed(let names): natural = "\(names.count) available"
        case .missing: natural = "not reachable"
        }
        lines.append("Call voice \(callVoice) (natural voice \(natural))")
        lines.append("Call transcripts \(sendsCallTranscript ? "sent to chat" : "not sent")")

        if let probe {
            lines.append("Memory node \(probe.sage.executablePath ?? "not found")")
            lines.append("Memory folder \(probe.sage.stateDirectory ?? "not found")")
            lines.append("Local runtime \(probe.localRuntime.runtimeExecutablePath ?? "not installed") "
                + "at \(probe.localRuntime.baseURL) "
                + "\(probe.localRuntime.isDaemonReachable ? "(running)" : "(not running)")")
            lines.append("Local models \(probe.localRuntime.installedModels.sorted().joined(separator: ", "))")
            lines.append("Hardware \(probe.hardware.cpuBrand ?? "unknown"), "
                + "\(probe.hardware.physicalCoreCount) cores, "
                + "\(MynahCopy.downloadSize(Int64(probe.hardware.physicalMemoryBytes))) memory")
        } else {
            lines.append("Environment not probed")
        }
        lines.append("Key folder \(KeyStorage.url().deletingLastPathComponent().path)")
        return lines.joined(separator: "\n")
    }

    /// The last answer, in the shape whoever is helping would need it: which of
    /// the three states it is in, and — when it could not check — which way it
    /// failed.
    private var updateSummary: String {
        switch update {
        case .none: return "not asked yet"
        case .upToDate?: return "up to date"
        case .newer(let version, _)?: return "\(version) available"
        case .cannotTell(let problem)?: return "could not check (\(problem))"
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// The version of the SAGE this Mac is actually running.
    ///
    /// **It reported the wrong one.** This resolved through
    /// `probe?.sage.executablePath`, and the probe is vendored-first — its job
    /// is finding *a* runnable node on a bare machine. So on a Mac with SAGE
    /// installed, About named the version of the copy inside this app, which is
    /// not the copy operating the owner's memories. `SageNodeChoice` exists
    /// precisely because an installed node wins and is never managed, and this
    /// is now the third place that had to learn it — after the memories screen
    /// and the task board.
    ///
    /// The two versions happen to match today, which is exactly why nobody saw
    /// it and exactly why it is worth fixing before they diverge. Same shape as
    /// the pause file, the ghost identity and the plist-versus-launchctl
    /// question: reporting what we shipped rather than what is running.
    var nodeVersion: String? {
        let executable = SageNodeChoice
            .resolve(vendored: SageNodeLocator.vendoredExecutableURL())?.executable
            ?? probe?.sage.executablePath.map(URL.init(fileURLWithPath:))
        guard let executable,
              let bundle = SageNodeLocator.appBundle(containing: executable) else { return nil }
        return SageNodeLocator.bundleVersion(at: bundle)
    }
}

// MARK: - What the screen is made of

/// Every group heading on the settings screen, named once.
///
/// Literals in two places is how a tab quietly stops carrying a group: the
/// switch that renders the pane and the list that says which tab owns what would
/// each look right on their own. `SettingsTabsTests` asserts that every name
/// below is claimed by exactly one tab, which only means anything because both
/// sides read these constants rather than typing the words again.
enum SettingsGroupTitle {
    static let unfinished = "Unfinished"
    static let brain = "Where your words go"
    static let voice = "Voice"
    static let calls = "Calls"
    static let phone = "Your phone"
    static let privacy = "What leaves this Mac"
    static let answering = "Answering"
    static let appearance = "Appearance"
    static let advanced = "Advanced"
    static let about = "About"

    /// Everything a tab has to account for. `unfinished` is not here: it is a
    /// call to action rather than a category, so it sits above the tabs and is
    /// visible whichever one is open.
    static let tabbed = [
        brain, voice, calls, phone, privacy, answering, appearance, advanced, about
    ]
}

/// The tabs, in the order they appear.
///
/// Four. It was five, and the fifth was the tell: "Where your words go" sat
/// under General and "What leaves this Mac" sat under a Privacy tab of its own,
/// which is one idea — the only idea this product is really about — split across
/// two screens so that neither said the whole thing. Merging them into **Your
/// words** left Phone alone on a tab holding three rows, and Phone belongs with
/// the other facts about how this Mac behaves.
///
/// `Your words` is first because it is what the owner came to check.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case words
    case voice
    case general
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .words: return "Your words"
        case .voice: return "Voice"
        case .general: return "General"
        case .about: return "About"
        }
    }

    /// The groups this tab shows, in the order it shows them.
    var groups: [String] {
        switch self {
        case .words:
            // Where they go, then what leaves. The second is the audit of the
            // first, and reading them together is the point.
            return [SettingsGroupTitle.brain, SettingsGroupTitle.privacy]
        case .voice:
            return [SettingsGroupTitle.voice, SettingsGroupTitle.calls]
        case .general:
            return [
                SettingsGroupTitle.phone,
                SettingsGroupTitle.answering,
                SettingsGroupTitle.appearance
            ]
        case .about:
            // About before Advanced: a tab named About that opens on a folded
            // "Advanced" row is a tab that answers a question nobody asked. The
            // Support row's copy names where the diagnostics are, so the order
            // costs the owner nothing.
            return [SettingsGroupTitle.about, SettingsGroupTitle.advanced]
        }
    }
}

// MARK: - Screen

/// Settings as a sidebar destination, not a `Settings` scene.
///
/// A preferences window is a second window: it can end up behind the main one,
/// on a different Space, or invisible to a screen-share — and the owner of this
/// appliance is exactly the person who will be on a call with someone helping
/// them when they need it.
struct SettingsView: View {
    var onOpenSection: (MainSection) -> Void

    @Environment(AppModel.self) private var app
    @State private var model: SettingsModel
    /// Which tab is open. Not persisted: the owner arrives here to do one thing,
    /// and a screen that reopens on wherever they last were is a screen that
    /// hides the thing they came back for.
    @State private var tab: SettingsTab = .words
    @State private var isAdvancedOpen = false
    @State private var didCopyDiagnostics = false
    @State private var isBuiltOnOpen = false
    @State private var didCopyEmail = false
    /// Which deferred step is being finished right now, if any. The sheets are
    /// the whole point of the "Unfinished" list: a row that names a task and
    /// then restarts the wizard is a five-screen detour to reach the one screen
    /// the owner asked for.
    @State private var isLinkingPhone = false
    @State private var isPastingKey = false
    @State private var isChangingModel = false
    @State private var isChangingProvider = false

    /// Seeded from disk rather than defaulted, so the switch shows what the
    /// daemon will actually do rather than what this app assumes.
    @State private var voiceNotes = ReplyPreferences().style().usesVoiceNotes

    private static let log = MynahLog(category: "settings")

    /// The conversation's own view of whether Mynah can think.
    ///
    /// Settings used to report the *stored* choice and nothing else, so it could
    /// say "Mynah thinks with: Claude Code" on the same session where Home said
    /// "Mynah can't use that brain any more". On a screen whose whole job is
    /// answering "where do my words go?", naming a destination that receives
    /// nothing is the one thing it must not do.
    private var conversation: ConversationModel { .shared }

    /// `@MainActor` because `SettingsModel` is, and a `View`'s initialiser is
    /// not isolated by default even though SwiftUI only ever calls it here.
    ///
    /// `openOn` exists for the previews and nothing else. A tab that cannot be
    /// opened without clicking is a tab whose layout nobody looks at until an
    /// owner finds it broken, and this screen has five of them.
    @MainActor
    init(
        onOpenSection: @escaping (MainSection) -> Void = { _ in },
        model: SettingsModel? = nil,
        openOn tab: SettingsTab = .words
    ) {
        self.onOpenSection = onOpenSection
        _model = State(initialValue: model ?? SettingsModel())
        _tab = State(initialValue: tab)
    }

    var body: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 0) {
            head(app: app)
            // A hairline under the band, running the full width of the pane
            // rather than the width of the column. It is what turns the title
            // and the tabs into chrome that stays put and the rest into content
            // that scrolls under it — the same read as a Mac settings window.
            MynahDivider()
            pane(app: app)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.surface.canvas)
        .onAppear { model.refresh() }
        .task { await model.probeIfNeeded() }
        .task { await model.loadCallVoices() }
        // Beside the screen, never in front of it. The row below carries its own
        // "asking" state, and no part of this page is waiting on GitHub.
        .task { await model.checkForUpdate() }
        // Asked every time the screen appears, not cached: the owner may have
        // just come back from switching Mynah off in Login Items, and that is
        // the trip this row exists to report on.
        .task { await model.refreshHelperState() }
        .sheet(isPresented: $isLinkingPhone) {
            PhoneLinkSheet {
                app.resolveDeferredStep(id: AppModel.DeferredStep.phoneLinkID)
                isLinkingPhone = false
                Task {
                    await app.reconcileAnsweringService()
                    model.refresh()
                }
            } onClose: {
                model.refresh()
                isLinkingPhone = false
            }
        }
        .sheet(isPresented: $isChangingProvider) {
            if let probe = model.probe {
                BrainProviderSheet(
                    choices: BrainSetupPlanner().plan(for: probe),
                    current: model.brainOption,
                    // What Ollama has actually pulled. The sheet lists these and
                    // offers no way to type a name — a model named by hand is a
                    // typo that becomes a failure two screens later, and the
                    // machine already knows the answer.
                    installedLocalModels: localModels
                ) { outcome in
                    isChangingProvider = false
                    switch outcome {
                    case .cancelled:
                        break
                    case .chose(let option):
                        // **No `needsAKeyFirst` any more.** That case closed this
                        // sheet, saved a brain that could not answer, and opened a
                        // second sheet to collect the key — which is why the owner
                        // reported there was nowhere to set one. The field is on
                        // the sheet now, and nothing arrives here unverified.
                        BrainSelectionStore.save(option)
                        model.refresh()
                        // Both consumers, same as the model picker. The window
                        // builds its own engine and the appliance reads the
                        // choice at launch, so changing one and not the other
                        // is how the phone and the window end up on different
                        // brains.
                        Task {
                            await conversation.reconnect()
                            await app.reconcileAnsweringService()
                        }
                    }
                }
            } else {
                // The probe is what lists the options. Without it there is
                // nothing to choose between, and a sheet of nothing is worse
                // than the button having done nothing.
                ProbeUnavailableSheet { isChangingProvider = false }
            }
        }
        .sheet(isPresented: $isChangingModel) {
            if let option = model.brainOption {
                BrainModelSheet(
                    option: option,
                    // A real list when the node can supply one, and none when it
                    // cannot. The probe knows exactly what is installed for a
                    // local runtime; for an API provider nobody here knows what
                    // the company is serving this week, and a hardcoded list of
                    // model names is a list that goes stale silently — which is
                    // the same reason no version number is typed into this app.
                    installed: localModels
                ) { chosen in
                    isChangingModel = false
                    guard let chosen else { return }
                    BrainSelectionStore.save(chosen)
                    model.refresh()
                    // Both halves, because the model is two things: the window
                    // builds its own engine, and the appliance answering the
                    // phone is a separate process that reads the choice at
                    // launch. Changing one and not the other is how the window
                    // and the phone end up on different models.
                    Task {
                        await conversation.reconnect()
                        await app.reconcileAnsweringService()
                    }
                }
            }
        }
        .sheet(isPresented: $isPastingKey) {
            if let option = model.brainOption,
               let provider = option.keyProviderIdentifier,
               let instructions = APIKeyOnboarding.instructions(forProvider: provider) {
                BrainKeySheet(option: option, provider: provider, instructions: instructions) { accepted in
                    if accepted {
                        app.resolveDeferredStep(id: AppModel.DeferredStep.brainKeyID)
                        // A replacement key for the same brain leaves the stored
                        // choice untouched, so `connect()` would keep the engine
                        // that is failing on the old key.
                        Task { await conversation.reconnect() }
                    }
                    isPastingKey = false
                }
            }
        }
    }

    // MARK: The band, and what scrolls under it

    /// Title, anything unfinished, and the tabs.
    ///
    /// The title is here because the window has none — `RootView` clears it so
    /// the sidebar can carry the app's identity alone — and because the memories
    /// pane names itself the same way. Without it the tab strip floats at the
    /// top of an empty canvas with nothing holding it down.
    private func head(app: AppModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .accessibilityAddTraits(.isHeader)

            // Above the tabs, not inside one. A step the owner deferred is the
            // reason they are on this screen at all, and burying it behind a tab
            // is the "Later that leads nowhere" this list exists to prevent.
            unfinished(app: app)

            MynahTabBar(tabs: SettingsTab.allCases, selection: $tab) { $0.title }
                .padding(.top, s6)
                .accessibilityLabel("Settings sections")
        }
        .frame(maxWidth: MynahWidth.settings, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, s8)
        .padding(.top, s7)
        .padding(.bottom, s6)
    }

    private func pane(app: AppModel) -> some View {
        ScrollView {
            groups(app: app)
                .frame(maxWidth: MynahWidth.settings, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, s8)
                .padding(.bottom, s9)
                // A tab is a change of subject, not a change of place, so the
                // groups fade rather than slide. A slide here would read as
                // navigation and invite the owner to look for a way back.
                .id(tab)
                .transition(.opacity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .mynahAnimation(Motion.fade, value: tab)
    }

    /// `spacing: 0` on purpose: `SectionHeader` already carries the air above a
    /// group, and adding a second gap put half a line of empty canvas between
    /// every heading and the group it belongs to.
    @ViewBuilder
    private func groups(app: AppModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .words:
                brainSection
                privacySection
            case .voice:
                voiceSection
                callSection
            case .general:
                phoneSection
                answeringSection(app: app)
                appearanceSection(app: app)
            case .about:
                aboutSection
                advancedSection
                colophon
            }
        }
    }

    /// Who made this, at the foot of the pane.
    ///
    /// It was a row inside the About card, which put a name and a copyright
    /// year in the same treatment as a version number and an update switch —
    /// things you read once beside things you act on. At the foot it is what a
    /// Mac app's colophon is: quiet, last, and unmistakably not a control.
    private var colophon: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(MynahAbout.author)
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
            Text(MynahAbout.copyright)
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.tertiary)
        }
        .padding(.top, s7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Unfinished

    /// Every row here goes to the screen it names.
    ///
    /// `restartSetup()` was the destination for all of them, which meant an owner
    /// who skipped linking their phone was put back through the welcome screen
    /// and made to re-pick where their words go. `SignalLinkView` was explicitly
    /// factored out of its stage "so Settings can present the same thing in a
    /// sheet" and nothing did.
    @ViewBuilder
    private func unfinished(app: AppModel) -> some View {
        if !app.deferredSetupSteps.isEmpty {
            SettingsGroup(SettingsGroupTitle.unfinished) {
                ForEach(Array(app.deferredSetupSteps.enumerated()), id: \.element.id) { index, step in
                    // Between rows, never after the last one — a trailing
                    // divider inside a card draws a line under nothing.
                    if index > 0 { MynahDivider() }
                    SettingsRow(step.title, detail: step.detail) {
                        MynahButton("Set this up", kind: .secondary) { open(step, app: app) }
                    }
                }
            }
        }
    }

    private func open(_ step: AppModel.DeferredStep, app: AppModel) {
        switch step.id {
        case AppModel.DeferredStep.phoneLinkID:
            isLinkingPhone = true
        case AppModel.DeferredStep.brainKeyID where model.brain?.needsAKey == true:
            isPastingKey = true
        default:
            // No sheet knows how to finish this one, so the full run is the
            // honest answer rather than a button that opens nothing.
            app.restartSetup()
        }
    }

    /// Times only — the date is noise for something that restarts most days.
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: Brain

    /// The trouble banner sits above the card rather than inside it.
    ///
    /// It is an alert about the whole group, not a row in it, and a bordered
    /// note nested inside a bordered card is two boxes saying one thing.
    @ViewBuilder
    private var brainSection: some View {
        if let trouble = conversation.trouble, model.brain != nil {
            // One source of truth for "can Mynah think right now": the same
            // authored sentence Home is showing, on the screen the owner came to
            // in order to fix it.
            InlineBanner(
                tone: trouble.isSevere ? .critical : .info,
                headline: trouble.headline,
                explanation: trouble.explanation
            )
            .padding(.top, s6)
        }
        if model.brain == nil {
            InlineBanner(
                headline: "Mynah hasn't recorded where your words go.",
                explanation: "Set it up again and it will remember your answer this time.",
                actionTitle: "Set Mynah up again",
                action: { app.restartSetup() }
            )
            .padding(.top, s6)
        }
        brainGroup
    }

    /// No card at all when there is nothing true to put in one.
    ///
    /// With no recorded brain and no stored key, the banner above already says
    /// everything there is to say, and an empty bordered box under a heading
    /// reads as a group that failed to load.
    @ViewBuilder
    private var brainGroup: some View {
        if model.brain != nil {
            SettingsGroup(SettingsGroupTitle.brain) { recordedBrainRows }
        } else if !model.providersWithKeys.isEmpty {
            SettingsGroup(SettingsGroupTitle.brain) {
                // Real, persisted fact, shown when the brain choice itself was
                // never recorded, so the screen still has something true to say.
                SettingsRow(
                    "Keys saved on this Mac",
                    detail: model.providersWithKeys
                        .map { MynahCopy.company(forBackend: $0) ?? $0 }
                        .joined(separator: ", ")
                ) {
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var recordedBrainRows: some View {
        if let brain = model.brain {
            // Scoped to the window, because that is all this record covers.
            // `BrainSelectionStore` is what the owner picked in the app and
            // nothing outside MynahMac reads it — the appliance builds its own
            // backend from its launch flags. Reporting it as "Mynah" made the
            // one question this product exists to answer wrong.
            SettingsRow("When you ask from this window", detail: brain.label) {
                StatusPill(destinationTitle(brain), tone: destinationTone(brain))
            }
            MynahDivider()
            applianceRow
            MynahDivider()
            // **A sheet, not the whole of setup**, on the owner's report:
            // *"changing the model shouldn't redo the whole setup."*
            //
            // This called `restartSetup()`, which drops `hasCompletedSetup` and
            // sends a Mac that was configured hours ago back to Welcome. Worse
            // than the annoyance: `hasCompletedSetup == false` is a `stop`
            // intent, so entering that flow **removed both LaunchAgents** and
            // his phone stopped being answered until he finished or backed out.
            // Opening it out of curiosity cost him the appliance.
            //
            // Same shape as the Calls row that used to send him to onboarding
            // to change a model — a small reversible change routed through the
            // largest irreversible flow in the product.
            SettingsRow(
                "Change where your words go",
                detail: "Pick somewhere else for Mynah to think. It is asked a real question "
                    + "before the change is kept, and what Mynah already remembers stays "
                    + "where it is."
            ) {
                MynahButton("Change", kind: .secondary) { isChangingProvider = true }
            }
            MynahDivider()
            modelRow
            if brain.needsAKey {
                MynahDivider()
                SettingsRow(
                    "The key Mynah uses",
                    detail: "Paste a new one whenever the old one stops working. "
                        + "It stays on this Mac and is never shown again."
                ) {
                    MynahButton("Paste a key", kind: .secondary) { isPastingKey = true }
                }
                MynahDivider()
                recheckRow
            }
        }
    }

    // **"Why Claude Code and Codex aren't options" is gone**, on the owner's
    // instruction: *"remove claude and codex if we can't use it bro - wtf is the
    // point of this section and message?!"*
    //
    // He is right, and the reasoning that put it here was about the wrong
    // problem. It began as two greyed cards in the brain picker, which read as
    // "not detected" for software he was visibly running. Moving the sentence to
    // Settings fixed the misreading and kept the mistake underneath it: a
    // settings screen is for things you can change, and this was several
    // paragraphs about two things that will never appear, shown only to the
    // people most likely to be annoyed by them. The honest fix for an
    // explanation nobody asked for is to stop explaining, not to relocate it.

    /// The appliance's own report, or an honest absence.
    @ViewBuilder
    private var applianceRow: some View {
        if let appliance = model.appliance {
            SettingsRow(
                "When you ask from your phone",
                detail: "\(appliance.model), as of \(Self.time.string(from: appliance.startedAt))."
                    + (appliance.keepsWordsOnDevice
                       ? " Nothing you say leaves this Mac."
                       : " What you say goes to \(appliance.destination).")
            ) {
                StatusPill(
                    appliance.destination,
                    // Neutral, not caution: the pill already names the
                    // company, and a name is a more specific signal than a
                    // colour that also means paused. See `Palette.state`.
                    tone: appliance.keepsWordsOnDevice ? .good : .neutral
                )
            }
        } else {
            // Not the same sentence as any provider name: nobody has answered a
            // phone on this Mac yet.
            SettingsRow(
                "When you ask from your phone",
                detail: "Mynah hasn't answered your phone on this Mac yet, so there is "
                    + "nothing to report."
            ) {
                StatusPill("Not yet", tone: .neutral)
            }
        }
    }

    /// The stored destination, unless the conversation says nothing is getting
    /// through — in which case the pill says so rather than naming a company
    /// that is receiving nothing.
    private func destinationTitle(_ brain: BrainChoice) -> String {
        conversation.trouble == nil ? brain.destination : "Not answering"
    }

    private func destinationTone(_ brain: BrainChoice) -> MynahTone {
        guard conversation.trouble == nil else { return .neutral }
        return brain.keepsWordsOnDevice ? .good : .neutral
    }

    /// Changing which model does the thinking.
    ///
    /// **There was no way to do this at all.** The key could be replaced and
    /// re-checked, but the model could only be changed by re-running the whole
    /// of setup through "Change where your words go" — and the Calls row
    /// actively sends the owner there: *"Change where your words go to one of
    /// the API models and calling works."* So the app named the fix and then
    /// made him reinstall to apply it. Changing model is an ordinary thing an
    /// owner does; it is not a reinstallation.
    ///
    /// It sits beside the key because that is the other thing about the brain
    /// he can change, and the two fail in related ways — a model name the
    /// provider does not serve and a key it will not accept produce the same
    /// silence at the same moment.
    /// Sits under both destination rows on purpose.
    ///
    /// This is the owner's *choice*, and the two rows above are the two places
    /// that choice has to land — this window, which picks it up at once, and
    /// the appliance, which reads its model from launch flags and therefore
    /// only learns about it when it next starts. They normally agree, because
    /// changing the model here rewrites the appliance's job as well.
    ///
    /// **They can drift, and one of the ways is new.** A reconcile that cannot
    /// read the configuration now deliberately changes nothing rather than
    /// tearing the appliance down — which is right, and it means a model change
    /// made in that window updates the store while the running appliance keeps
    /// the model it was started with. So this row must not say "the model
    /// Mynah uses" as though there were one place to look. The appliance row
    /// above reports what the phone is *actually* running, and if the two ever
    /// disagree the owner can see it rather than being told a number that is
    /// true of only half the product.
    /// **The owner no longer picks a cloud model, so this row no longer offers
    /// to change one.** It still reports, because what is running is worth
    /// knowing and the two-places-to-land problem above is still real.
    ///
    /// The button survives for a local runtime only, and the distinction is not
    /// an inconsistency. A cloud model name is a lookup against a catalogue that
    /// changes without telling anyone, in a vocabulary the owner has no reason
    /// to have learned — that is the whole argument for Mynah picking it. None
    /// of that is true of a model sitting on this Mac: it does not get retired
    /// behind his back, and somebody who ran `ollama pull` knows exactly what
    /// they pulled and why. Taking that away would be applying the rule past the
    /// thing the rule was aimed at.
    private var modelRow: some View {
        SettingsRow(
            "The model it thinks with",
            detail: modelRowDetail
        ) {
            if !localModels.isEmpty {
                MynahButton("Change", kind: .secondary) { isChangingModel = true }
            }
        }
    }

    /// Model names the local runtime actually has. Empty for an API provider —
    /// which is also what hides the button.
    private var localModels: [String] {
        model.probe?.localRuntime.installedModels.sorted() ?? []
    }

    private var modelRowDetail: String {
        let current = model.brain?.modelName.map { "Currently \($0)." }
            ?? "Mynah hasn't recorded which model it is on."
        guard localModels.isEmpty else {
            return current + " This window changes over straight away. Your phone picks it up "
                + "the next time the appliance starts."
        }
        // No longer "whatever this provider gives it by default" — that was
        // never true. Mynah asks for a specific model; it just isn't one the
        // owner was ever asked to name.
        return current + " Mynah picks the model for each provider — a fast one that can "
            + "hold a conversation and drive its tools. To change it, change where your "
            + "words go above."
    }

    private var recheckRow: some View {
        VStack(alignment: .leading, spacing: s3) {
            SettingsRow(
                "Check the key still works",
                detail: "Asks a real question, the way Mynah does, so a key that has "
                    + "run out of credit is caught here rather than mid-answer."
            ) {
                if case .checking = model.checkState {
                    ProgressView().controlSize(.small).tint(Palette.accent.fill)
                } else {
                    MynahButton("Check now", kind: .secondary) {
                        Task { await model.recheckKey() }
                    }
                }
            }
            checkResult
        }
    }

    @ViewBuilder
    private var checkResult: some View {
        switch model.checkState {
        case .idle, .checking:
            EmptyView()
        case .good(let sentence):
            Text(sentence)
                .mynahFont(.body)
                .foregroundStyle(Palette.state.good)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, s4)
        case .bad(let sentence):
            Text(sentence)
                .mynahFont(.body)
                .foregroundStyle(Palette.state.critical)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, s4)
                .transition(.push(from: .top).combined(with: .opacity))
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        SettingsGroup(SettingsGroupTitle.voice) {
            SettingsRow("You speak into", detail: PrivacyClaim.microphone) {
                Text("Phone or Mac").mynahFont(.bodyEmphasis).foregroundStyle(Palette.ink.secondary)
            }
            MynahDivider()

            SettingsRow(
                "Turning your voice into words",
                detail: model.speech.isReady
                    ? "Happens on this Mac. Your recordings are not uploaded anywhere."
                    : "Mynah can't find what it uses to turn speech into words on this Mac."
            ) {
                if model.speech.isReady, let name = model.speech.modelName {
                    StatusPill(name, tone: .good)
                } else {
                    MynahButton("Set Mynah up again", kind: .secondary) { app.restartSetup() }
                }
            }
            MynahDivider()

            SettingsRow(
                "Speaking the answer",
                detail: "The voice Mynah answers in is generated on this Mac."
            ) {
                Text("This Mac").mynahFont(.bodyEmphasis).foregroundStyle(Palette.ink.secondary)
            }
            MynahDivider()

            // The detail line explains the consequence, not the mechanism. The
            // owner is choosing how they want to be answered; that this rewrites
            // a section of the system prompt is not their problem.
            // The daemon reads this file once at start-up (main.swift
            // resolveReplyStyle), so saving also reconciles the supervised
            // service. The switch and the running appliance then tell the same
            // truth immediately.
            SettingsRow(
                "Answer with voice notes",
                detail: (voiceNotes
                    ? "Mynah speaks its answers, so it keeps them short — a couple of sentences, "
                        + "no lists. Long answers are unlistenable."
                    : "Mynah writes its answers, so it gives you the whole thing — a line per "
                        + "item, and links you can tap.")
                    + " This applies to new answers immediately."
            ) {
                Toggle("", isOn: $voiceNotes)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: voiceNotes) { _, isOn in
                        do {
                            try ReplyPreferences().save(voiceNotes: isOn)
                        } catch {
                            // Revert rather than show a switch that lies about
                            // what the daemon will do.
                            Self.log.error("could not save reply preference: \(error)")
                            voiceNotes = !isOn
                            return
                        }
                        Task { await app.reconcileAnsweringService() }
                    }
            }
        }
    }

    // MARK: Calls

    /// Talking to Mynah out loud: whether it can happen, how it sounds, and
    /// whether anything survives it.
    private var callSection: some View {
        SettingsGroup(SettingsGroupTitle.calls) {
            callReadinessRow
            MynahDivider()

            callVoiceRow
            MynahDivider()

            SettingsRow(
                "Send the transcript to my chat",
                detail: "When a call ends, what was said is posted back into your Signal thread, "
                    + "so there is a record of it."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.sendsCallTranscript },
                    set: { model.setSendsCallTranscript($0) }
                ))
                .labelsHidden()
                .mynahToggle()
            }
        }
    }

    /// Whether `//call` will work, taken from the fact the refusal is built on.
    ///
    /// **This row used to be about the model and it was the wrong barrier.** It
    /// reported `keepsWordsOnDevice`, because that was what
    /// `CallInvitation.refusal` refused on — a brain running on this Mac was
    /// assumed too slow to hold a call. That assumption died on measurement (see
    /// `CallInvitation.refusal(isSetUpForCalls:)`), and this row died with it.
    ///
    /// The barrier that remains is the relay secret, and it is the one the owner
    /// was never told about: on a Mac without it, an owner following this row's
    /// old advice switched to an API model, tried again, and was refused for a
    /// reason nothing had mentioned. So the row reports the *real* condition.
    ///
    /// Still reading the same fact the daemon refuses on — `CallHost` is the one
    /// source — so the two cannot drift into disagreeing.
    @ViewBuilder
    private var callReadinessRow: some View {
        let isSetUp = CallHost.isSetUpForCalls()
        SettingsRow(
            "Talking to Mynah out loud",
            detail: isSetUp
                ? "Text \(CallInvitation.command) to yourself and tap the link it sends back. "
                    + "You can interrupt it mid-sentence."
                : "This Mac hasn't been set up for calls yet. Voice notes work either way — "
                    + "send one and Mynah answers with one."
        ) {
            StatusPill(
                isSetUp ? "Ready" : "Not set up",
                tone: isSetUp ? .good : .neutral
            )
        }
    }

    @ViewBuilder
    private var callVoiceRow: some View {
        switch model.callVoices {
        case .checking:
            SettingsRow(
                "The voice on a call",
                detail: "Mynah is looking for the natural voice on this Mac."
            ) {
                ProgressView().controlSize(.small).tint(Palette.accent.fill)
            }

        case .missing:
            // No picker at all in this state, on purpose. A menu of voices that
            // cannot be spoken is a control the owner sets and never hears.
            SettingsRow(
                "The voice on a call",
                detail: "The natural voice isn't installed on this Mac, so calls use the voice "
                    + "built into macOS. It works, and it sounds robotic."
            ) {
                StatusPill("Built-in voice", tone: .neutral)
            }

        case .installed(let names):
            VStack(alignment: .leading, spacing: s3) {
                SettingsRow(
                    "The voice on a call",
                    detail: "Generated on this Mac, like the voice notes. A name tells you "
                        + "nothing about how a voice sounds, so listen to one before you keep it."
                ) {
                    HStack(spacing: s4) {
                        if model.isPlayingCallVoice {
                            ProgressView().controlSize(.small).tint(Palette.accent.fill)
                        } else {
                            MynahButton("Listen", kind: .quiet) {
                                Task { await model.playCallVoice() }
                            }
                        }
                        Picker("", selection: Binding(
                            get: { model.callVoice },
                            set: { model.setCallVoice($0) }
                        )) {
                            ForEach(names, id: \.self) { name in
                                Text(KokoroVoices.displayName(name)).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
                // Beside the voice, because they are one decision: a voice at
                // the wrong pace is the wrong voice, and Listen plays both so
                // the owner judges the thing they will actually hear rather
                // than a number.
                SettingsRow(
                    "How fast it talks",
                    detail: "The default is a little quicker than normal reading pace. "
                        + "A call is an exchange, not an audiobook."
                ) {
                    HStack(spacing: s4) {
                        Slider(
                            value: Binding(
                                get: { model.callSpeed },
                                set: { model.setCallSpeed($0) }
                            ),
                            in: CallPreferences.slowest...CallPreferences.fastest
                        )
                        .frame(width: 180)
                        Text(String(format: "%.2f×", model.callSpeed))
                            .mynahFont(.mono)
                            .foregroundStyle(Palette.ink.secondary)
                            .frame(width: 52, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
                if let problem = model.callVoiceProblem {
                    Text(problem)
                        .mynahFont(.body)
                        .foregroundStyle(Palette.state.critical)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, s4)
                }
            }
            .mynahAnimation(Motion.fade, value: model.callVoiceProblem)
        }
    }

    // MARK: Phone

    private var phoneSection: some View {
        SettingsGroup(SettingsGroupTitle.phone) {
            // **The number came out of the value slot, and that is most of the
            // fix.**
            //
            // It was a bare number, right-aligned in mono where a *value* goes,
            // directly above a row about calling. Everything about that
            // placement says "this is the number you ring" — the owner read it
            // that way and he was reading the layout correctly. The words never
            // claimed it; the position did.
            //
            // So the number moves into a sentence, where it can be given a job,
            // and the value slot gets a status instead. `thread`'s wording, and
            // "Nothing dials this number" is the clause doing the work — the
            // rest is the sentence it needed to sit in. It also keeps the
            // allowlist fact, which was in the old detail and is worth not
            // losing.
            SettingsRow(
                "Your Signal account",
                detail: model.phone.linkedNumber.map {
                    "Mynah listens to the thread you send yourself, on \($0). Nothing dials "
                        + "this number — and messages from anyone else are ignored."
                } ?? "Mynah hasn't been told which Signal account to listen on."
            ) {
                if model.phone.linkedNumber != nil {
                    StatusPill("Linked", tone: .good)
                } else {
                    StatusPill("Not set", tone: .neutral)
                }
            }
            MynahDivider()

            MynahDivider()

            // The phone group is where an owner looks for what their phone can
            // do, and until now it said only that Mynah answers. Calling was
            // documented once, under a heading about model speed, which is not
            // where anybody goes to ask "what can I do with this thing".
            //
            // The condition is stated rather than left to the Calls group: an
            // unqualified "you can call it" sends an owner on a local model to
            // be refused, and the refusal is not a bug they can act on.
            SettingsRow(
                "You can also call it",
                // **Two barriers, not one.** The model refusal fires first and
                // hid the other: `CallHost` also needs a relay secret, which
                // does not exist on the owner's Mac — verified — so calling has
                // never been possible here for two reasons and this row named
                // one. An owner who switched to an API model on `thread`'s word
                // would have been refused again, for a reason nothing had
                // mentioned.
                //
                // The last sentence is checked rather than hoped:
                // `handleCallRequest` wraps `calls.start()` in a `catch` and
                // replies, so a failure does reach him as a message.
                detail: "Send \(CallInvitation.command) to yourself in Signal and tap the link "
                    + "it sends back — you talk out loud and can interrupt it mid-sentence. It "
                    + "needs a brain that answers fast, so it is turned down on a model that "
                    + "runs on this Mac, and this Mac has to be set up for calls. If it can't, "
                    + "it tells you when you ask."
            ) { EmptyView() }
            MynahDivider()

            SettingsRow(
                "Can Mynah reach it",
                detail: model.phone.isReachable
                    ? "The link between this Mac and your phone is up."
                    : "Mynah is starting the private Signal link. If this does not change, "
                        + "turn answering off and on once."
            ) {
                StatusPill(
                    model.phone.isReachable ? "Connected" : "Not connected",
                    tone: model.phone.isReachable ? .good : .neutral
                )
            }

            // Ships the moment the engine can honour it. Until then no button
            // appears, because a control that quietly does nothing teaches the
            // owner their choices are not real.
            if model.canUnlinkPhone, model.phone.linkedNumber != nil {
                MynahDivider()
                SettingsRow(
                    "Stop answering this phone",
                    detail: "Mynah will ignore voice notes until you link a phone again."
                ) {
                    MynahButton("Unlink", kind: .secondary) {
                        Task { await model.unlinkPhone() }
                    }
                }
            } else if model.phone.linkedNumber != nil {
                MynahDivider()
                SettingsRow(
                    "Changing which phone Mynah answers",
                    detail: "This is set when Mynah is installed on this Mac, and changing it "
                        + "means setting Mynah up again."
                ) {
                    MynahButton("Set Mynah up again", kind: .secondary) { app.restartSetup() }
                }
            }
        }
    }

    // MARK: Privacy

    /// Specific and honest, one line per thing that could leave.
    ///
    /// No reassurance that is not a fact, and no fact stated more warmly than it
    /// deserves — the cloud row says the company's name.
    private var privacySection: some View {
        SettingsGroup(SettingsGroupTitle.privacy) {
            SettingsRow(
                "What you say, while Mynah thinks",
                detail: leavesForThinking
            ) {
                StatusPill(
                    model.brain?.destination ?? "Not chosen",
                    tone: model.brain.map { $0.keepsWordsOnDevice ? .good : .neutral } ?? .neutral
                )
            }
            MynahDivider()

            SettingsRow(
                "Your recordings",
                detail: "They are turned into words here and never sent anywhere."
            ) {
                StatusPill("Stays here", tone: .good)
            }
            MynahDivider()

            SettingsRow(
                "What Mynah remembers",
                detail: "Kept on this Mac, in a folder only you can read."
            ) {
                MynahButton("See it", kind: .secondary) { onOpenSection(.memories) }
            }
            MynahDivider()

            SettingsRow(
                "Looking something up on the web",
                detail: "When a question needs the internet, the words Mynah searches for go "
                    + "to a search engine. The rest of what you said does not."
            ) {
                StatusPill("Only when needed", tone: .neutral)
            }
            MynahDivider()

            // On this list because it is a thing that leaves. It is also the
            // only one the owner did not cause by speaking — it happens on its
            // own — which makes leaving it off the list the worst omission
            // available. The switch is in About, named here so it can be found.
            // Shortened, and the length was duplication rather than thoroughness:
            // the About tab carries the same explanation at the row where the
            // owner can actually act on it. This one's job is to appear on the
            // list of things that leave, which it now does in a line.
            SettingsRow(
                "Checking for a newer Mynah",
                detail: "Mynah asks GitHub once a day whether there is a newer version. "
                    + "The switch is on the About tab."
            ) {
                StatusPill(
                    model.checksForUpdates ? "Once a day" : "Turned off",
                    tone: model.checksForUpdates ? .neutral : .good
                )
            }
        }
    }

    private var leavesForThinking: String {
        guard let brain = model.brain else {
            return "Mynah hasn't recorded where it sends your words to think."
        }
        if brain.keepsWordsOnDevice {
            return "Nothing. Mynah works out its answer here, on this Mac."
        }
        return "Sent to \(brain.destination) each time you ask something, so it can work "
            + "out an answer."
    }

    // MARK: Answering

    private func answeringSection(app: AppModel) -> some View {
        @Bindable var app = app
        return SettingsGroup(SettingsGroupTitle.answering) {
            // Names the panel, because the panel is the visible half of this
            // setting. The row used to promise something with no evidence on
            // screen: the window closed, one menu-bar glyph appeared, and the
            // owner had no way to tell whether anything was still listening.
            SettingsRow(
                "Keep answering from my phone",
                detail: app.answeringServiceError
                    ?? ("Mynah runs privately in the background, even with this window closed. "
                        + "Turn this off to stop the phone bridge.")
            ) {
                Toggle("", isOn: $app.keepsAnsweringWhenClosed).labelsHidden().mynahToggle()
            }
            MynahDivider()
            backgroundHelperRow
            MynahDivider()
            SettingsRow("Pause answering", detail: "Mynah stays open but stops replying.") {
                Toggle("", isOn: $app.isPaused).labelsHidden().mynahToggle()
            }
        }
    }

    /// What macOS is actually doing with the helper, as opposed to what Mynah
    /// last asked it to do.
    ///
    /// **The switch above is a request; this row is the answer.** Writing a
    /// LaunchAgent puts an entry in System Settings → General → Login Items, and
    /// the owner can turn it off there. When they do, the phone stops being
    /// answered and every screen in this app carried on saying answering was on
    /// — because nothing asked. That is why `state()` exists and why this row
    /// reads it rather than mirroring the toggle.
    ///
    /// Deliberately not a control. Mynah cannot switch a Login Item back on from
    /// in here; only the owner can, in System Settings. A button that could not
    /// do the thing it named would be worse than the sentence that says where
    /// the thing is.
    @ViewBuilder
    private var backgroundHelperRow: some View {
        SettingsRow("The helper that answers when Mynah is closed", detail: helperDetail) {
            switch model.helperState {
            case .running:
                StatusPill("Running", tone: .good)
            case .installedButNotRunning:
                StatusPill("Switched off", tone: .neutral)
            case .absent:
                StatusPill("Not installed", tone: .neutral)
            case .unknown, .none:
                // No pill at all while the first answer is in flight. A pill
                // that says "Off" for half a second and then corrects itself is
                // the screen guessing out loud.
                EmptyView()
            }
        }
    }

    private var helperDetail: String {
        switch model.helperState {
        case .running:
            return "macOS is running it, so your phone reaches Mynah with this window closed."
        case .installedButNotRunning:
            // The one that needed saying. macOS has stopped it, Mynah cannot
            // start it, and until now nothing told the owner either fact.
            return "macOS has it switched off, so nothing is answering your phone right now. "
                + "Turn Mynah back on in System Settings, under General → Login Items & Extensions."
        case .absent:
            return "Mynah installs a small background helper when the switch above is on. "
                + "It appears in System Settings, under General → Login Items & Extensions."
        case .unknown, .none:
            return "Mynah is checking whether macOS is running it."
        }
    }

    private func appearanceSection(app: AppModel) -> some View {
        @Bindable var app = app
        return SettingsGroup(SettingsGroupTitle.appearance) {
            // Named for what it does rather than for the mechanism. "Tooltips"
            // is the word the owner used and the word every other Mac app uses,
            // so it is what he will look for.
            SettingsRow(
                "Explanations on hover",
                detail: "Hold the pointer over a row and Mynah explains it. Turn this off once "
                    + "you know your way around — nothing is only in a tooltip."
            ) {
                Toggle("", isOn: $app.showsTooltips).labelsHidden().mynahToggle()
            }
            MynahDivider()
            SettingsRow("Text size") {
                Picker("", selection: $app.textSize) {
                    ForEach(MynahTextSize.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }
    }

    // MARK: Advanced

    /// Folded away, because none of it is for the owner — it is for whoever they
    /// call when something is wrong.
    ///
    /// Hand-built rather than a `DisclosureGroup`. The stock one brings AppKit's
    /// default content indentation, so these eight rows and their dividers were
    /// pushed right while every other row on the page started at the section's
    /// leading edge — the only indented content in Settings, in the one section
    /// somebody helping over the phone will be reading out. The chevron is the
    /// single button glyph this app permits.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isAdvancedOpen.toggle()
            } label: {
                HStack(spacing: s3) {
                    Text(SettingsGroupTitle.advanced)
                        .mynahFont(.eyebrow)
                        .foregroundStyle(Palette.ink.secondary)
                    Image(systemName: "chevron.right")
                        .mynahIcon(.inline)
                        .foregroundStyle(Palette.ink.tertiary)
                        .rotationEffect(.degrees(isAdvancedOpen ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                // The same air `SectionHeader` puts above and below a group
                // heading, so a folded Advanced sits on the page at exactly the
                // rhythm the headings above it set.
                .padding(.top, s6)
                .padding(.bottom, s4)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel(SettingsGroupTitle.advanced)
            .accessibilityValue(isAdvancedOpen ? "Open" : "Closed")

            if isAdvancedOpen { advancedRows }
        }
        .mynahAnimation(Motion.snap, value: isAdvancedOpen)
    }

    private var advancedRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            pathRow("Mynah", value: SettingsModel.appVersion)
            MynahDivider()
            pathRow("Memory", value: model.nodeVersion ?? model.probe?.sage.executablePath ?? placeholder)
            MynahDivider()
            pathRow("Memory folder", value: model.probe?.sage.stateDirectory ?? placeholder)
            MynahDivider()
            pathRow("Speech model", value: model.speech.modelPath ?? "Not found")
            MynahDivider()
            pathRow("Transcriber", value: model.speech.transcriberPath ?? "Not found")
            MynahDivider()
            pathRow("Messaging link", value: model.phone.socketPath.isEmpty ? placeholder : model.phone.socketPath)
            MynahDivider()
            pathRow("Keys", value: KeyStorage.url().deletingLastPathComponent().path)
            MynahDivider()
            pathRow(
                "On-device models",
                value: model.probe.map { report in
                    report.localRuntime.installedModels.isEmpty
                        ? "None installed"
                        : report.localRuntime.installedModels.sorted().joined(separator: ", ")
                } ?? placeholder
            )

            MynahDivider()
            SettingsRow(
                "Copy diagnostics",
                detail: "Puts all of the above on the clipboard, so you can paste it to "
                    + "whoever is helping you."
            ) {
                MynahButton(didCopyDiagnostics ? "Copied" : "Copy", kind: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnostics(), forType: .string)
                    didCopyDiagnostics = true
                }
            }
            .mynahAnimation(Motion.fade, value: didCopyDiagnostics)
        }
        .mynahGroupCard()
        .transition(.push(from: .top).combined(with: .opacity))
    }

    // MARK: About

    /// Last on the page, because it is read once.
    ///
    /// Both version numbers are read rather than written down: Mynah's from its
    /// own bundle, SAGE's from the copy vendored inside it. A number typed into
    /// source is a number that survives the release that invalidated it, and an
    /// About panel reporting a version the owner is not running is worse than
    /// one reporting none.
    private var aboutSection: some View {
        SettingsGroup(
            SettingsGroupTitle.about,
            // No promise of a page to visit instead. This repository is private:
            // a link most people would get a 404 from is worse than no link,
            // which is why About carries none either.
            caption: PrivacyClaim.aboutCaption
        ) {
            // The full name here, and only here. In running copy it stays
            // "Mynah" — "Mynah (Sage Voice Bridge) keeps what you tell it" is a
            // sentence nobody wants to read twice. The parenthetical exists to
            // answer "what IS this" once, in the place someone goes to ask.
            SettingsRow(
                "Mynah (Sage Voice Bridge)",
                detail: "A private voice appliance. It answers only your phone."
            ) {
                Text(SettingsModel.appVersion)
                    .mynahFont(.mono)
                    .foregroundStyle(Palette.ink.secondary)
                    .textSelection(.enabled)
            }
            MynahDivider()

            // Directly under the product, which is where a Mac About panel puts
            // a byline and where somebody looking for "who made this" looks
            // The author's byline used to sit here, as a row. It has moved to
            // the foot of the pane — see `colophon` — which is where a Mac app
            // puts a copyright line and where it stops competing with the rows
            // that do something.

            updateRow
            MynahDivider()

            // The explanation moved to the group's caption. It is the longest
            // sentence in Settings and it made this row four lines tall with a
            // switch stranded beside it; under the card it is the same words,
            // available to anyone who wants them, costing the list nothing.
            SettingsRow("Check GitHub for a newer version", detail: "Once a day.") {
                Toggle("", isOn: Binding(
                    get: { model.checksForUpdates },
                    set: { model.setChecksForUpdates($0) }
                ))
                .labelsHidden()
                .mynahToggle()
            }
            MynahDivider()

            SettingsRow(
                "SAGE",
                detail: "What Mynah remembers, and the agent layer it thinks with. "
                    + "Open source, Apache 2.0."
            ) {
                HStack(spacing: s4) {
                    // The address, underlined, rather than a button reading
                    // "View". It was already a link and did not look like one —
                    // an owner scanning for somewhere to click found a verb
                    // rather than a destination. No new colour: underlined
                    // `ink.primary` is the affordance, and this app has no link
                    // token because `accent` means "the one live thing" and a
                    // link is not that.
                    Button { open(MynahAbout.sageURL) } label: {
                        Text(MynahAbout.sageURL.host ?? "github.com")
                            .mynahFont(.mono)
                            .foregroundStyle(Palette.ink.primary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(MynahAbout.sageURL.absoluteString)
                    .accessibilityLabel("Open the SAGE project page")
                    Text(model.nodeVersion ?? placeholder)
                        .mynahFont(.mono)
                        .foregroundStyle(Palette.ink.secondary)
                        .textSelection(.enabled)
                }
            }
            MynahDivider()

            SettingsRow(
                "Support",
                // Names the place rather than pointing at it. Advanced used to
                // sit above this row and now sits below it, and a sentence whose
                // truth depends on the order of two groups is a sentence that
                // goes stale the next time either moves.
                detail: "One person maintains this. Write to them and say what happened — "
                    + "the diagnostics under Advanced are the thing to paste."
            ) {
                HStack(spacing: s4) {
                    MynahButton(didCopyEmail ? "Copied" : "Copy", kind: .quiet) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MynahAbout.supportEmail, forType: .string)
                        didCopyEmail = true
                    }
                    // `mailto:` rather than a second copy button: on a Mac this
                    // opens the owner's mail app with the address already in it,
                    // which is the whole errand.
                    MynahButton("Email", kind: .secondary) {
                        guard let url = URL(string: "mailto:\(MynahAbout.supportEmail)") else { return }
                        open(url)
                    }
                }
            }
            .mynahAnimation(Motion.fade, value: didCopyEmail)
            MynahDivider()

            builtOnDisclosure
        }
    }

    /// Notice, tell, link — never fetch and swap.
    ///
    /// Mynah does not replace itself. It holds a live Signal connection and, on
    /// a call, an open microphone, and software that rewrites its own binary
    /// underneath either of those fails in a way nobody afterwards can explain.
    /// So this row is an answer to a question, with a link the owner can act on
    /// when it suits them.
    ///
    /// "Could not check" is its own state and looks nothing like "up to date".
    /// This repository is private, which means GitHub answers an unauthenticated
    /// request with a 404 — silence, not agreement — and an owner told they were
    /// current on the strength of that would be told it every single day.
    @ViewBuilder
    private var updateRow: some View {
        switch model.update {
        case .none:
            SettingsRow("A newer Mynah", detail: "Mynah is asking GitHub whether there is one.") {
                ProgressView().controlSize(.small).tint(Palette.accent.fill)
            }

        case .upToDate?:
            SettingsRow(
                "A newer Mynah",
                detail: "There isn't one. This is the newest version GitHub has been given."
            ) {
                StatusPill("Up to date", tone: .good)
            }

        case .newer(let version, let page)?:
            SettingsRow(
                "A newer Mynah",
                detail: "Version \(version) has been released. Mynah does not replace itself — "
                    + "download it and swap this copy over whenever it suits you."
            ) {
                HStack(spacing: s4) {
                    StatusPill(version, tone: .neutral, showsDot: false)
                    MynahButton("Download", kind: .secondary) { open(page) }
                }
            }

        // Turned off is a choice, not a failure, so it does not get the pill
        // that means something went wrong.
        case .cannotTell(.turnedOff)?:
            SettingsRow("A newer Mynah", detail: UpdateCheckProblem.turnedOff.spokenDescription) {
                StatusPill("Not checking", tone: .neutral)
            }

        case .cannotTell(let problem)?:
            SettingsRow("A newer Mynah", detail: problem.spokenDescription) {
                StatusPill("Couldn't check", tone: .neutral)
            }
        }
    }

    /// Folded, for the same reason Advanced is: eleven rows of licence names is
    /// a wall in front of the three facts above it. Folded is not hidden — the
    /// list is in the app, one press away, which is what attribution requires.
    private var builtOnDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isBuiltOnOpen.toggle()
            } label: {
                HStack(spacing: s3) {
                    Text("What Mynah is built on")
                        .mynahFont(.title3)
                        .foregroundStyle(Palette.ink.primary)
                    Image(systemName: "chevron.right")
                        .mynahIcon(.inline)
                        .foregroundStyle(Palette.ink.tertiary)
                        .rotationEffect(.degrees(isBuiltOnOpen ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, s4)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel("What Mynah is built on")
            .accessibilityValue(isBuiltOnOpen ? "Open" : "Closed")

            if isBuiltOnOpen {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Other people's work, and what each is licensed under.")
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .mynahProse()
                        .padding(.bottom, s4)

                    ForEach(Array(MynahAbout.components.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { MynahDivider() }
                        attributionRow(item)
                    }
                }
                .transition(.push(from: .top).combined(with: .opacity))
            }
        }
        .mynahAnimation(Motion.snap, value: isBuiltOnOpen)
    }

    private func attributionRow(_ item: Attribution) -> some View {
        // A copyleft component is not discharged by being credited: whoever
        // holds this build is entitled to its source, and the offer has to be
        // where they would look for it rather than in a file nobody opens.
        let detail = [item.role, item.sourceOffer].compactMap { $0 }.joined(separator: " ")

        return SettingsRow(item.name, detail: detail) {
            HStack(spacing: s4) {
                // The licence, not a pill. A pill is for state that changes, and
                // eleven coloured chips down one column would read as eleven
                // things needing attention.
                Text(item.licence)
                    .mynahFont(.mono)
                    .foregroundStyle(Palette.ink.secondary)
                    .textSelection(.enabled)
                MynahButton("View", kind: .quiet) { open(item.url) }
            }
        }
    }

    /// Every link in this section goes through here, so none of them can quietly
    /// become an in-app browser later.
    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private var placeholder: String { model.isProbing ? "Looking…" : "Not found" }

    private func pathRow(_ title: String, value: String) -> some View {
        SettingsRow(title) {
            Text(value)
                .mynahFont(.mono)
                .foregroundStyle(Palette.ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: 300, alignment: .trailing)
                .help(value)
        }
    }
}

// MARK: - Finishing a deferred step

/// The phone stage's own body, in a sheet.
///
/// `SignalLinkView` was factored out of `SignalLinkStage` for exactly this and
/// nothing presented it, so "Set this up" on an unlinked phone restarted the
/// whole wizard. No progress rail here: the owner is not in a flow, they are
/// finishing one thing.
private struct PhoneLinkSheet: View {
    let onLinked: () -> Void
    let onClose: () -> Void

    @State private var model = SignalLinkModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Link your phone")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                SignalLinkView(model: model)
                    .padding(.vertical, s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            ActionRow {
                MynahButton(model.phase.isLinked ? "Done" : "Close", isDefault: true, action: dismiss)
            }
            .padding(.top, s5)
        }
        .padding(s8)
        .frame(width: 620, height: 700)
        .background(Palette.surface.overlay)
        .task { model.refresh() }
        .onDisappear { model.stop() }
        // Escape closes it. A modal with no keyboard way out is a trap, and
        // this one has nothing to confirm.
        .onExitCommand(perform: dismiss)
    }

    /// Deliberately does not fire the moment the link succeeds: the screen's
    /// own "your phone is linked" card is the confirmation, and yanking the
    /// sheet away at that instant reads as a crash rather than a success.
    private func dismiss() {
        let linked = model.phase.isLinked
        model.stop()
        if linked { onLinked() } else { onClose() }
    }
}

/// Pasting a key without walking the whole wizard.
///
/// This is the missing terminal escape from the loop the owner could otherwise
/// not leave: Home said "open Settings and paste the key you were given", and
/// Settings had no field to paste one into anywhere. Same components as the
/// connect stage, no rail.
private struct BrainKeySheet: View {
    let option: BrainSetupOption
    let provider: String
    let instructions: APIKeyOnboarding.Instructions
    /// `true` when a key was accepted and stored.
    let onClose: (Bool) -> Void

    @State private var key = ""
    /// What the provider last said. The offline shape check is derived from the
    /// text instead, so typing never has to round-trip through here.
    @State private var verdict: BrainKeyValidator.Verdict?
    @State private var isChecking = false
    @State private var didAccept = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Paste your \(instructions.providerName) key")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .accessibilityAddTraits(.isHeader)
            Text("Mynah keeps it on this Mac and never shows it again.")
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)
                .mynahProse()
                .padding(.top, s2)

            ScrollView {
                VStack(alignment: .leading, spacing: s6) {
                    MynahCard {
                        VStack(alignment: .leading, spacing: s6) {
                            NumberedStepList(steps: instructions.steps)
                            MynahButton("Get \(BrainSetupPlanner.indefiniteArticle(for: instructions.providerName)) \(instructions.providerName) key", kind: .secondary) {
                                NSWorkspace.shared.open(instructions.keyPageURL)
                            }
                        }
                    }
                    KeyField(
                        label: "\(instructions.providerName) key",
                        text: $key,
                        state: fieldState,
                        onSubmit: check
                    )
                }
                .padding(.vertical, s6)
            }
            .scrollBounceBehavior(.basedOnSize)

            ActionRow(quietTitle: "Cancel", quietAction: { onClose(didAccept) }) {
                MynahButton(
                    didAccept ? "Done" : "Check this key",
                    isEnabled: didAccept || (!isChecking && !normalisedKey.isEmpty),
                    isDefault: true
                ) {
                    if didAccept { onClose(true) } else { check() }
                }
            }
            .padding(.top, s5)
        }
        .padding(s8)
        .frame(width: 620, height: 660)
        .background(Palette.surface.overlay)
        .mynahAnimation(Motion.snap, value: fieldState)
        // Escape is Cancel. A key that verified is already saved, so leaving
        // this way never loses one.
        .onExitCommand { onClose(didAccept) }
    }

    private var normalisedKey: String { APIKeyOnboarding.normalise(key) }

    private var fieldState: KeyFieldState {
        if isChecking { return .checking("Checking this key with \(instructions.providerName)…") }
        if let verdict {
            return verdict.isUsable
                ? .accepted(verdict.spokenDescription)
                : .rejected(verdict.spokenDescription)
        }
        if !normalisedKey.isEmpty,
           let problem = APIKeyOnboarding.shapeProblem(of: normalisedKey, expecting: provider) {
            return .shapeProblem(problem.spokenDescription)
        }
        return .idle(helper: instructions.looksLikeHint)
    }

    private func check() {
        guard !isChecking, !normalisedKey.isEmpty else { return }
        let candidate = normalisedKey
        verdict = nil
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let backend = try BrainFactory.makeBackend(for: option, apiKey: candidate)
                let result = await BrainKeyValidator().validate(backend)
                verdict = result
                guard result.isUsable else { return }
                try KeyStorage.save(candidate, forProvider: provider)
                didAccept = true
            } catch {
                // The owner pasted exactly what they were asked for; whatever
                // went wrong here is ours. The detail goes to the log.
                settingsLog.error("key sheet failed: \(String(describing: error))")
                verdict = .unusable("Mynah couldn't save that key. Quit Mynah and open it again.")
            }
        }
    }
}

/// Choosing which model does the thinking, without walking the whole of setup.
///
/// **It verifies rather than accepting.** A model name is a string the provider
/// either serves or does not, and the failure mode of a wrong one is not an
/// error dialog — it is Mynah going quiet the next time the owner asks it
/// something, hours later, with nothing on screen connecting the two. So this
/// does what `recheckKey` does: builds the real backend with the candidate name
/// and asks it a real question. The same machinery that catches a key which has
/// run out of credit catches a model that does not exist.
///
/// **Local runtimes only.** It used to have a second mode — a free-text field
/// for API providers — and that mode is gone, because the owner no longer names
/// cloud models. Mynah picks those; see `CloudBrainModelCatalog` and
/// `docs/MODEL-CHOICES.md`.
///
/// What is left is a list of what this Mac actually has, and that is a different
/// kind of choice rather than a survivor of the old one. A cloud model name is a
/// lookup against a catalogue that changes without telling anyone; a model the
/// owner pulled onto their own disk is neither unfamiliar nor liable to vanish.
/// The verification stays regardless — a local model that is installed but will
/// not drive tools fails here rather than mid-answer.
private struct BrainModelSheet: View {
    let option: BrainSetupOption
    /// Model names the local runtime actually has. Never empty: the row that
    /// opens this sheet is hidden when there is nothing to choose between, so
    /// "a sheet with no options" is unreachable rather than handled.
    let installed: [String]
    /// The option to save, or `nil` when the owner backed out.
    let onClose: (BrainSetupOption?) -> Void

    @State private var name: String
    @State private var verdict: BrainKeyValidator.Verdict?
    @State private var isChecking = false

    init(option: BrainSetupOption, installed: [String], onClose: @escaping (BrainSetupOption?) -> Void) {
        self.option = option
        self.installed = installed
        self.onClose = onClose
        _name = State(initialValue: option.modelName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The model Mynah thinks with")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)
                .mynahProse()
                .padding(.top, s2)

            ScrollView {
                VStack(alignment: .leading, spacing: s5) {
                    list
                    resultLine
                }
                .padding(.vertical, s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            ActionRow(quietTitle: "Cancel", quietAction: { onClose(nil) }) {
                MynahButton(
                    "Use this model",
                    isEnabled: !isChecking && !trimmed.isEmpty && trimmed != option.modelName,
                    isDefault: true,
                    action: check
                )
            }
            .padding(.top, s5)
        }
        .padding(s8)
        .frame(width: 620, height: 560)
        .background(Palette.surface.overlay)
        .mynahAnimation(Motion.snap, value: verdict)
        // Escape is Cancel. Nothing here is saved until it verifies.
        .onExitCommand { onClose(nil) }
    }

    private var subtitle: String {
        "These are the models installed on this Mac. Mynah asks the one you pick a real "
            + "question before keeping it, so one that can't drive its tools is caught here "
            + "rather than mid-answer."
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(installed.enumerated()), id: \.element) { index, candidate in
                if index > 0 { MynahDivider() }
                Button { name = candidate } label: {
                    HStack(spacing: s3) {
                        StatusDot(candidate == trimmed ? .accent : .neutral)
                        Text(candidate).mynahFont(.mono).foregroundStyle(Palette.ink.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, s3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .mynahGroupCard()
    }

    @ViewBuilder
    private var resultLine: some View {
        if isChecking {
            HStack(spacing: s3) {
                ProgressView().controlSize(.small).tint(Palette.accent.fill)
                Text("Asking \(trimmed) a question…")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
            }
        } else if let verdict {
            Text(verdict.spokenDescription)
                .mynahFont(.body)
                .foregroundStyle(verdict.isUsable ? Palette.state.good : Palette.state.critical)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func check() {
        guard !isChecking, !trimmed.isEmpty else { return }
        var candidate = option
        candidate.modelName = trimmed
        verdict = nil
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let backend = try BrainFactory.makeBackend(
                    for: candidate,
                    apiKey: candidate.keyProviderIdentifier.flatMap(KeyStorage.key(forProvider:))
                )
                let result = await BrainKeyValidator().validate(backend)
                verdict = result
                guard result.isUsable else { return }
                onClose(candidate)
            } catch {
                settingsLog.error("model change failed: \(String(describing: error))")
                verdict = .unusable("Mynah couldn't set that model up. Check the name and try again.")
            }
        }
    }
}

private let settingsLog = MynahLog(category: "settings")

// MARK: - Previews

/// A phone link that reports a linked, reachable phone — and, in the second
/// preview, one that can actually be unlinked, so the button that ships the day
/// the engine grows that ability can be seen now.
private struct PreviewPhoneLink: PhoneLinking {
    var status: PhoneStatus
    var canUnlink: Bool = false
    func unlink() async throws {}
}

/// Builds a throwaway defaults suite, model and `AppModel` in its own
/// initialiser, so the preview shows the real screen driven by real stores
/// rather than a mock of it — and so opening a preview never rewrites the app's
/// settings on this machine.
private struct SettingsPreviewHost: View {
    private let model: SettingsModel
    private let app: AppModel
    private let tab: SettingsTab

    @MainActor
    init(brainRecorded: Bool, phone: PreviewPhoneLink, tab: SettingsTab = .words) {
        self.tab = tab
        let defaults = UserDefaults(suiteName: "mynah.settings.preview.\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "mynah.setupComplete")
        if brainRecorded {
            BrainChoiceStore.record(
                BrainSetupOption(
                    id: .fullyLocal,
                    label: "Fully on this Mac",
                    summary: "Runs here.",
                    requirement: .download,
                    keepsWordsOnDevice: true,
                    availability: .available,
                    tier: .fullyLocal,
                    backendIdentifier: "ollama",
                    modelName: "qwen3.5:4b"
                ),
                defaults: defaults
            )
        }
        // A throwaway preferences file, with the check turned off in it before
        // the screen is built. Opening a design canvas must not rewrite the
        // owner's real preference, and it certainly must not send a request to
        // GitHub from somebody's Xcode.
        let updates = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah.settings.preview.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("update-preferences.json", isDirectory: false)
        UpdatePreferences.amend(at: updates) { $0.checksForUpdates = false }

        self.model = SettingsModel(defaults: defaults, updatePreferences: updates, phoneLink: phone)
        self.app = AppModel(defaults: defaults)
    }

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
    }

    private var pane: some View {
        SettingsView(model: model, openOn: tab).environment(app)
    }
}

private extension PreviewPhoneLink {
    static let linked = PreviewPhoneLink(
        status: PhoneStatus(
            isReachable: true,
            linkedNumber: SignalSenderAllowlist.redact("+60123456789"),
            socketPath: "/Users/owner/.local/share/signal-cli/daemon.socket"
        )
    )
}

#Preview("Settings — Your words") {
    SettingsPreviewHost(brainRecorded: true, phone: .linked)
        .frame(width: 1440, height: 900)
}

#Preview("Settings — Voice") {
    SettingsPreviewHost(brainRecorded: true, phone: .linked, tab: .voice)
        .frame(width: 1440, height: 900)
}

#Preview("Settings — General") {
    SettingsPreviewHost(brainRecorded: true, phone: .linked, tab: .general)
        .frame(width: 1440, height: 900)
}

#Preview("Settings — About") {
    SettingsPreviewHost(brainRecorded: true, phone: .linked, tab: .about)
        .frame(width: 1440, height: 900)
}

/// The state the card idiom is easiest to get wrong in: no recorded brain, so
/// the group above is a banner with nothing under it.
#Preview("Settings — nothing recorded") {
    SettingsPreviewHost(brainRecorded: false, phone: PreviewPhoneLink(status: .unknown))
        .frame(width: 1440, height: 900)
}
