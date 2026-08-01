import Foundation
import Observation
import OSLog
import SageVoiceCore

// MARK: - Logging

/// Everything the owner must never read goes here: exception strings, tool
/// names, HTTP status codes, MCP stderr. `Exchange.Failure` carries the
/// authored sentence; this carries the truth.
private let conversationLog = MynahLog(category: "conversation")

// MARK: - One exchange

/// What the owner asked, and what came back.
///
/// A question and its answer are one value rather than two rows in a message
/// list, because the waiting state belongs exactly where the answer will land.
/// Splitting them means the thinking indicator has to be positioned by the view
/// and can drift away from the turn it belongs to.
struct Exchange: Identifiable, Equatable, Sendable {

    /// The authored sentence pair shown when a turn does not produce an answer.
    ///
    /// Never an exception string, never a status code. `explanation` always
    /// contains a verb the owner can perform — that is the whole contract.
    struct Failure: Equatable, Sendable {
        var headline: String
        var explanation: String
        /// Whether asking the identical thing again could plausibly work. A flag
        /// rather than a button title the view matches on: deriving behaviour by
        /// searching your own copy is how a wording change becomes a bug.
        var canRetry: Bool
        /// Set when the fix lives in Settings, and used as the shortcut's title.
        var settingsActionTitle: String?
        /// Stopping a turn on purpose is not a fault, and painting it red would
        /// teach the owner that their own button broke something.
        var isSevere: Bool

        init(
            headline: String,
            explanation: String,
            canRetry: Bool = false,
            settingsActionTitle: String? = nil,
            isSevere: Bool = false
        ) {
            self.headline = headline
            self.explanation = explanation
            self.canRetry = canRetry
            self.settingsActionTitle = settingsActionTitle
            self.isSevere = isSevere
        }

        static let stopped = Failure(
            headline: "Stopped.",
            explanation: "Mynah didn't finish that one. Ask it again whenever you like.",
            canRetry: true
        )
    }

    struct Answer: Equatable, Sendable {
        var text: String
        /// Wall clock for the whole turn. Shown so the owner learns what normal
        /// looks like, not so they can time it.
        var seconds: TimeInterval
        /// What Mynah did, already translated into the owner's words. Empty when
        /// it answered from what it already had.
        var activity: [String]
        /// Documents this turn wrote, drawn under the answer as something to
        /// open. The phone gets these as attachments; the window has no
        /// attachment channel, so it offers the file itself.
        var files: [URL] = []
    }

    enum Outcome: Equatable, Sendable {
        case thinking
        case answered(Answer)
        case failed(Failure)
    }

    let id: UUID
    var question: String
    /// Restamped on a retry, so the thinking line's timings stay honest.
    var askedAt: Date
    var outcome: Outcome

    init(id: UUID = UUID(), question: String, askedAt: Date = Date(), outcome: Outcome = .thinking) {
        self.id = id
        self.question = question
        self.askedAt = askedAt
        self.outcome = outcome
    }

    var isThinking: Bool { outcome == .thinking }
}

// MARK: - Tool activity, in the owner's words

/// Turns the tool names in a `ToolLoopTrace` into phrases a person would use.
///
/// A name with no phrase here is **dropped**, never shown. That is deliberate:
/// the catalogue is whatever the memory node happens to publish today, so a
/// fallback that printed the raw name would put `sage_pipe_result` in front of
/// the owner the first time the server grew a tool.
enum ToolActivity {

    private static let phrasebook: [String: String] = [
        "sage_recall": "Looked through what it remembers",
        "sage_list": "Looked through what it remembers",
        "sage_timeline": "Looked back over the last few days",
        "sage_remember": "Wrote that down",
        "sage_reflect": "Wrote that down",
        "sage_forget": "Forgot that",
        "sage_task": "Checked your list",
        "sage_backlog": "Checked your list",
        "sage_inbox": "Checked your messages",
        "sage_status": "Checked how it's doing",
        "sage_federation": "Checked your other machines",
        "sage_find_agent": "Asked one of your other helpers",
        "sage_pipe": "Asked one of your other helpers",
        "sage_pipe_result": "Asked one of your other helpers",
        "web_search": "Searched the web"
    ]

    /// Unique phrases in the order the tools actually ran. Two recalls in one
    /// turn are one phrase — the owner does not care that it looked twice.
    static func phrases(for toolNames: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in toolNames {
            guard let phrase = phrasebook[name], seen.insert(phrase).inserted else { continue }
            result.append(phrase)
        }
        return result
    }
}

// MARK: - The turn engine seam

/// One finished turn, reduced to what the screen and the next turn need.
struct TurnResult: Sendable {
    var reply: String
    var toolNames: [String]
    var seconds: TimeInterval
    /// The full message list `ToolLoop` produced. Never stored as-is — see
    /// `ConversationModel.conversationOnly(_:)`.
    var messages: [BrainMessage]

    /// Documents this turn wrote, for the screen to offer.
    ///
    /// The window has no attachment channel — that is the whole reason
    /// `NotesToolSource` takes a `Delivery` — so a PDF written here would
    /// otherwise be a file the owner is told about and cannot reach. *"if you
    /// send the same message in the app it would send back a clickable pdf that
    /// it has saved to its 'directory'."*
    var files: [URL] = []
}

/// Where a turn is actually run.
///
/// A protocol so the previews below drive the same code path the owner does
/// without a live memory node, a model, or a key. `ToolLoopTurnEngine` is the
/// only implementation that ships.
protocol TurnEngine: Sendable {
    /// Starts the memory node and fetches the catalogue. Separate from `run` so
    /// the health line can be honest before the owner has asked anything.
    func prepare() async throws
    func run(transcript: String, history: [BrainMessage]) async throws -> TurnResult
    /// Pays the prompt prefill while nobody is waiting. Optional: against a
    /// hosted model there is no local cache to warm and it would spend quota.
    func warmUp() async
    func shutDown() async
}

extension TurnEngine {
    func warmUp() async {}
    func shutDown() async {}
}

// MARK: - Voice input seam

/// Press-and-hold speech capture.
///
/// Deliberately a seam with no implementation in this file. Capturing the
/// microphone needs a bundled `NSMicrophoneUsageDescription` (without one macOS
/// terminates the process rather than prompting) and an on-device recogniser to
/// turn the recording into words — both of which belong to the install and
/// permissions surface, not to the conversation.
///
/// Until one is wired, `ConversationModel.canHoldToTalk` is false and the
/// hold-to-talk control is simply absent. A control that cannot lead anywhere
/// does not ship; the composer says where voice comes from today instead.
@MainActor
protocol VoiceCapture: AnyObject {
    /// 0…1, sampled by the model while recording to drive the level meter.
    var level: Double { get }
    func begin() async throws
    /// The words that were spoken. Returned rather than sent, so an
    /// ASR mishearing is something the owner sees before Mynah acts on it.
    func finish() async throws -> String
    func cancel()
}

// MARK: - Where the owner's words go

/// The brain the owner picked, persisted so the app can rebuild it at launch.
///
/// Stored as the whole `BrainSetupOption` because it is `Codable` and because
/// `BrainFactory` is keyed on it — re-deriving a backend from a bare identifier
/// string would be a second, drifting copy of that switch.
///
/// This never *chooses* anything. The only value that reaches `save(_:)` is one
/// the owner clicked, which is what keeps `BrainSetupSelection`'s internal
/// initialiser meaningful.
enum BrainSelectionStore {
    private static let storageKey = "mynah.brain.selectedOption"

    static func save(_ option: BrainSetupOption, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(option) else { return }
        defaults.set(data, forKey: storageKey)
        // Every save is also a fact worth keeping past the next switch — see
        // `LastBrainModelStore`. Recorded here because this is the one choke
        // point every brain change goes through, so a caller cannot forget.
        LastBrainModelStore.remember(option, defaults: defaults)
    }

    static func current(_ defaults: UserDefaults = .standard) -> BrainSetupOption? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(BrainSetupOption.self, from: data)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

// MARK: - The live engine

/// Drives `ToolLoop` over the owner's memory node, plus web search.
///
/// An actor rather than a lock-protected class: the catalogue, the handshake and
/// the ritual are all mutable state that a second turn must not race, and the
/// whole type is `await`-ed from one place anyway.
actor ToolLoopTurnEngine: TurnEngine {

    private let mcp: MCPClient
    private let loop: ToolLoop
    private let ritual: SageRitual
    private let localProvisioner: LocalBrainInstaller?
    private let notes: NotesToolSource
    private var catalogue: [MCPTool]?
    private var isPrepared = false

    init(backend: BrainBackend, memoryExecutable: URL, allowsWebSearch: Bool = true) {
        // The appliance's identity, not one of its own.
        //
        // This used childEnvironment(), which resolves a different key —
        // agent.key rather than appliance-agent.key — and a different key is a
        // different agent. The node was right to show two: "MYNAH (Mac App)"
        // beside "MYNAH (SAGE Voice Bridge Agent)", both with zero memories,
        // because nothing said through one was visible to the other.
        //
        // One appliance is one agent. The owner grants a domain to a thing they
        // installed once, and asking them to grant it twice — then wondering why
        // the window cannot recall what the phone was told — is a split brain
        // wearing two names.
        let identityEnvironment = MynahIdentity.applianceEnvironment()
        let memoryEnvironment = backend.identifier == "ollama"
            ? MynahIdentity.localSemanticEnvironment(identityEnvironment: identityEnvironment)
            : identityEnvironment
        let mcp = MCPClient(
            executableURL: memoryExecutable,
            arguments: ["mcp"],
            environment: memoryEnvironment
        )
        let notes = NotesToolSource()
        self.notes = notes
        var sources: [CompositeToolSource.Source] = [
            CompositeToolSource.Source(
                label: "memory",
                provider: mcp,
                isRequired: true,
                // Fails closed if the node ever renames its tools. Web search
                // always matches the allowlist, so without this expectation a
                // renamed memory catalogue would sail through leaving the model
                // holding one tool and no memory, looking perfectly healthy.
                expectedToolNames: ["sage_recall", "sage_remember"]
            ),
            // `.savedOnDisk` — the default, and load-bearing. Mynah has no
            // attachment channel, so the appliance's "the file is attached to
            // your reply" would be a lie here, and one the owner would only
            // discover by looking for a file that never arrived.
            //
            // Held rather than built inline, because the window offers what it
            // wrote as something to click — which means somebody has to ask it
            // afterwards what it wrote.
            CompositeToolSource.Source(
                label: "notes",
                provider: notes,
                isRequired: true,
                expectedToolNames: NotesToolSource.toolNames
            )
        ]
        if allowsWebSearch {
            sources.append(
                CompositeToolSource.Source(
                    label: "web",
                    provider: WebSearchToolSource(backends: WebSearchToolSource.defaultBackends()),
                    // The owner's phone is a long way from this Mac. "The
                    // internet lookup is down" must not read as "Mynah is down".
                    isRequired: false,
                    expectedToolNames: [WebSearchToolSource.toolName]
                )
            )
        }
        self.mcp = mcp
        self.loop = ToolLoop(backend: backend, mcp: CompositeToolSource(sources: sources))
        self.localProvisioner = backend.identifier == "ollama"
            ? LocalBrainInstaller(runtime: OllamaRuntimeInstaller.shared)
            : nil
        // The raw node, not the composed source: the boot ritual calls tools the
        // loop's allowlist deliberately withholds from the model.
        // Registered as the appliance, for the same reason it signs as it.
        // With a log sink, and that is not decoration. `SageRitual.log` defaults
        // to `{ _ in }`, this call site never passed one, and so every
        // "[sage] turn failed" the app produced went into a closure that threw
        // it away. The appliance recorded zero memories against its agent while
        // the Memories screen told the owner, in a confident sentence, that the
        // screen "fills up as you talk to it".
        //
        // A store that fails silently is worse than one that fails: the owner
        // cannot tell "nothing has happened yet" from "nothing has ever
        // worked", and neither can we — the reason it recorded nothing is not
        // recoverable from any log on the machine, because it was never
        // written down.
        self.ritual = SageRitual(
            tools: mcp,
            agentName: SageRitual.applianceAgentName,
            displayName: SageRitual.applianceDisplayName,
            log: { conversationLog.error("\($0)") }
        )
    }

    func prepare() async throws {
        guard !isPrepared else { return }
        if let localProvisioner {
            guard await localProvisioner.install() else {
                throw BrainBackendError.unreachable(
                    "the managed local runtime or one of its required models is not ready"
                )
            }
        }
        _ = try await mcp.start()
        let tools = try await loop.availableTools()
        catalogue = tools
        // The dictation vocabulary reads the owner's own memories through the
        // same MCP connection. Registered here rather than built here: the
        // store compiles it in the background and never on the path of a voice
        // note, and a refusal — which is what mask 30 returns today — is
        // indistinguishable from an empty corpus by design.
        await DictationProfileStore.shared.use(source: SageMemoryVocabularySource(tools: mcp).callAsFunction)
        // Before any warm-up, never after: the boot reply becomes part of the
        // system prompt, and warming a prompt no turn ever sends buys nothing.
        if await ritual.boot() != nil {
            let prompt = await ritual.systemPrompt(base: loop.systemPrompt)
            loop.setSystemPrompt(prompt)
        }
        isPrepared = true
    }

    /// Pays roughly 14 seconds of prefill now so the owner does not pay ~22 of
    /// it on their first question. Local models only — a hosted API keeps no
    /// cache to warm, so the same request would just spend the owner's quota.
    func warmUp() async {
        guard isPrepared, loop.backendIsLocal, let catalogue else { return }
        _ = await loop.warmUp(tools: catalogue)
    }

    func run(transcript: String, history: [BrainMessage]) async throws -> TurnResult {
        try await prepare()
        let started = Date()
        let result = try await loop.run(transcript: transcript, tools: catalogue, history: history)
        conversationLog.info("turn: \(result.trace.summary)")

        // After the reply and never before. The node starts refusing outside
        // tool calls once enough turns pile up unrecorded, and web search is an
        // outside call — skipping this surfaces days later as "search broke".
        // Unstructured on purpose: `Task {}` does not inherit cancellation, so
        // the owner pressing Stop on the *next* turn cannot skip this one's
        // housekeeping, and nobody waits on it either way.
        let reply = result.reply
        let usedTools = result.trace.toolNames
        Task { [ritual] in
            await ritual.recordTurn(transcript: transcript, reply: reply, usedTools: usedTools)
        }

        return TurnResult(
            reply: result.reply,
            toolNames: result.trace.toolNames,
            seconds: Date().timeIntervalSince(started),
            messages: result.messages,
            // Drained, not read: a document that rode along with a second answer
            // because nobody cleared the list is a confusing thing to chase.
            files: notes.drainWrittenNotes()
        )
    }

    func shutDown() async {
        mcp.stop()
        isPrepared = false
        catalogue = nil
    }
}

// MARK: - The conversation

/// Everything the talk screen shows, and the only thing that runs a turn.
@MainActor
@Observable
final class ConversationModel {

    /// The conversation outlives the pane.
    ///
    /// `MainShell` switches its detail pane with a `switch`, which destroys the
    /// previous branch — so a model owned by the view would erase what Mynah
    /// just said the moment the owner glanced at Settings.
    /// The one conversation.
    ///
    /// `voice:` is nil on a Mac with no local recogniser, which is what keeps
    /// `canHoldToTalk` false and the hold-to-talk control absent rather than
    /// present-and-failing. See `MicrophoneVoiceCapture.ifAvailable`.
    static let shared = ConversationModel(voice: MicrophoneVoiceCapture.ifAvailable())

    /// Matches the appliance. Each turn re-sends the whole history plus every
    /// tool schema, and prefill is the dominant cost, so history is the most
    /// expensive knob here rather than the cheapest.
    static let historyTurnLimit = 6

    /// Whether Mynah can answer at all, and what to say if it cannot.
    enum Readiness: Equatable, Sendable {
        case connecting
        /// `destination` is already phrased for the owner.
        /// `model` is the exact name the brain answers as, shown beside the
        /// company. Two facts, not one: "DeepSeek" says where the words go and
        /// says nothing about which of their models is answering.
        case ready(destination: String, model: String?, staysOnDevice: Bool)
        case blocked(Exchange.Failure)
    }

    /// The one line under the header. Not a dashboard.
    struct Health: Equatable, Sendable {
        var tone: MynahTone
        var title: String
        var detail: String?
        /// Where the words go, as a company or "This Mac".
        var provider: String?
        /// Which model answers.
        var model: String?
        /// Drives the pills' colour, and it is the app's existing rule rather
        /// than a new one: green means it stayed on this Mac, amber means it
        /// left. The Privacy screen has used exactly these two meanings from
        /// the start, so a cloud brain reads amber here for the same reason it
        /// does there.
        var staysOnDevice: Bool = false
    }

    private(set) var exchanges: [Exchange] = []
    private(set) var readiness: Readiness = .connecting
    /// Set once the owner has seen one answer, so the "about twenty seconds"
    /// expectation is stated before the wait and never again.
    private(set) var hasEverAnswered = false
    private(set) var isRecording = false
    private(set) var micLevel: Double = 0

    /// What the owner has typed but not sent. Survives a pane switch with the
    /// rest of the conversation.
    var draft: String = ""

    private var engine: TurnEngine?
    /// Which brain `engine` was built from. `nil` for an injected engine, which
    /// is what previews and tests use — they have no stored choice to drift from.
    private var connectedOptionID: BrainSetupOptionID?
    private let voice: VoiceCapture?

    /// What this window said before the turns currently on screen.
    ///
    /// **Injected, because this used to not exist and that was the bug.** The
    /// window kept a `history` array that started empty and only ever grew from
    /// turns typed here, while a second record was drawn on the same screen
    /// above them. So the owner read one conversation and Mynah answered from
    /// another: he asked for a recipe's steps directly beneath the recipe and
    /// was asked which recipe he meant.
    ///
    /// The source has changed and the seam has not. It used to be the phone's
    /// thread, read from the daemon's file; it is now this window's own record,
    /// read from disk at launch. One conversation per surface, and each answers
    /// from the one it is showing — see `WindowConversation` for why the two
    /// were separated and what carries continuity between them instead.
    ///
    /// A closure rather than a reference, because `ConversationModel` must not
    /// know what a `WindowConversation` is — and because previews and tests need
    /// a window with no record behind it, which is what the default gives them.
    var priorContext: @MainActor () -> [BrainMessage] = { [] }

    /// Where a finished turn goes to be remembered across a relaunch.
    ///
    /// Injected for the same reason as `priorContext`, and paired with it: the
    /// closure that reads the record and the closure that writes it belong to
    /// whoever owns the record. A window with neither — a preview, a test — is a
    /// conversation that lasts as long as it is on screen, which is the right
    /// behaviour for both.
    var recordTurn: @MainActor (
        _ question: String,
        _ answer: String,
        _ askedAt: Date,
        _ answeredAt: Date,
        _ files: [URL]
    ) -> Void = { _, _, _, _, _ in }
    private var activeTurn: (id: UUID, task: Task<Void, Never>)?
    private var levelSampler: Task<Void, Never>?
    /// The connect that is already running, held so a second caller can *wait*
    /// for it rather than give up. A bare `isConnecting` flag made the owner's
    /// very first question fail for no reason: `runTurn` called `connect()`,
    /// the guard returned immediately, readiness was still `.connecting` so
    /// `trouble` was nil, and the turn resolved to the generic "Mynah couldn't
    /// finish that". The window is seconds wide on every cold start, because a
    /// connect runs a full environment probe and an MCP handshake.
    private var connectTask: Task<Void, Never>?
    /// Whether the connected brain runs here. Kept so a failure can be explained
    /// in terms of the brain the owner actually picked — "check this Mac is
    /// online" is the wrong errand for a local model that was never installed.
    private var connectedStaysOnDevice = false

    init(
        engine: TurnEngine? = nil,
        voice: VoiceCapture? = nil,
        exchanges: [Exchange] = [],
        readiness: Readiness = .connecting
    ) {
        self.engine = engine
        self.voice = voice
        self.exchanges = exchanges
        self.readiness = readiness
        self.hasEverAnswered = exchanges.contains {
            if case .answered = $0.outcome { return true }
            return false
        }
    }

    // MARK: Derived state

    var isBusy: Bool { activeTurn != nil }

    /// True while the engine is still being built. Belt and braces beside
    /// `connect()`'s in-flight join: the composer stays live during start-up, so
    /// without this the owner can queue a turn into a half-built engine.
    var isWakingUp: Bool { readiness == .connecting }

    /// **`trouble == nil` is the owner's ruling on amber, made mechanical.**
    ///
    /// When the engine is blocked, Home used to draw an amber "Not ready yet"
    /// beside a Send button that was still live — so the only thing stopping a
    /// doomed turn was the owner reading a colour and inferring what it meant.
    /// He read that colour wrong once and reported a crash that had not
    /// happened, then ended the argument: *"if something is not working, we
    /// should disable the send button or something instead; that makes more
    /// visual sense"*.
    ///
    /// He is describing a better mechanism, not just a better look. A disabled
    /// Send cannot be misread, it needs no legend, and it stops the thing it is
    /// warning about instead of merely colouring it. The banner above the
    /// composer already carries the sentence and the fix.
    var canSend: Bool {
        !isBusy
            && !isRecording
            && !isWakingUp
            && trouble == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Voice capture is offered only when something can actually record and
    /// transcribe. See `VoiceCapture`.
    var canHoldToTalk: Bool { voice != nil }

    var trouble: Exchange.Failure? {
        if case .blocked(let failure) = readiness { return failure }
        return nil
    }

    var health: Health {
        switch readiness {
        case .connecting:
            return Health(tone: .neutral, title: "Waking up", detail: nil)
        case .blocked:
            return Health(tone: .neutral, title: "Not ready yet", detail: "Finish the step below.")
        case .ready(let destination, let model, let staysOnDevice):
            return Health(
                tone: .good,
                // "Online", not "Listening".
                //
                // Listening is what a microphone does. On an appliance that
                // holds private conversations it reads as something switched on
                // in the room and pointed at you — which is the opposite of what
                // is true here: nothing on this Mac records anything, the owner
                // speaks into their phone. "Online" says the same thing about
                // readiness without the implication.
                title: isBusy ? "Answering" : "Online",
                // Was the sentence "your words go to DeepSeek". It is two
                // pills now — the company and the model — because a sentence
                // cannot be scanned and the model was missing from it entirely.
                detail: nil,
                provider: staysOnDevice ? "This Mac" : destination,
                model: model,
                staysOnDevice: staysOnDevice
            )
        }
    }

    // MARK: Connecting

    /// Builds the engine from what the owner chose during setup, and says
    /// plainly what to do when there is nothing to build from.
    /// Joins the connect already in flight, or starts one.
    ///
    /// Every caller awaits a finished connect. Bailing out early left `readiness`
    /// at `.connecting` for the caller that bailed, which `runTurn` then read as
    /// "no engine and no reason" — the owner's first question failing with a
    /// sentence about quitting the app, for a race with the app's own start-up.
    func connect() async {
        if let existing = connectTask {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performConnect()
        }
        connectTask = task
        await task.value
        connectTask = nil
    }

    /// Throws the current engine away and builds a new one.
    ///
    /// `connect()` keeps a live engine whenever the stored choice has not
    /// changed, which is right for every case but one: pasting a *replacement
    /// key* for the same brain. There the choice is identical and the engine is
    /// stale anyway, so without this the owner fixes their key in Settings and
    /// every answer keeps failing until they quit the app.
    func reconnect() async {
        if let existing = connectTask { await existing.value }
        let stale = engine
        engine = nil
        connectedOptionID = nil
        connectedStaysOnDevice = false
        await stale?.shutDown()
        await connect()
    }

    private func performConnect() async {
        // An engine outlives the setup flow, so "Change where your words go" has
        // to be able to reach it. Left alone, a live engine is never rebuilt: the
        // owner changes their brain, Settings shows the new one, and every answer
        // keeps going to the old provider until they quit the app. On a product
        // whose whole pitch is where your words go, that is the one contradiction
        // that cannot ship.
        //
        // Checked here rather than in a new method so that every existing caller
        // — Talk's `.task`, which re-runs when the shell comes back after setup —
        // gets it without a second call site to remember.
        if engine != nil {
            // Only an engine this model built can go stale. An injected one
            // (previews, tests) has no recorded choice and must survive, or
            // opening a preview on a Mac with a real brain saved would tear the
            // stub down and go looking for the owner's actual provider.
            guard let connectedOptionID,
                  BrainSelectionStore.current()?.id != connectedOptionID else { return }
            let stale = engine
            engine = nil
            self.connectedOptionID = nil
            self.connectedStaysOnDevice = false
            await stale?.shutDown()
        }

        readiness = .connecting

        guard let option = BrainSelectionStore.current() else {
            readiness = .blocked(
                Exchange.Failure(
                    headline: "Mynah doesn't know where to think yet.",
                    explanation: "Open Settings and choose where your words go. It takes a moment "
                        + "and you can change it again later.",
                    settingsActionTitle: "Open settings"
                )
            )
            return
        }

        // `keyProviderIdentifier`, not `backendIdentifier`: the same seam setup
        // files the key under. The two disagreed for Google, so a key that was
        // pasted and verified could not be found again.
        let key = option.keyProviderIdentifier.flatMap(KeyStorage.key(forProvider:))
        let company = MynahCopy.company(forBackend: option.backendIdentifier) ?? "the company you chose"
        if option.requirement == .apiKey, (key ?? "").isEmpty {
            readiness = .blocked(
                Exchange.Failure(
                    headline: "Mynah still needs your \(company) key.",
                    explanation: "Open Settings and paste the key you were given. Nothing else is missing.",
                    settingsActionTitle: "Open settings"
                )
            )
            return
        }

        let backend: BrainBackend
        do {
            backend = try BrainFactory.makeBackend(for: option, apiKey: key)
        } catch {
            conversationLog.error("could not build backend: \(String(describing: error))")
            readiness = .blocked(
                Exchange.Failure(
                    headline: "Mynah can't use that brain any more.",
                    explanation: "Open Settings and choose where your words go again.",
                    settingsActionTitle: "Open settings",
                    isSevere: true
                )
            )
            return
        }

        guard let memory = await Self.locateMemoryNode() else {
            readiness = .blocked(
                Exchange.Failure(
                    headline: "Mynah can't find what it remembers.",
                    // Not "install it once more". Reinstalling is the thing an
                    // owner reaches for and the thing that cannot help: the
                    // identity lives in Application Support, which macOS keeps
                    // when an app is trashed, and the node preserves an existing
                    // agent's capabilities when the same key registers again. A
                    // reinstalled Mynah comes back as exactly the same agent
                    // with exactly the same standing, having cost the owner a
                    // download to learn nothing.
                    explanation: "Quit Mynah and open it again. If that doesn't help, your SAGE node "
                        + "isn't running — open it, or check the Agents screen for what it says.",
                    isSevere: true
                )
            )
            return
        }

        let candidate = ToolLoopTurnEngine(backend: backend, memoryExecutable: memory)
        do {
            try await candidate.prepare()
        } catch {
            conversationLog.error("could not prepare engine: \(String(describing: error))")
            readiness = .blocked(Self.explain(error, staysOnDevice: option.keepsWordsOnDevice))
            await candidate.shutDown()
            return
        }

        engine = candidate
        connectedStaysOnDevice = option.keepsWordsOnDevice
        // Recorded alongside the engine, never derived from `readiness`: two
        // options can share a destination company, so the displayed name cannot
        // tell one brain from another.
        connectedOptionID = option.id
        readiness = .ready(
            destination: company,
            model: option.modelName,
            staysOnDevice: option.keepsWordsOnDevice
        )
        // Not awaited: the owner can start typing while the prefill lands.
        Task { await candidate.warmUp() }
    }

    /// The node vendored inside this app first, then whatever the probe finds.
    ///
    /// The vendored copy inherits this app's notarization, so it launches with
    /// nothing for the owner to approve. Probing is the fallback for a build
    /// that was not vendored, and it spawns processes — hence only on that path.
    private static func locateMemoryNode() async -> URL? {
        if let vendored = SageNodeLocator.vendoredExecutableURL() {
            return vendored
        }
        let probe = await EnvironmentProbe().run()
        guard let path = probe.sage.executablePath else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: Turns

    /// Whether the owner has stopped Mynah answering.
    ///
    /// Read from the shared file rather than `AppModel`, so the window and the
    /// appliance cannot disagree — and because `retry()` had no pause check at
    /// all, which made it demonstrable without a phone: pause, hit "Ask again"
    /// on a failed exchange, and a real turn ran under a header saying it would
    /// not.
    var isPaused: Bool { PauseState().isPaused() }


    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPaused else { return }

        // Typing while it thinks used to do nothing whatsoever. The guard was
        // `!isBusy` and returned before clearing the draft, so Return left the
        // sentence sitting in the box and the owner watching a spinner, with no
        // way to tell a refused send from a slow one. On an appliance whose
        // turns run 20–60 s that is most of the time it is being used.
        //
        // Queued rather than sent, because Ollama serves one slot: a second
        // request now would either be refused or would evict the prompt cache
        // the running turn is built on.
        guard !isBusy else {
            queued.append(text)
            draft = ""
            return
        }

        draft = ""
        let exchange = Exchange(question: text)
        exchanges.append(exchange)
        startTurn(id: exchange.id, transcript: text)
    }

    /// What the owner typed while the last turn was still running.
    ///
    /// Sent as **one** question rather than several turns. Three sentences
    /// typed in a row while waiting are almost always one thought — "and the
    /// address", "and their number" — and answering them separately costs
    /// three full turns to say what one turn would have said better.
    private(set) var queued: [String] = []

    /// Starts a turn for everything queued during the last one.
    ///
    /// Joined with newlines, so the model reads them as consecutive lines of a
    /// single message and the transcript records what was actually asked.
    private func flushQueued() {
        guard !queued.isEmpty, !isPaused, !isBusy else { return }
        let text = queued.joined(separator: "\n")
        queued.removeAll()
        let exchange = Exchange(question: text)
        exchanges.append(exchange)
        startTurn(id: exchange.id, transcript: text)
    }

    /// Re-asks a question that failed. The failed attempt contributed nothing to
    /// `history`, so this is a clean second try rather than a continuation.
    func retry(_ id: UUID) {
        guard !isBusy, !isPaused, let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        let question = exchanges[index].question
        exchanges[index].askedAt = Date()
        exchanges[index].outcome = .thinking
        startTurn(id: id, transcript: question)
    }

    /// The owner's own escape hatch from a long turn. Not an error.
    func stop() {
        guard let active = activeTurn else { return }
        active.task.cancel()
        activeTurn = nil
        // Stop means stop, including whatever was typed while it ran. Draining
        // the queue here would answer Stop by immediately starting another
        // turn, which is the opposite of what the button says. Put back in the
        // box rather than discarded — the owner can press Return again.
        draft = ([queued.joined(separator: "\n"), draft]
            .filter { !$0.isEmpty }).joined(separator: "\n")
        queued.removeAll()
        finish(active.id, with: .failed(.stopped))
    }

    /// Clears the screen. **Not the context, and that is the whole change.**
    ///
    /// This used to do `history.removeAll()` as well, on the reasoning that a
    /// button called "clear" must not leave Mynah answering from turns the owner
    /// believes they deleted. Sound for a button that deletes a conversation,
    /// and this is not one — the line beside it has always read *"Clearing here
    /// changes nothing on your phone"*, so the conversation demonstrably
    /// survives. All the extra wipe removed was the appliance's ability to
    /// follow it.
    ///
    /// The owner named the model he wanted: *"think of the clear more to clear
    /// the screen of chat clutter, but behind the scenes the agent still needs
    /// the context window and what was last discussed — this way only a true
    /// 'clear' from signal interface would REALLY clear the chat window"*.
    ///
    /// So the window is a *view* of the conversation, not the conversation.
    /// Signal owns the record, this clears the view, and Mynah keeps the thread
    /// either way — re-grounding from SAGE when it goes cold.
    func clear() {
        stop()
        exchanges.removeAll()
    }

    private func startTurn(id: UUID, transcript: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(id: id, transcript: transcript)
        }
        activeTurn = (id: id, task: task)
    }

    private func runTurn(id: UUID, transcript: String) async {
        if engine == nil {
            await connect()
        }
        guard let engine else {
            // `trouble` is set by `connect()` on every failing path, but the
            // fallback matters: an exchange left waiting forever is a spinner
            // with no story, which is worse than any wrong sentence.
            finish(id, with: .failed(trouble ?? Self.explain(ConnectionUnavailable())))
            clearActiveTurn(id)
            return
        }

        do {
            let result = try await engine.run(
                transcript: transcript,
                history: groundingHistory(excluding: id)
            )
            guard !Task.isCancelled else {
                clearActiveTurn(id)
                return
            }
            hasEverAnswered = true
            finish(
                id,
                with: .answered(
                    Exchange.Answer(
                        text: result.reply,
                        seconds: result.seconds,
                        activity: ToolActivity.phrases(for: result.toolNames),
                        files: result.files
                    )
                )
            )
        } catch {
            if Task.isCancelled || error is CancellationError {
                finish(id, with: .failed(.stopped))
            } else {
                conversationLog.error("turn failed: \(String(describing: error))")
                finish(id, with: .failed(Self.explain(error, staysOnDevice: connectedStaysOnDevice)))
            }
        }
        clearActiveTurn(id)
    }

    /// Only ever resolves a turn that is still waiting, so a late answer cannot
    /// overwrite a Stop the owner already pressed.
    private func finish(_ id: UUID, with outcome: Exchange.Outcome) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }),
              exchanges[index].isThinking else { return }
        exchanges[index].outcome = outcome
        // The one place a turn resolves, so the one place worth writing down.
        // Only answers: a failed or stopped turn is half an exchange, and half
        // an exchange in a record reads as Mynah ignoring somebody.
        guard case .answered(let answer) = outcome else { return }
        let asked = exchanges[index].askedAt
        recordTurn(
            exchanges[index].question,
            answer.text,
            asked,
            asked.addingTimeInterval(answer.seconds),
            answer.files
        )
    }

    private func clearActiveTurn(_ id: UUID) {
        guard activeTurn?.id == id else { return }
        activeTurn = nil
        // The one place a turn ends, so the one place the queue can drain.
        flushQueued()
    }

    /// **What Mynah answers from: exactly what is on the screen.**
    ///
    /// Derived every turn rather than accumulated, and that is the fix. There
    /// used to be a `history` array built from the previous turn's result, which
    /// meant the window's context and the window's contents were two different
    /// records kept in step by nothing. They drifted the moment a message
    /// arrived from the phone — the mirror drew it, the array never saw it — and
    /// the owner watched Mynah fail to see a recipe sitting directly above the
    /// question about it.
    ///
    /// One record cannot drift from itself. The phone's turns come first because
    /// they happened first, then this window's, then `trimmed` keeps the last
    /// few of the whole thing.
    ///
    /// Three exclusions, each deliberate:
    ///
    /// - **The turn being answered.** It is already in `exchanges` by the time
    ///   this runs — `send()` appends before starting — and it is passed to the
    ///   engine as `transcript`. Including it here would ask the question twice.
    /// - **Anything still thinking.** A question with no answer yet is half a
    ///   turn, and half a turn in a history is a model being told it already
    ///   replied when it did not.
    /// - **Anything that failed.** This was the old array's rule too, in
    ///   `retry`'s words: a failed attempt contributed nothing, so asking again
    ///   is a clean second try rather than a continuation.
    private func groundingHistory(excluding active: UUID) -> [BrainMessage] {
        var messages = priorContext()
        for exchange in exchanges where exchange.id != active {
            guard case .answered(let answer) = exchange.outcome else { continue }
            messages.append(BrainMessage(role: .user, content: exchange.question))
            messages.append(BrainMessage(role: .assistant, content: answer.text))
        }
        return Self.trimmed(messages, keepingLastTurns: Self.historyTurnLimit)
    }

    // MARK: History hygiene

    /// Reduces a finished turn to what the *next* turn should remember: the
    /// owner's words and the answer they were given. Nothing else.
    ///
    /// Keeping the tool calls and their results was a real bug on the appliance,
    /// not merely waste. Observed: turn 2 called a memory tool and answered;
    /// turns 3, 4 and 5 then called **no tools at all** and recycled that
    /// answer — including for "can you save a memory?", which should have
    /// written one. With last turn's tool output sitting in context a small
    /// model concludes it already has the facts, so Mynah goes stale the moment
    /// anything changes in what it remembers.
    ///
    /// The system turn goes too (`ToolLoop` prepends its own), as does every
    /// assistant turn that carried only tool calls and no sentence, since
    /// replaying those without their results is incoherent.
    ///
    /// Duplicated from `VoiceBridgeDaemon` on purpose: the originals are
    /// internal to `SageVoiceCore` and this app cannot call them. Behaviour is
    /// kept identical — if one changes, both must.
    static func conversationOnly(_ messages: [BrainMessage]) -> [BrainMessage] {
        messages.compactMap { message in
            switch message.role {
            case .system, .tool:
                return nil
            case .user:
                return message
            case .assistant:
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return BrainMessage(role: .assistant, content: ToolLoop.speakable(message.content))
            }
        }
    }

    /// Keeps the last `turns` exchanges, trimming from the front rather than
    /// summarising: prefill dominates the cost of a turn, and an old exchange is
    /// not worth re-paying it for.
    static func trimmed(_ messages: [BrainMessage], keepingLastTurns turns: Int) -> [BrainMessage] {
        guard turns > 0 else { return [] }
        var userIndices: [Int] = []
        for (index, message) in messages.enumerated() where message.role == .user {
            userIndices.append(index)
        }
        guard userIndices.count > turns else { return messages }
        return Array(messages[userIndices[userIndices.count - turns]...])
    }

    // MARK: Voice

    func beginRecording() {
        guard let voice, !isRecording, !isBusy else { return }
        isRecording = true
        micLevel = 0
        Task {
            do {
                try await voice.begin()
            } catch {
                conversationLog.error("could not start recording: \(String(describing: error))")
                stopSampling()
                isRecording = false
            }
        }
        // The meter is sampled rather than pushed so `VoiceCapture` stays a
        // three-method protocol instead of an observation contract.
        levelSampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let voice = self.voice else { return }
                self.micLevel = voice.level
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Puts the words in the field rather than sending them.
    ///
    /// A mishearing that goes straight to a brain holding tools is exactly the
    /// failure the tool allowlist exists to bound; letting the owner read it
    /// first costs one keystroke and removes the whole class.
    func endRecording() {
        guard let voice, isRecording else { return }
        stopSampling()
        isRecording = false
        Task {
            do {
                let spoken = try await voice.finish()
                let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                draft = draft.isEmpty ? trimmed : draft + " " + trimmed
            } catch {
                conversationLog.error("could not transcribe: \(String(describing: error))")
            }
        }
    }

    func cancelRecording() {
        guard let voice, isRecording else { return }
        stopSampling()
        isRecording = false
        voice.cancel()
    }

    private func stopSampling() {
        levelSampler?.cancel()
        levelSampler = nil
        micLevel = 0
    }

    // MARK: Error translation

    /// Maps whatever went wrong onto a sentence pair with a verb in it.
    ///
    /// The one place an error becomes owner-facing copy. Nothing that reaches a
    /// `Text` comes from `localizedDescription`, an HTTP status, or an exception
    /// — those go to `conversationLog` and stay there.
    static func explain(_ error: Error, staysOnDevice: Bool = false) -> Exchange.Failure {
        if let backendError = error as? BrainBackendError {
            switch backendError {
            case .missingCredential, .unauthorized:
                return Exchange.Failure(
                    headline: "Mynah can't sign in to its brain.",
                    explanation: "The key it has was refused. Open Settings and paste a new one.",
                    settingsActionTitle: "Open settings",
                    isSevere: true
                )
            case .rateLimited:
                return Exchange.Failure(
                    headline: "Mynah has used up its allowance for now.",
                    explanation: "The company answering for it caps how much you can ask at once. "
                        + "Wait a few minutes and ask again.",
                    canRetry: true
                )
            case .unreachable:
                // A brain that runs here cannot be unreachable for want of a
                // network. Telling that owner to check their Wi-Fi sends them
                // to inspect the one thing that is definitely fine, for a model
                // that was never installed.
                guard !staysOnDevice else {
                    return Exchange.Failure(
                        headline: "Mynah hasn't got its own brain on this Mac yet.",
                        explanation: "The brain that runs here still has to be installed before "
                            + "Mynah can use it. Open Settings and choose where your words go.",
                        settingsActionTitle: "Open settings",
                        isSevere: true
                    )
                }
                return Exchange.Failure(
                    headline: "Mynah can't reach its brain.",
                    explanation: "Check this Mac is online, then ask again.",
                    canRetry: true,
                    isSevere: true
                )
            case .misconfigured, .badResponse, .malformedResponse, .requestRejected:
                return Exchange.Failure(
                    headline: "Mynah couldn't finish that.",
                    explanation: "Something went wrong at the other end. Ask again — it usually "
                        + "works the second time.",
                    canRetry: true,
                    isSevere: true
                )
            }
        }

        if let loopError = error as? ToolLoopError {
            switch loopError {
            case .emptyReply:
                return Exchange.Failure(
                    headline: "Mynah didn't have an answer for that.",
                    explanation: "Try asking it a different way — it does better with a whole "
                        + "sentence than a couple of words.",
                    canRetry: true
                )
            case .noTools, .toolAllowlistMatchedNothing:
                return memoryUnreachable
            }
        }

        if error is MCPClientError || error is CompositeToolSource.Failure {
            return memoryUnreachable
        }

        return Exchange.Failure(
            headline: "Mynah couldn't finish that.",
            explanation: "Ask it again. If it keeps happening, quit Mynah and open it once more.",
            canRetry: true,
            isSevere: true
        )
    }

    /// The engine went missing without `connect()` recording a reason. Its own
    /// type so the generic branch of `explain(_:)` handles it, rather than a
    /// second copy of the same sentence pair.
    private struct ConnectionUnavailable: Error {}

    private static let memoryUnreachable = Exchange.Failure(
        headline: "Mynah can't get to what it remembers.",
        explanation: "Quit Mynah and open it again. Everything it knows is still on this Mac.",
        isSevere: true
    )
}
