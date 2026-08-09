import SageVoiceCore
import SwiftUI

// MARK: - The claims this destination is made of

/// The rest of the registry, added from the file that renders them.
///
/// An extension rather than more members in `SettingsView.swift`, because that
/// file belongs to somebody else today and a claim registry that can only be
/// added to by editing one busy file is a registry people will route around.
/// Same type, same guarantee: `PrivacyClaimTests` asserts every member reaches a
/// screen, and this page is composed from these rather than repeating them, so a
/// sentence cannot quietly leave the product without leaving here first.
///
/// **The wording is deliberately unchanged from the rows these came from.** This
/// destination is a rearrangement, not a rewrite: an owner who has read these
/// sentences in Settings should recognise them, and any improvement to them is a
/// separate decision made on purpose rather than a side effect of moving them.
extension PrivacyClaim {

    /// **Two surfaces, two answers, and they can drift apart.**
    ///
    /// This started as one row reading the window's recorded brain choice for
    /// both. The correction is structural rather than a bug sighting, and the
    /// distinction is worth keeping straight because I first wrote it down the
    /// other way round: I read `launchctl`, saw the appliance on
    /// `--provider ollama --model qwen3.5:4b`, and asserted the window was on an
    /// API brain without looking. `chrome` checked the plist —
    /// `mynah.brain.selectedOption` is `local.ollama`, the same model — so on
    /// this Mac the two agree and the single row would have told the truth.
    ///
    /// The reason for two rows is that nothing *makes* them agree. The daemon
    /// builds its backend from its launch flags and never consults
    /// `BrainSelectionStore`; `SettingsView` says so in as many words. And the
    /// gap widened today: a reconcile that cannot read its configuration now
    /// deliberately changes nothing rather than tearing the appliance down,
    /// which was the right call — it was uninstalling the owner's phone bridge —
    /// but it means a model changed in this window updates the store while the
    /// running appliance keeps the model it was started with until the next
    /// successful reconcile.
    ///
    /// So the phone is asked about the appliance's published status, the window
    /// is asked about the window's own choice, and neither speaks for the other.
    /// A privacy page naming the wrong destination is the worst error available
    /// on it, and it costs one extra row to make that unreachable.
    static func thinkingOnThePhone(model: String?, staysOnDevice: Bool) -> String {
        guard let model else {
            return "Mynah hasn't answered your phone yet, so it hasn't said which brain it uses."
        }
        return staysOnDevice
            ? "Answered by \(model), which runs on this Mac. Nothing you say from your phone "
                + "goes anywhere else to be thought about."
            : "What you say goes to \(model) so it can work out an answer. That is the one "
                + "thing this product cannot do without."
    }

    /// The window's own turns, which is a different backend from the one
    /// answering the phone and may go somewhere else entirely.
    static func thinkingInThisWindow(destination: String?, staysOnDevice: Bool) -> String {
        guard let destination else {
            return "Mynah hasn't recorded where this window sends your words to think."
        }
        return staysOnDevice
            ? "Answered by \(destination), which runs on this Mac."
            : "What you type or say here goes to \(destination) so it can work out an answer."
    }

    static let recordings = "They are turned into words on this Mac and never sent anywhere."

    static let memories = "Kept on this Mac, in a folder only you can read."

    static let webSearch = "When a question needs the internet, the words Mynah searches for go "
        + "to a search engine. The rest of what you said does not."

    /// Calling, stated as what leaves rather than as a feature.
    ///
    /// Every clause is checked against the code rather than the description of
    /// it. Recognition and synthesis happen here (`CallTurnServer`: "recognition,
    /// the model, synthesis — happens here"). The relay serves the page and
    /// carries the offer and the answer, and `CallHost` is explicit that it "is
    /// not in the call" — on a shared network "the audio crosses the room
    /// without touching it".
    ///
    /// **What is deliberately absent: any claim about what happens when the
    /// phone and this Mac cannot reach each other directly.** The ICE
    /// configuration is not in this repository — it is served with the page from
    /// the relay — so this app cannot see whether media ever falls back through
    /// one, and a reassurance nobody here can verify is exactly the kind this
    /// page must not make.
    static let calling = "Your side of a call is turned into words on this Mac, and Mynah's "
        + "answer is spoken here too. The link you tap is served by a relay, which passes the "
        + "two ends' details along and is not in the call itself."

    /// The transcript is a second copy of a conversation, in a place the owner
    /// may not be thinking about, and it is switchable — so it is named here and
    /// the switch is named with it.
    static let callTranscript = "If you have transcripts turned on, what was said in a call is "
        + "posted back into your chat when it ends."

    /// The page's opening, and the reason it is a destination rather than a
    /// section. Composed from nothing — it is the frame the claims sit in.
    static let openingStatement = "Almost everything Mynah does happens on this Mac. These are "
        + "the exceptions, and what each one tells somebody else."
}

// MARK: - Screen

/// What leaves this Mac.
///
/// Its own destination rather than a group inside Settings, because these are
/// not settings: there is nothing here to change, and the one thing that can be
/// changed — the update check — is named with its switch rather than duplicated
/// as a control. Settings answers "how is this set up"; this answers "what does
/// it tell anyone", which is the question the product exists to have a good
/// answer to.
///
/// **It is deliberately not styled as documentation.** The facts on this page
/// are the product's argument, and a page of grey paragraphs behind a
/// disclosure would be the same demotion that moving them out of Settings was
/// meant to undo. So: a real heading, one statement, and then the same rows the
/// owner already recognises, each with the badge that says where that thing
/// goes.
struct PrivacyView: View {

    /// Lets the memories row go where it points. Optional so the pane can be
    /// previewed and tested without a shell around it.
    var onOpenSection: ((MainSection) -> Void)?

    /// Read once when the pane appears rather than observed: none of this
    /// changes while somebody is reading it, and a live-updating privacy page
    /// would redraw under the owner for no reason they could see.
    @State private var brain: BrainChoice?
    /// What the *appliance* publishes about itself, which is the only honest
    /// source for what leaves when the owner speaks to their phone.
    @State private var appliance: ApplianceStatus?
    @State private var checksForUpdates = UpdatePreferences.load().checksForUpdates
    /// Read on appear like the update switch, and for the same reason: this
    /// screen reports state it does not own, and the owner may have changed it
    /// on the Settings screen a moment ago.
    @State private var checksOnThings = ProactivePreferences.load().isOn
    @State private var isChecking = false
    /// What the last press found, in one sentence. Nil until asked.
    @State private var updateReport: String?
    @State private var sendsCallTranscript = CallPreferences.load().transcript

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading
                claims.padding(.top, s7)
                closing.padding(.top, s6)
            }
            .frame(maxWidth: MynahWidth.settings, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, s8)
            .padding(.top, s7)
            .padding(.bottom, s9)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.surface.canvas)
        .task {
            brain = BrainChoiceStore.current()
            appliance = ApplianceStatus.current()
            checksForUpdates = UpdatePreferences.load().checksForUpdates
            checksOnThings = ProactivePreferences.load().isOn
            sendsCallTranscript = CallPreferences.load().transcript
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: s4) {
            Text("What leaves this Mac")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .accessibilityAddTraits(.isHeader)
            Text(PrivacyClaim.openingStatement)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The list

    /// One row per thing that can leave, each with the badge that says where it
    /// goes. Ordered by how often it happens rather than by severity: the first
    /// two are every single time the owner speaks, and the last is every fifteen
    /// minutes whether they speak or not.
    private var claims: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Every time you ask something") {
                // The phone first, because that is the appliance: it answers
                // when nobody is at the Mac, and it is the surface the owner
                // uses most. Its brain is whatever the daemon was launched
                // with, which is not necessarily what this window is set to.
                PrivacyRow(
                    "When you ask from your phone",
                    detail: PrivacyClaim.thinkingOnThePhone(
                        model: appliance?.model,
                        staysOnDevice: appliance?.keepsWordsOnDevice ?? false
                    )
                ) {
                    StatusPill(
                        appliance.map { $0.keepsWordsOnDevice ? "Stays here" : $0.model }
                            ?? "Not answering yet",
                        // Neutral rather than caution when words leave. The pill
                        // already names the company, and a name is a more
                        // specific signal than a hue that also means paused.
                        // Only the *leaving* side moved — `good` is
                        // single-purpose and stays. See `Palette.state`.
                        tone: appliance.map { $0.keepsWordsOnDevice ? .good : .neutral } ?? .neutral
                    )
                }
                MynahDivider()
                PrivacyRow(
                    "When you ask in this window",
                    detail: PrivacyClaim.thinkingInThisWindow(
                        destination: brain?.destination,
                        staysOnDevice: brain?.keepsWordsOnDevice ?? false
                    )
                ) {
                    StatusPill(
                        brain?.destination ?? "Not chosen",
                        tone: brain.map { $0.keepsWordsOnDevice ? .good : .neutral } ?? .neutral
                    )
                }
                MynahDivider()
                PrivacyRow("Your recordings", detail: PrivacyClaim.recordings) {
                    StatusPill("Stays here", tone: .good)
                }
                MynahDivider()
                PrivacyRow("What Mynah remembers", detail: PrivacyClaim.memories) {
                    // A link rather than a control: it changes nothing, it goes
                    // somewhere. The row is still a statement of fact.
                    if let onOpenSection {
                        MynahButton("See it", kind: .secondary) { onOpenSection(.memories) }
                    } else {
                        StatusPill("Stays here", tone: .good)
                    }
                }
            }

            SettingsGroup("Sometimes") {
                PrivacyRow("Looking something up on the web", detail: PrivacyClaim.webSearch) {
                    StatusPill("Only when needed", tone: .neutral)
                }
                MynahDivider()
                PrivacyRow("Talking to it out loud", detail: PrivacyClaim.calling) {
                    StatusPill("Stays here", tone: .good)
                }
                MynahDivider()
                PrivacyRow("After a call", detail: PrivacyClaim.callTranscript) {
                    StatusPill(
                        sendsCallTranscript ? "Posted to chat" : "Turned off",
                        tone: sendsCallTranscript ? .neutral : .good
                    )
                }
            }

            SettingsGroup("Without you asking") {
                // The only thing on this page the owner did not cause by
                // speaking, which is exactly why leaving it off would be the
                // worst omission available.
                PrivacyRow("Checking for a newer Mynah", detail: PrivacyClaim.aboutCaption) {
                    HStack(spacing: s4) {
                        StatusPill(
                            checksForUpdates ? "Every 15 minutes" : "Turned off",
                            tone: checksForUpdates ? .neutral : .good
                        )
                        // The one row on this page that describes something
                        // happening on a timer, so it is the one place where
                        // "not now, later" is a real answer to a real question.
                        // A button that asks immediately turns waiting a day
                        // into waiting a second.
                        //
                        // Offered even when the daily check is off, and that is
                        // deliberate rather than an oversight: turning the timer
                        // off is a decision about what Mynah does unprompted,
                        // and pressing this is the owner asking. Those are not
                        // the same thing, and refusing to look because the
                        // automatic check is disabled would be the app deciding
                        // it knows better than the person clicking.
                        if isChecking {
                            ProgressView().controlSize(.small).tint(Palette.accent.fill)
                        } else {
                            // `.secondary`, matching "See it" two rows up.
                            //
                            // `.quiet` is the style for "Not now" and "Skip" —
                            // it draws no border, so beside a filled status pill
                            // this read as a second label rather than something
                            // to press. The two pressable things on this page
                            // should look alike.
                            MynahButton("Check now", kind: .secondary) {
                                Task { await checkNow() }
                            }
                        }
                    }
                }
                if let updateReport {
                    PrivacyRow("", detail: updateReport) { EmptyView() }
                }
                MynahDivider()
                // The other one, and the only thing Mynah does that puts a
                // message on the owner's phone by itself. Listed here whether it
                // is on or off, because a screen that only mentions a feature
                // once it is switched on cannot be read as a complete list.
                PrivacyRow("Checking on things by itself", detail: PrivacyClaim.checkingOnThings) {
                    StatusPill(
                        checksOnThings ? "On" : "Turned off",
                        tone: checksOnThings ? .neutral : .good
                    )
                }
            }
        }
    }

    /// Asks GitHub now, and says what came back.
    ///
    /// `force: true` because the daily limit exists to stop the appliance
    /// pestering GitHub unprompted, and this is not unprompted — somebody
    /// pressed a button. Without it the first press of the day answers and
    /// every press after it says "hasn't managed to check yet", which reads as
    /// a broken control rather than a rate limit.
    private func checkNow() async {
        isChecking = true
        defer { isChecking = false }
        let answer = await UpdateCheck(preferencesFile: UpdatePreferences.defaultFileURL())
            .run(force: true)
        switch answer {
        case .upToDate:
            updateReport = "You are on the newest version."
        case .newer(let version, let page):
            updateReport = "Version \(version) is available — \(page.absoluteString)"
        case .cannotTell(let problem):
            // The problem type already writes one sentence for the owner, and
            // every one of them says "could not tell" rather than "up to date".
            updateReport = problem.spokenDescription
        }
    }

    /// Where to go to change the one changeable thing, said once at the end
    /// rather than repeated on the row.
    private var closing: some View {
        Text("Nothing on this page is a setting. The update check is the only one of these you "
            + "can turn off, and its switch is in Settings, under About.")
            .mynahFont(.callout)
            .foregroundStyle(Palette.ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row on this page: a fact, its explanation, and a badge saying where it
/// goes.
///
/// A thin wrapper over `SettingsRow` rather than a new component — the rows are
/// the ones the owner already recognises from Settings, and reproducing their
/// look by hand is how two screens that should be identical drift apart. The
/// wrapper exists so this page can be read as a list of claims rather than a
/// list of settings rows.
private struct PrivacyRow<Badge: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var badge: Badge

    init(_ title: String, detail: String, @ViewBuilder badge: () -> Badge) {
        self.title = title
        self.detail = detail
        self.badge = badge()
    }

    var body: some View {
        SettingsRow(title, detail: detail) { badge }
    }
}

// MARK: - Previews

#Preview("Privacy — an API brain") {
    PrivacyPreviewPair(brain: nil)
        .frame(width: 1180, height: 900)
}

private struct PrivacyPreviewPair: View {
    let brain: BrainChoice?

    var body: some View {
        HStack(spacing: 0) {
            PrivacyView().environment(\.colorScheme, .light)
            PrivacyView().environment(\.colorScheme, .dark)
        }
    }
}
