import Observation
import OSLog
import SwiftUI

// MARK: - Who Mynah can ask

/// One agent Mynah can hand work to.
///
/// Deliberately narrower than what the node returns. `sage_find_agent` hands
/// back an `agent_id`, a `to` address, a `registered_name` and a `provider`;
/// none of those is a fact about the owner's life. The owner says "ask
/// Perplexity" — they say the *name*, and the address is the machine's problem.
/// What survives this boundary is the name, whether it can answer, and the one
/// thing this product exists to be honest about: where it is.
struct KnownAgent: Identifiable, Hashable, Sendable {

    /// Where the agent runs, which is the same question as "does asking it send
    /// my words off this Mac".
    ///
    /// The setup flow settled the vocabulary for this — "Stays on this Mac" and
    /// "Sends your words to Google" — and this is the same fact in the same
    /// words, in the other place the owner decides it.
    enum Location: Hashable, Sendable {
        case thisMac
        /// The peer's name when the node gives one, and nothing when it does
        /// not. Naming a machine Mynah cannot name would be worse than saying
        /// "another machine".
        case anotherMachine(String?)
    }

    /// The node's address for this agent. Held so a future "ask this one" can
    /// pipe to it, never rendered — a hex digest on screen is machinery.
    let id: String
    let name: String
    /// False when the node knows an agent that cannot currently take work.
    ///
    /// Always true for everything `sage_find_agent` returns today: that tool
    /// searches "active local registrations" and active federated contacts, so
    /// a dormant agent never reaches this screen. Kept because the day a source
    /// *can* report a dormant one, "Perplexity is here but not answering" is a
    /// materially different sentence from "Perplexity is not here" — and a
    /// screen that cannot tell them apart sends the owner to the wrong fix.
    let isReady: Bool
    let location: Location

    /// The right-hand fact on the row.
    var whereabouts: String {
        guard isReady else { return "Not answering" }
        switch location {
        case .thisMac: return "On this Mac"
        case .anotherMachine(let name): return name.map { "On \($0)" } ?? "On another machine"
        }
    }

    var tone: MynahTone {
        guard isReady else { return .caution }
        return location == .thisMac ? .good : .caution
    }
}

/// Work another agent has sent back, waiting for the owner.
///
/// `summary` is the node's own words for the item. Nothing on this screen
/// composes a description of work it did not do.
struct WaitingWork: Identifiable, Hashable, Sendable {
    let id: String
    let from: String
    let summary: String
    let arrived: Date
}

/// Everything the agents pane shows, in one answer.
///
/// One value rather than three calls with three loading states: the pane has one
/// idea, so it has one load and one thing that can go wrong.
struct AgentDirectory: Sendable, Equatable {
    var agents: [KnownAgent] = []
    var waiting: [WaitingWork] = []

    static let empty = AgentDirectory()

    /// Whether asking anything on this list could send the owner's words off
    /// this Mac.
    ///
    /// Derived from the agents rather than read from the federation call, and
    /// the difference matters: a node can have a federated peer connected and no
    /// federated *agent* the owner can reach, and in that case nothing here can
    /// send their words anywhere. The claim on screen has to be about what is on
    /// screen.
    var reachesAnotherMachine: Bool {
        agents.contains { $0.location != .thisMac }
    }
}

// MARK: - The seam

/// Where the list of agents comes from.
///
/// A protocol for the same reason `MemoryStoring` is one: so this screen can be
/// drawn, previewed and tested without a running node, and so nothing in the
/// view layer learns what MCP is.
///
/// **Nothing in this file talks to SAGE.** The app already runs two SAGE child
/// processes — `ConversationModel`'s and `SageMemoryStore`'s — and a third
/// started from here would be a third node reading the same state directory.
/// The real implementation belongs beside one of those, not here.
protocol AgentDirectorySource: Sendable {
    func directory() async throws -> AgentDirectory
}

/// Everything that can go wrong between this screen and the agents, in the
/// shapes the owner can act on.
///
/// Note what is *not* here: an empty directory. "You have no agents" is a result,
/// not a failure, and the two must never render the same — an owner with ten
/// agents and a stopped node being told they have none is the failure this enum
/// exists to prevent.
enum AgentTrouble: Error, Equatable, Sendable {
    /// This screen has no way to reach the node yet. See `DisconnectedAgents`.
    case notConnected
    /// Mynah's memory and agents have never been set up on this Mac.
    case notSetUp
    /// Set up, and it did not answer.
    case unreachable
    /// It answered, and refused.
    case refused
    /// It answered with something this app could not read.
    case unreadable

    var headline: String {
        switch self {
        case .notConnected: return "Mynah can't list your agents on this screen yet."
        case .notSetUp: return "Mynah hasn't got a memory on this Mac yet."
        case .unreachable: return "Mynah can't reach your agents."
        case .refused: return "Mynah wouldn't open its agent list."
        case .unreadable: return "Mynah's node answered with something unexpected."
        }
    }

    /// Every one of these names something the owner can do, and none of them
    /// claims the agents are gone.
    var explanation: String {
        switch self {
        case .notConnected:
            // Says the true thing and points at the path that does work. An
            // owner who reads this and sends a voice note gets the feature.
            return "Your agents are still there, and Mynah can already reach them when you "
                + "ask out loud — name one in a voice note and it will find it."
        case .notSetUp:
            return "Set Mynah up again and it will build one. Nothing is lost — there was "
                + "nowhere to keep it yet."
        case .unreachable:
            return "It may still be starting up. Give it a moment and try again. Your agents "
                + "are unaffected."
        case .refused:
            return "Quit Mynah and open it again. If that doesn't help, set it up again."
        case .unreadable:
            return "Try again. If it keeps happening, quit Mynah and open it again."
        }
    }

    /// Only a failure the owner can retry gets a button. "Try again" on a node
    /// that was never installed is a button that fails the same way every time.
    var isWorthRetrying: Bool {
        self == .unreachable || self == .unreadable
    }
}

/// The shipping default, and it fetches nothing.
///
/// The pane is drawn and the seam is not connected. That is a deliberate state
/// rather than an oversight: wiring it means reusing the app's existing node
/// connection, which lives in a file this work was not allowed to touch, and a
/// screen that invented plausible agents to fill the gap would be worse than one
/// that says plainly it cannot list them. `AgentTrouble.notConnected` is honest
/// about this screen without claiming anything untrue about the node.
struct DisconnectedAgents: AgentDirectorySource {
    func directory() async throws -> AgentDirectory {
        throw AgentTrouble.notConnected
    }
}

// MARK: - Model

@MainActor
@Observable
final class AgentsModel {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(AgentTrouble)
    }

    private(set) var phase: Phase = .loading
    private(set) var directory = AgentDirectory.empty

    private let source: any AgentDirectorySource
    private let log = Logger(subsystem: "com.sage.mynah", category: "agents")

    init(source: any AgentDirectorySource = DisconnectedAgents()) {
        self.source = source
    }

    func load() async {
        // The previous answer stays on screen while this runs. A refresh that
        // blanks the list first makes a working node look like it dropped out
        // every time the owner comes back to the pane.
        do {
            directory = try await source.directory()
            phase = .ready
        } catch let trouble as AgentTrouble {
            phase = .failed(trouble)
        } catch {
            log.error("agent directory failed: \(String(describing: error), privacy: .public)")
            phase = .failed(.unreachable)
        }
    }
}

// MARK: - Screen

/// Who Mynah can hand work to, and what has come back.
///
/// One idea, so one list. There is no search field: the owner has a handful of
/// agents, not a thousand memories, and a filter over seven rows is a control
/// that exists to look capable. There is no address, no provider and no agent
/// id, because the owner speaks names. What is left is the name, where it runs,
/// and — only when there is any — what it sent back.
struct AgentsView: View {
    @State private var model: AgentsModel

    /// `@MainActor` because `AgentsModel` is, and a `View`'s initialiser is not
    /// isolated by default even though SwiftUI only ever calls it here.
    @MainActor
    init(source: any AgentDirectorySource = DisconnectedAgents()) {
        _model = State(initialValue: AgentsModel(source: source))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Who Mynah can ask")
                    .mynahFont(.title1)
                    .foregroundStyle(Palette.ink.primary)
                    .accessibilityAddTraits(.isHeader)

                destinationLine.padding(.top, s3)

                content.padding(.top, s6)
            }
            .frame(maxWidth: MynahWidth.settings, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, s8)
            .padding(.top, s7)
            .padding(.bottom, s9)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.surface.canvas)
        .task { await model.load() }
    }

    /// The one sentence this screen exists to be trusted on, directly under the
    /// title and above the list — before the owner picks anybody.
    ///
    /// The setup flow answers "where do your words go?" on the screen where the
    /// owner chooses a brain. This is the same question arriving from the other
    /// direction: handing work to an agent on somebody else's machine sends
    /// their words there, and that has to be said here rather than discovered
    /// afterwards.
    @ViewBuilder
    private var destinationLine: some View {
        if case .ready = model.phase, !model.directory.agents.isEmpty {
            HStack(spacing: s3) {
                StatusDot(model.directory.reachesAnotherMachine ? .caution : .good)
                Text(model.directory.reachesAnotherMachine
                     ? "Some of these run on other machines. Ask one and your words go there."
                     : "Everything here runs on this Mac.")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            // Nothing at all, on purpose. A directory load is a fraction of a
            // second, and a breathing indicator on every visit is an appliance
            // asking to be watched.
            Color.clear.frame(height: 1)

        case .failed(let trouble):
            InlineBanner(
                tone: trouble == .notConnected ? .info : .critical,
                headline: trouble.headline,
                explanation: trouble.explanation,
                actionTitle: trouble.isWorthRetrying ? "Try again" : nil,
                action: trouble.isWorthRetrying ? { Task { await model.load() } } : nil
            )

        case .ready:
            if model.directory.agents.isEmpty {
                EmptyState(
                    glyph: "person.2",
                    // Not "you have no agents". This screen sees what Mynah can
                    // see, and Mynah signs as itself — the same care
                    // `MemoriesView` takes with its own empty sentence.
                    title: "Nobody to ask yet",
                    message: "Agents on this Mac appear here as they register. Mynah is the "
                        + "first one, and it is already listening."
                )
                .padding(.top, s8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    roster
                    waiting
                }
            }
        }
    }

    /// The agents, as a status list — dot, name, whereabouts. The same three
    /// marks the ready stage of setup uses to summarise what the owner decided,
    /// which is what makes this screen read as the same product.
    private var roster: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.directory.agents.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { MynahDivider() }
                StatusLine(agent.name, value: agent.whereabouts, tone: agent.tone)
            }
        }
        .mynahGroupCard()
    }

    /// Only when there is any.
    ///
    /// An empty "Waiting for you" card under a list of agents is a heading with
    /// nothing behind it, and the owner learns to stop reading headings.
    @ViewBuilder
    private var waiting: some View {
        if !model.directory.waiting.isEmpty {
            SettingsGroup("Waiting for you") {
                ForEach(Array(model.directory.waiting.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { MynahDivider() }
                    SettingsRow(item.from, detail: item.summary) {
                        Text(item.arrived.formatted(.relative(presentation: .named)))
                            .mynahFont(.label)
                            .foregroundStyle(Palette.ink.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Previews

/// Preview data, and the reason `AgentDirectorySource` exists.
///
/// Named so it can never be mistaken for a shipping source: nothing in the app
/// constructs this, and the app's default argument is `DisconnectedAgents`.
struct PreviewAgentDirectory: AgentDirectorySource {
    var directory: AgentDirectory = .init()
    var trouble: AgentTrouble?

    func directory() async throws -> AgentDirectory {
        if let trouble { throw trouble }
        return directory
    }

    /// Shaped after what `sage_find_agent` actually returns on a real node.
    static let local = AgentDirectory(
        agents: [
            KnownAgent(id: "1", name: "Mynah", isReady: true, location: .thisMac),
            KnownAgent(id: "2", name: "Claude Code", isReady: true, location: .thisMac),
            KnownAgent(id: "3", name: "Codex", isReady: true, location: .thisMac)
        ]
    )

    static let federated = AgentDirectory(
        agents: [
            KnownAgent(id: "1", name: "Mynah", isReady: true, location: .thisMac),
            KnownAgent(id: "2", name: "Claude Code", isReady: true, location: .thisMac),
            KnownAgent(id: "3", name: "Perplexity", isReady: true, location: .anotherMachine("Ana's Mac")),
            KnownAgent(id: "4", name: "Overnight indexer", isReady: false, location: .anotherMachine(nil))
        ],
        waiting: [
            WaitingWork(
                id: "w1",
                from: "Perplexity",
                summary: "The comparison of the three espresso grinders you asked about.",
                arrived: Date().addingTimeInterval(-2_400)
            )
        ]
    )
}

private struct AgentsPreviewPair: View {
    let source: PreviewAgentDirectory

    var body: some View {
        HStack(spacing: 0) {
            AgentsView(source: source).environment(\.colorScheme, .light)
            AgentsView(source: source).environment(\.colorScheme, .dark)
        }
    }
}

#Preview("Agents — all on this Mac") {
    AgentsPreviewPair(source: PreviewAgentDirectory(directory: PreviewAgentDirectory.local))
        .frame(width: 1440, height: 700)
}

#Preview("Agents — some elsewhere") {
    AgentsPreviewPair(source: PreviewAgentDirectory(directory: PreviewAgentDirectory.federated))
        .frame(width: 1440, height: 700)
}

#Preview("Agents — nobody yet") {
    AgentsPreviewPair(source: PreviewAgentDirectory())
        .frame(width: 1440, height: 700)
}

/// What the app itself shows today, and the state that must never read as
/// "you have no agents".
#Preview("Agents — not connected") {
    AgentsPreviewPair(source: PreviewAgentDirectory(trouble: .notConnected))
        .frame(width: 1440, height: 700)
}

#Preview("Agents — node stopped") {
    AgentsPreviewPair(source: PreviewAgentDirectory(trouble: .unreachable))
        .frame(width: 1440, height: 700)
}
