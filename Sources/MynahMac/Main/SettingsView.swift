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
/// There is deliberately no microphone picker here. Nothing in this product
/// records from the Mac — verified: `SageVoiceCore` contains no `AVCaptureDevice`,
/// no `AVAudioEngine` and no recorder. The owner speaks into their phone; the
/// voice note arrives over the messaging bridge and is transcribed here. A
/// microphone setting would be a control for a thing that does not happen.
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

    private let log = Logger(subsystem: "com.sage.mynah", category: "settings")
    private let defaults: UserDefaults
    private let phoneLink: any PhoneLinking

    private(set) var probe: EnvironmentProbeResult?
    private(set) var isProbing = false
    private(set) var brain: BrainChoice?
    private(set) var speech: SpeechFacts
    private(set) var phone: PhoneStatus
    private(set) var checkState: CheckState = .idle

    init(
        defaults: UserDefaults = .standard,
        phoneLink: any PhoneLinking = SignalPhoneLink()
    ) {
        self.defaults = defaults
        self.phoneLink = phoneLink
        self.brain = BrainChoiceStore.current(defaults: defaults)
        self.speech = SpeechFacts.detect()
        self.phone = phoneLink.status
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
            log.error("re-check failed: \(String(describing: error), privacy: .public)")
            checkState = .bad("Mynah couldn't set that brain up. Set it up again.")
        }
    }

    func unlinkPhone() async {
        do {
            try await phoneLink.unlink()
            phone = phoneLink.status
        } catch {
            log.error("unlink failed: \(String(describing: error), privacy: .public)")
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

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var nodeVersion: String? {
        guard let path = probe?.sage.executablePath else { return nil }
        guard let bundle = SageNodeLocator.appBundle(containing: URL(fileURLWithPath: path)) else {
            return nil
        }
        return SageNodeLocator.bundleVersion(at: bundle)
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
    @State private var isAdvancedOpen = false
    @State private var didCopyDiagnostics = false
    /// Which deferred step is being finished right now, if any. The sheets are
    /// the whole point of the "Unfinished" list: a row that names a task and
    /// then restarts the wizard is a five-screen detour to reach the one screen
    /// the owner asked for.
    @State private var isLinkingPhone = false
    @State private var isPastingKey = false

    /// Seeded from disk rather than defaulted, so the switch shows what the
    /// daemon will actually do rather than what this app assumes.
    @State private var voiceNotes = ReplyPreferences().style().usesVoiceNotes

    private static let log = Logger(subsystem: "local.sage.voicebridge", category: "settings")

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
    @MainActor
    init(onOpenSection: @escaping (MainSection) -> Void = { _ in }, model: SettingsModel? = nil) {
        self.onOpenSection = onOpenSection
        _model = State(initialValue: model ?? SettingsModel())
    }

    var body: some View {
        @Bindable var app = app
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                unfinished(app: app)
                brainSection
                voiceSection
                phoneSection
                privacySection
                answeringSection(app: app)
                appearanceSection(app: app)
                advancedSection
            }
            .frame(maxWidth: MynahWidth.settings, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, s8)
            .padding(.top, s7)
            .padding(.bottom, s9)
        }
        .background(Palette.surface.canvas)
        .onAppear { model.refresh() }
        .task { await model.probeIfNeeded() }
        .sheet(isPresented: $isLinkingPhone) {
            PhoneLinkSheet {
                app.resolveDeferredStep(id: AppModel.DeferredStep.phoneLinkID)
                model.refresh()
                isLinkingPhone = false
            } onClose: {
                model.refresh()
                isLinkingPhone = false
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
            SectionHeader("Unfinished")
            ForEach(app.deferredSetupSteps) { step in
                SettingsRow(step.title, detail: step.detail) {
                    MynahButton("Set this up", kind: .secondary) { open(step, app: app) }
                }
                MynahDivider()
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

    // MARK: Brain

    private var brainSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Where your words go")

            if let brain = model.brain {
                SettingsRow("Mynah thinks with", detail: brain.label) {
                    StatusPill(destinationTitle(brain), tone: destinationTone(brain))
                }
                // One source of truth for "can Mynah think right now": the same
                // authored sentence Home is showing, on the screen the owner
                // came to in order to fix it.
                if let trouble = conversation.trouble {
                    InlineBanner(
                        tone: trouble.isSevere ? .critical : .caution,
                        headline: trouble.headline,
                        explanation: trouble.explanation
                    )
                    .padding(.bottom, s4)
                }
                MynahDivider()
                SettingsRow(
                    "Change where your words go",
                    detail: "Runs setup again so you can pick somewhere else. "
                        + "What Mynah already remembers stays where it is."
                ) {
                    MynahButton("Change", kind: .secondary) { app.restartSetup() }
                }
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
            } else {
                InlineBanner(
                    tone: .caution,
                    headline: "Mynah hasn't recorded where your words go.",
                    explanation: "Set it up again and it will remember your answer this time.",
                    actionTitle: "Set Mynah up again",
                    action: { app.restartSetup() }
                )
                if !model.providersWithKeys.isEmpty {
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
    }

    /// The stored destination, unless the conversation says nothing is getting
    /// through — in which case the pill says so rather than naming a company
    /// that is receiving nothing.
    private func destinationTitle(_ brain: BrainChoice) -> String {
        conversation.trouble == nil ? brain.destination : "Not answering"
    }

    private func destinationTone(_ brain: BrainChoice) -> MynahTone {
        guard conversation.trouble == nil else { return .caution }
        return brain.keepsWordsOnDevice ? .good : .caution
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
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Voice")

            SettingsRow(
                "You speak into",
                detail: "Your phone. Mynah never listens through this Mac's microphone — "
                    + "it only hears the voice notes you send it."
            ) {
                Text("Your phone").mynahFont(.bodyEmphasis).foregroundStyle(Palette.ink.secondary)
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
            SettingsRow(
                "Answer with voice notes",
                detail: voiceNotes
                    ? "Mynah speaks its answers, so it keeps them short — a couple of sentences, "
                        + "no lists. Long answers are unlistenable."
                    : "Mynah writes its answers, so it gives you the whole thing — a line per "
                        + "item, and links you can tap."
            ) {
                Toggle("", isOn: $voiceNotes)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: voiceNotes) { _, isOn in
                        do {
                            try ReplyPreferences().save(voiceNotes: isOn)
                        } catch {
                            // Revert rather than show a switch that lies about
                            // what the daemon will do on its next start.
                            Self.log.error("could not save reply preference: \(error)")
                            voiceNotes = !isOn
                        }
                    }
            }
        }
    }

    // MARK: Phone

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your phone")

            SettingsRow(
                "Mynah answers",
                detail: model.phone.linkedNumber == nil
                    ? "Mynah hasn't been told which phone to answer."
                    : "Only this phone. Voice notes from anyone else are ignored."
            ) {
                if let number = model.phone.linkedNumber {
                    Text(number).mynahFont(.mono).foregroundStyle(Palette.ink.secondary)
                } else {
                    StatusPill("Not set", tone: .caution)
                }
            }
            MynahDivider()

            SettingsRow(
                "Can Mynah reach it",
                detail: model.phone.isReachable
                    ? "The link between this Mac and your phone is up."
                    : "Open Signal on this Mac once and leave it running, then come back here."
            ) {
                StatusPill(
                    model.phone.isReachable ? "Connected" : "Not connected",
                    tone: model.phone.isReachable ? .good : .caution
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
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("What leaves this Mac")

            SettingsRow(
                "What you say, while Mynah thinks",
                detail: leavesForThinking
            ) {
                StatusPill(
                    model.brain?.destination ?? "Not chosen",
                    tone: model.brain.map { $0.keepsWordsOnDevice ? .good : .caution } ?? .neutral
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
                StatusPill("Only when needed", tone: .caution)
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
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Answering")
            // Names the panel, because the panel is the visible half of this
            // setting. The row used to promise something with no evidence on
            // screen: the window closed, one menu-bar glyph appeared, and the
            // owner had no way to tell whether anything was still listening.
            SettingsRow(
                "Keep answering when this window is closed",
                detail: "Your phone can still reach Mynah with the window shut, and a small panel "
                    + "stays on screen showing what it's doing."
            ) {
                Toggle("", isOn: $app.keepsAnsweringWhenClosed).labelsHidden().mynahToggle()
            }
            MynahDivider()
            SettingsRow("Pause answering", detail: "Mynah stays open but stops replying.") {
                Toggle("", isOn: $app.isPaused).labelsHidden().mynahToggle()
            }
        }
    }

    private func appearanceSection(app: AppModel) -> some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Appearance")
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
                    Text("Advanced")
                        .mynahFont(.eyebrow)
                        .foregroundStyle(Palette.ink.secondary)
                    Image(systemName: "chevron.right")
                        .mynahIcon(.inline)
                        .foregroundStyle(Palette.ink.tertiary)
                        .rotationEffect(.degrees(isAdvancedOpen ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, s4)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel("Advanced")
            .accessibilityValue(isAdvancedOpen ? "Open" : "Closed")

            if isAdvancedOpen { advancedRows }
        }
        .padding(.top, s7)
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
        .transition(.push(from: .top).combined(with: .opacity))
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
                settingsLog.error("key sheet failed: \(String(describing: error), privacy: .public)")
                verdict = .unusable("Mynah couldn't save that key. Quit Mynah and open it again.")
            }
        }
    }
}

private let settingsLog = Logger(subsystem: "com.sage.mynah", category: "settings")

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

    @MainActor
    init(brainRecorded: Bool, phone: PreviewPhoneLink) {
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
        self.model = SettingsModel(defaults: defaults, phoneLink: phone)
        self.app = AppModel(defaults: defaults)
    }

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
    }

    private var pane: some View {
        SettingsView(model: model).environment(app)
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

#Preview("Settings — set up") {
    SettingsPreviewHost(brainRecorded: true, phone: .linked)
        .frame(width: 1440, height: 900)
}

#Preview("Settings — nothing recorded") {
    SettingsPreviewHost(brainRecorded: false, phone: PreviewPhoneLink(status: .unknown))
        .frame(width: 1440, height: 900)
}
