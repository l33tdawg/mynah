import AppKit
import Observation
import OSLog
import SageVoiceCore
import SwiftUI

// MARK: - What Mynah remembers

/// One thing Mynah learned, in the only terms the owner needs.
///
/// Deliberately narrower than what the node returns. The store hands back a
/// content hash, a classification, a submitting agent, a corroboration count, a
/// challenge count and a consensus status; none of that is a fact about the
/// owner's life, so none of it survives this boundary. What is left is a
/// sentence, when it was learned, what it is about, and how sure Mynah is.
struct Memory: Identifiable, Hashable, Sendable {

    /// Confidence as words. The node stores a float and the owner will never
    /// see one — "0.82 confidence" is a fact about a consensus algorithm, not
    /// about whether Mynah should be trusted on this.
    enum Certainty: Sendable, Hashable, CaseIterable {
        case certain
        case fairlySure
        case unsure

        init(score: Double) {
            switch score {
            case 0.90...: self = .certain
            case 0.70..<0.90: self = .fairlySure
            default: self = .unsure
            }
        }

        var word: String {
            switch self {
            case .certain: return "Certain"
            case .fairlySure: return "Fairly sure"
            case .unsure: return "Not sure"
            }
        }

        /// The detail line. A sentence, because a one-word verdict on its own
        /// invites the owner to wonder what the other words would have been.
        var sentence: String {
            switch self {
            case .certain: return "Mynah is certain about this."
            case .fairlySure: return "Mynah is fairly sure about this."
            case .unsure: return "Mynah isn't sure about this one — it may have misheard."
            }
        }
    }

    let id: String
    let text: String
    /// The node calls this a domain. The owner calls it what the memory is about.
    let topic: String
    let learned: Date
    let certainty: Certainty
}

/// One page of memories, plus how many exist behind it.
struct MemoryPage: Sendable {
    var memories: [Memory]
    /// What the node says the whole filtered set contains. Used only to decide
    /// whether a "Show more" row is honest, never rendered as a count — the
    /// number the owner sees is the number of rows they can actually see.
    var total: Int

    static let empty = MemoryPage(memories: [], total: 0)
}

/// What happened when the owner asked Mynah to forget something.
enum ForgetOutcome: Sendable, Equatable {
    /// Gone. The row disappears.
    case forgotten
    /// The node accepted the request but has not finished acting on it. Saying
    /// "done" here would be a lie the owner could disprove by refreshing.
    case stillLettingGo
}

/// Everything that can go wrong between this screen and the memories, in the
/// four shapes the owner can actually do something about.
///
/// The underlying error — an exit status, a JSON-RPC code, an HTTP status —
/// goes to `os.Logger` and stops there.
enum MemoryTrouble: Error, Equatable, Sendable {
    /// Mynah's memory has never been set up on this Mac.
    case notSetUp
    /// It is set up but did not answer.
    case unreachable
    /// It answered, and refused.
    case refused
    /// The store is there and shut. Distinct from `refused` because the owner
    /// can do something about this one and the fix is not "quit and reopen".
    case locked
    /// It answered with something this app could not read.
    case unreadable

    var headline: String {
        switch self {
        case .notSetUp: return "Mynah hasn't got a memory on this Mac yet."
        case .unreachable: return "Mynah can't get to what it remembers."
        case .refused: return "Mynah wouldn't open its memory."
        case .locked: return "Your SAGE node is locked."
        case .unreadable: return "Mynah's memory answered with something unexpected."
        }
    }

    /// Every one of these names a verb the owner can perform, and none of them
    /// says the memories are gone.
    var explanation: String {
        switch self {
        case .notSetUp:
            return "Set Mynah up again and it will build one. Nothing you've said is lost — "
                + "there was nowhere to keep it yet."
        case .unreachable:
            return "It may still be starting up. Give it a moment and try again."
        case .refused:
            // Not "set it up again", and not "reinstall". The appliance's key
            // survives both — it lives in Application Support, which macOS keeps
            // when an app is trashed — so the same identity comes back with the
            // same registration. Sending somebody round that loop costs them an
            // afternoon and leaves them exactly where they started.
            return "Quit Mynah and open it again. If it still won't open, send the diagnostics "
                + "from Settings — nothing you have told it is affected."
        case .locked:
            // **Kept deliberately, and it is the only "can't read" claim that
            // survived the sweep.** Three others were removed on 29 July for
            // saying this falsely; this one is true, and the difference is
            // which door the answer came through.
            //
            // The task board and the agents roster ask over *unsigned REST*,
            // where a 401 means "you are not an operator" and says nothing
            // about the node. This screen asks over **MCP, signed as the
            // appliance** — see the reader below, which drives `sage_list` and
            // `sage_recall` through `MCPClient`. When a signed request comes
            // back sealed, the vault genuinely is sealed and Mynah genuinely
            // cannot read it.
            //
            // `login_required` is the same token on both paths, which is
            // exactly how the false version got written. If this sentence ever
            // needs revisiting, the question is not "can Mynah read" — it is
            // whether this screen is still signed.
            return "Everything Mynah remembers is still there — it just can't read any of it "
                + "until the node is unlocked. Unlock it in CEREBRUM and this fills in."
        case .unreadable:
            return "Try again. If it keeps happening, quit Mynah and open it again."
        }
    }

    /// Which refusal this is, read from the node's own words.
    ///
    /// The MCP transport hands back one error for "the tool said no" regardless
    /// of why, so the only signal available is the message. A locked vault says
    /// so; everything else keeps `refused`, which is the safe direction — an
    /// owner told to quit and reopen when the real problem was a passphrase
    /// tries the wrong fix once, whereas an owner told to unlock a node that is
    /// not locked is sent looking for a passphrase that does not exist.
    static func reading(refusal detail: String?) -> MemoryTrouble {
        let said = (detail ?? "").lowercased()
        let locked = ["login_required", "unlock", "locked", "vault is sealed", "sealed"]
        return locked.contains(where: said.contains) ? .locked : .refused
    }
}

// MARK: - The seam

/// Where memories come from.
///
/// A protocol so this screen can be previewed, tested and shipped without a
/// running node, and so nothing in the view layer ever learns what MCP is.
protocol MemoryStoring: Sendable {
    /// Newest first. `topic` is the node's domain filter, applied at the source
    /// rather than to the loaded page — a filter that only searches what
    /// happens to be on screen is not a filter.
    func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage

    /// Search by meaning, not by spelling.
    func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage

    func forget(id: String) async throws -> ForgetOutcome
}

// MARK: - The real one

/// Talks to the memory node that ships inside this app.
///
/// An actor holding one long-lived `MCPClient`. The child process is expensive
/// to start — the node runs a first-connection handshake that took ~4s on this
/// machine — so it is started once and kept, not spawned per query.
actor SageMemoryStore: MemoryStoring {

    /// One per app. The screen may be built and torn down repeatedly as the
    /// owner moves around the sidebar; the node connection must not be.
    static let shared = SageMemoryStore()

    private let log = Logger(subsystem: "com.sage.mynah", category: "memories")

    private var client: MCPClient?

    /// The identity this screen signs as — the appliance's, and nobody else's.
    ///
    /// **This screen spent its whole life querying the node as an agent that
    /// does not exist, and it is worth writing down exactly how.** It resolved
    /// through `MynahIdentity.resolvedKeyPath()`, which returns `keyURL()` →
    /// `agent.key`. That file derives to agent `17641c48…`, and `17641c48` is
    /// not on the node's roster at all. The appliance is `74140c2d…`, which
    /// comes from `applianceKeyURL()` → `appliance-agent.key`. So every browse
    /// asked "what does this ghost remember?", the honest answer was "nothing",
    /// and the screen drew an empty list — an independent second cause of the
    /// empty Memories screen, on top of the capability mask.
    ///
    /// The comment that used to sit here said `MynahIdentity` was "the single
    /// answer for the whole app". That belief is what caused this: there are two
    /// key files in the appliance's support directory, and since "one appliance
    /// is one agent" the window signs as the appliance while `agent.key` is a
    /// leftover. `applianceEnvironment()` is the single answer, it is what
    /// `ConversationModel` and `sage-voiced` already spawn with, and it carries
    /// the key migration those two depend on.
    ///
    /// Not `private`, and that is the one concession this type makes to its
    /// tests. `MemoryNodeChoiceTests` reads the key path back out, derives the
    /// agent id from it and checks that agent is on the node's roster — because
    /// nothing else can. **A ghost key is answered emptily rather than refused**,
    /// so every other check passes: the child spawns, the call returns, the list
    /// comes back empty, and "empty" is exactly what a new install looks like.
    /// That is how this shipped and went unnoticed. `thread` hit the same
    /// silent-success problem on the federation scan and arrived at the same
    /// shape independently, which is the argument for it.
    static var identityEnvironment: [String: String] {
        MynahIdentity.applianceEnvironment()
    }

    /// The node already installed on this Mac, and only otherwise the one
    /// vendored in this app.
    ///
    /// **This used to be `EnvironmentProbe.defaultSageBundleExecutables`, which
    /// is the exact opposite ordering, and the two resolvers in this codebase
    /// contradict each other on purpose.** The probe puts the vendored copy
    /// first because its job is finding *a runnable node on a bare machine*, and
    /// for that it is right. It is the wrong answer to the different question
    /// this screen asks, which is "which binary should operate the store that
    /// already holds the owner's memories" — and using it meant that on a Mac
    /// with SAGE installed, browsing memories spawned the copy we happened to
    /// vendor to drive somebody's existing `~/.sage`. One store, two binaries,
    /// whatever versions they happened to be. `SageNodeChoice` is the rule the
    /// owner actually asked for — "if a SAGE node is already installed, Mynah
    /// uses it and changes nothing about it" — and it is what `sage-voiced`
    /// already resolves with, so the daemon and this screen now agree.
    private static var executableURL: URL? {
        SageNodeChoice.resolve(vendored: SageNodeLocator.vendoredExecutableURL())?.executable
    }

    private func connection() throws -> MCPClient {
        if let client { return client }
        guard let executable = Self.executableURL else {
            throw MemoryTrouble.notSetUp
        }
        // 30s rather than the 90s default. A browse that has not answered in
        // half a minute has failed, and the screen owes the owner a sentence
        // rather than another minute of dots.
        let made = MCPClient(
            executableURL: executable,
            arguments: ["mcp"],
            environment: Self.identityEnvironment,
            requestTimeoutSeconds: 30
        )
        client = made
        return made
    }

    /// Drops the connection so the next call starts a fresh child. Called when
    /// the node has gone away underneath us — a retained dead client answers
    /// every subsequent request with the same failure forever.
    private func reset() {
        client?.stop()
        client = nil
    }

    // MARK: Queries

    func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage {
        var arguments: [String: JSONValue] = [
            "limit": .int(limit),
            "offset": .int(offset),
            "sort": .string("newest")
        ]
        if let topic, !topic.isEmpty { arguments["domain"] = .string(topic) }
        return try await page(from: "sage_list", arguments: arguments)
    }

    func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage {
        var arguments: [String: JSONValue] = [
            "query": .string(query),
            "top_k": .int(limit)
        ]
        if let topic, !topic.isEmpty { arguments["domain"] = .string(topic) }
        return try await page(from: "sage_recall", arguments: arguments)
    }

    func forget(id: String) async throws -> ForgetOutcome {
        let payload = try await payload(
            from: "sage_forget",
            arguments: ["memory_id": .string(id), "reason": .string("the owner asked Mynah to forget it")]
        )
        // The node distinguishes "gone" from "asked to go". Collapsing the two
        // would make Forget look like it worked on a memory that is still there
        // when the owner comes back tomorrow.
        return payload["status"]?.stringValue == "deprecated" ? .forgotten : .stillLettingGo
    }

    // MARK: Transport

    private func page(from tool: String, arguments: [String: JSONValue]) async throws -> MemoryPage {
        let payload = try await payload(from: tool, arguments: arguments)
        guard let entries = payload["memories"]?.arrayValue else {
            log.error("\(tool, privacy: .public) returned no memories array")
            throw MemoryTrouble.unreadable
        }
        let memories = entries.compactMap(Self.memory(from:))
        return MemoryPage(
            memories: memories,
            total: payload["total_count"]?.intValue ?? memories.count
        )
    }

    private func payload(from tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        let client = try connection()
        let text: String
        do {
            text = try await client.call(name: tool, arguments: arguments)
        } catch let error as MCPClientError {
            log.error("\(tool, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .missingExecutable:
                throw MemoryTrouble.notSetUp
            case .toolFailed(_, let detail), .rpcError(_, let detail):
                // A shut vault and a genuine refusal both arrive here, and they
                // send the owner to two different places: one to their
                // passphrase, the other to quitting and reopening. The node's
                // own wording is the only thing that tells them apart from this
                // side, so it is matched rather than guessed at — and anything
                // that does not match keeps the older, vaguer sentence.
                throw MemoryTrouble.reading(refusal: detail)
            case .launchFailed, .notStarted, .serverExited, .timedOut:
                // These all mean the child is gone or wedged; the next attempt
                // must not reuse it.
                reset()
                throw MemoryTrouble.unreachable
            case .malformedResponse:
                throw MemoryTrouble.unreadable
            }
        } catch {
            log.error("\(tool, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            reset()
            throw MemoryTrouble.unreachable
        }

        guard let payload = Self.embeddedObject(in: text) else {
            log.error("\(tool, privacy: .public) returned unparseable text")
            throw MemoryTrouble.unreadable
        }
        return payload
    }

    // MARK: Decoding

    /// Pulls the result object out of the node's reply.
    ///
    /// The reply is not always bare JSON: on the first call of a session the
    /// node prepends a plain-text banner separated by `\n\n---\n\n`, and it can
    /// append a plain-text reminder afterwards. Both are addressed to an AI
    /// agent, not to this app. Brace-matching from the first `{` — skipping
    /// braces inside strings — is the only reading that survives both.
    static func embeddedObject(in text: String) -> JSONValue? {
        if let whole = JSONValue.parse(text), whole.objectValue != nil { return whole }

        // The banner is separated from the payload by a horizontal rule on its
        // own line. Cutting there first means a banner that ever grows a brace
        // of its own cannot capture the brace matcher below.
        var body = text
        if let rule = body.range(of: "\n\n---\n\n", options: .backwards) {
            body = String(body[rule.upperBound...])
        }

        let characters = Array(body)
        guard let start = characters.firstIndex(of: "{") else { return nil }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if isInsideString {
                if character == "\\" { isEscaped = true }
                else if character == "\"" { isInsideString = false }
                continue
            }
            switch character {
            case "\"": isInsideString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return JSONValue.parse(String(characters[start...index]))
                }
            default: break
            }
        }
        return nil
    }

    /// `sage_list` and `sage_recall` publish the same seven fields for a
    /// memory, which is why one decoder serves both.
    static func memory(from entry: JSONValue) -> Memory? {
        guard let id = entry["memory_id"]?.stringValue, !id.isEmpty,
              let content = entry["content"]?.stringValue else { return nil }

        // A memory the owner already asked to forget must not reappear in the
        // list they asked to remove it from.
        if entry["status"]?.stringValue == "deprecated" { return nil }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return Memory(
            id: id,
            text: trimmed,
            topic: (entry["domain"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? "General",
            learned: Self.date(from: entry["created_at"]?.stringValue) ?? .distantPast,
            certainty: Memory.Certainty(score: entry["confidence"]?.doubleValue ?? 0)
        )
    }

    /// The node timestamps with fractional seconds; the formatter has to be
    /// told, and a node that ever stops sending them must not blank every date.
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction = ISO8601DateFormatter()

    static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return withFraction.date(from: raw) ?? withoutFraction.date(from: raw)
    }
}

// MARK: - Screen state

/// Everything the memories screen knows.
///
/// Search and topic both re-query the node rather than filtering the loaded
/// page, so what the owner sees is the whole set every time — which is the
/// entire promise of this screen.
@MainActor
@Observable
final class MemoriesModel {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(MemoryTrouble)
    }

    /// One page. Big enough that most owners never see "Show more", small
    /// enough that the first paint is not gated on a thousand rows.
    private static let pageSize = 60
    /// Semantic search has no pagination — the node ranks and cuts. Asking for
    /// more than this would be asking it to rank noise.
    private static let searchLimit = 40
    /// Long enough that typing a word does not fire four queries, short enough
    /// that a pause feels like an answer rather than a delay.
    private static let searchDelay = Duration.milliseconds(280)

    private let store: any MemoryStoring
    private let log = Logger(subsystem: "com.sage.mynah", category: "memories")

    private(set) var phase: Phase = .loading
    private(set) var memories: [Memory] = []
    private(set) var hasMore = false
    private(set) var isLoadingMore = false

    /// Topics offered in the filter, taken from what has been loaded. It is
    /// only ever a superset of nothing — a topic cannot appear here unless a
    /// memory in it exists — so the menu never promises an empty result.
    private(set) var topics: [String] = []

    /// Memories the node accepted a forget for but has not finished releasing.
    /// They stay on screen, marked, because claiming they are gone is a lie the
    /// owner can catch.
    private(set) var stillLettingGo: Set<String> = []
    private(set) var forgetInFlight: Set<String> = []
    private(set) var forgetTrouble: MemoryTrouble?

    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }

    var topic: String? {
        didSet {
            guard topic != oldValue else { return }
            selection = nil
            Task { await load() }
        }
    }

    var selection: Memory.ID?
    /// The memory the confirmation dialog is about. Non-nil is what presents it.
    var pendingForget: Memory?

    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init(store: any MemoryStoring = SageMemoryStore.shared) {
        self.store = store
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The one number on this screen, and it counts rows the owner can see —
    /// not the node's total, which includes things filtered out on the way here.
    var visibleCount: Int { memories.count }

    // MARK: Loading

    func loadIfNeeded() async {
        guard memories.isEmpty, phase == .loading else { return }
        await load()
    }

    func load() async {
        loadTask?.cancel()
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        phase = .loading
        do {
            let page = try await fetchFirstPage()
            guard !Task.isCancelled else { return }
            memories = page.memories
            hasMore = !isSearching && page.memories.count < page.total
            mergeTopics(from: page.memories)
            phase = .ready
        } catch let trouble as MemoryTrouble {
            guard !Task.isCancelled else { return }
            phase = .failed(trouble)
        } catch {
            guard !Task.isCancelled else { return }
            log.error("memory load failed: \(String(describing: error), privacy: .public)")
            phase = .failed(.unreachable)
        }
    }

    private func fetchFirstPage() async throws -> MemoryPage {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return try await store.recent(topic: topic, limit: Self.pageSize, offset: 0)
        }
        return try await store.search(query, topic: topic, limit: Self.searchLimit)
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isSearching else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await store.recent(
                topic: topic,
                limit: Self.pageSize,
                offset: memories.count
            )
            // Identity-keyed rather than appended blindly: a memory committed
            // between the two requests shifts the window, and a duplicated row
            // in a list the owner is auditing is worse than a missing one.
            let known = Set(memories.map(\.id))
            let fresh = page.memories.filter { !known.contains($0.id) }
            memories.append(contentsOf: fresh)
            mergeTopics(from: fresh)
            hasMore = !fresh.isEmpty && memories.count < page.total
        } catch {
            log.error("show more failed: \(String(describing: error), privacy: .public)")
            hasMore = false
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled, let self else { return }
            self.selection = nil
            // Through `load()` rather than straight to `performLoad()`, so a
            // search and a topic change racing each other cancel one another
            // instead of both finishing and letting whichever the network
            // favoured decide what the owner sees.
            await self.load()
        }
    }

    private func mergeTopics(from memories: [Memory]) {
        let merged = Set(topics).union(memories.map(\.topic))
        topics = merged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Forgetting

    func confirmForget(_ memory: Memory) {
        pendingForget = memory
    }

    func forget(_ memory: Memory) async {
        guard !forgetInFlight.contains(memory.id) else { return }
        forgetInFlight.insert(memory.id)
        forgetTrouble = nil
        defer { forgetInFlight.remove(memory.id) }

        do {
            switch try await store.forget(id: memory.id) {
            case .forgotten:
                stillLettingGo.remove(memory.id)
                if selection == memory.id { selection = nil }
                memories.removeAll { $0.id == memory.id }
            case .stillLettingGo:
                stillLettingGo.insert(memory.id)
            }
        } catch let trouble as MemoryTrouble {
            forgetTrouble = trouble
        } catch {
            log.error("forget failed: \(String(describing: error), privacy: .public)")
            forgetTrouble = .unreachable
        }
    }
}

// MARK: - Screen

/// The headline feature: everything Mynah remembers, and a way to remove any of
/// it.
///
/// One column. A memory is a sentence with a date; opening one adds the two
/// facts that did not fit — how sure Mynah is, and exactly when — plus the one
/// action that matters. There is no inspector, no metadata grid and no
/// consensus state, because the owner did not buy a database.
struct MemoriesView: View {
    @State private var model: MemoriesModel

    /// `@MainActor` because `MemoriesModel` is, and a `View`'s initialiser is
    /// not isolated by default even though SwiftUI only ever calls it here.
    @MainActor
    init(store: any MemoryStoring = SageMemoryStore.shared) {
        _model = State(initialValue: MemoriesModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls.padding(.top, s6)
            content.padding(.top, s6)
        }
        .frame(maxWidth: MynahWidth.memoryDetail, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, s8)
        .padding(.top, s7)
        .padding(.bottom, s8)
        .background(Palette.surface.canvas)
        .task { await model.loadIfNeeded() }
        .confirmationDialog(
            "Forget this?",
            isPresented: Binding(
                get: { model.pendingForget != nil },
                set: { if !$0 { model.pendingForget = nil } }
            ),
            presenting: model.pendingForget
        ) { memory in
            Button("Forget it", role: .destructive) {
                model.pendingForget = nil
                Task { await model.forget(memory) }
            }
            Button("Keep it", role: .cancel) { model.pendingForget = nil }
        } message: { _ in
            Text("Mynah won't be able to use this again, and it can't be brought back.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: s2) {
            Text("What Mynah remembers")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
            countLine
        }
    }

    @ViewBuilder
    private var countLine: some View {
        switch model.phase {
        case .loading, .failed:
            // Nothing truthful to count yet. An animating zero would read as
            // "Mynah remembers nothing about you", which is a different and
            // much worse statement than "still looking".
            Color.clear.frame(height: 1)
        case .ready:
            Text(countSentence)
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .mynahAnimation(Motion.fade, value: model.visibleCount)
        }
    }

    private var countSentence: String {
        let count = model.visibleCount
        if model.isSearching {
            return count == 1 ? "1 match" : "\(count) matches"
        }
        if count == 0 { return "Nothing yet" }
        return count == 1 ? "1 thing" : "\(count) things"
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: s4) {
            MemorySearchField(text: Binding(
                get: { model.searchText },
                set: { model.searchText = $0 }
            ))
            if model.topics.count > 1 { topicPicker }
        }
    }

    /// A `Menu` wearing MYNAH's secondary button, not a stock pop-up.
    ///
    /// It sits in the same row as `MemorySearchField`, which is a fully custom
    /// control ~34pt tall with a 10pt continuous radius and a hairline. A macOS
    /// pop-up button at regular size is ~22pt with the system bezel, gradient
    /// and accent chevron, so the row paired a bespoke field with an obviously
    /// stock control of a different height, radius, border and colour. Settings'
    /// text-size picker stays stock on purpose — it lives in a `SettingsRow`,
    /// where a native pop-up is the correct Mac idiom.
    private var topicPicker: some View {
        Menu {
            Button("Everything") { model.topic = nil }
            Divider()
            ForEach(model.topics, id: \.self) { topic in
                Button(topic) { model.topic = topic }
            }
        } label: {
            HStack(spacing: s3) {
                Text(model.topic ?? "Everything")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: s3)
                Image(systemName: "chevron.down")
                    .mynahIcon(.inline)
                    .foregroundStyle(Palette.ink.tertiary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.mynahSecondary)
        .menuIndicator(.hidden)
        .frame(width: 168)
        .help("Show only what Mynah remembers about one thing")
        .accessibilityLabel("Filter by topic")
        .accessibilityValue(model.topic ?? "Everything")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: s4) {
                ThinkingIndicator()
                Text("Looking through what Mynah remembers…")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
            }
            .padding(.vertical, s6)

        case .failed(let trouble):
            InlineBanner(
                tone: .critical,
                headline: trouble.headline,
                explanation: trouble.explanation,
                actionTitle: "Try again",
                action: { Task { await model.load() } }
            )

        case .ready:
            if model.memories.isEmpty {
                emptyState.padding(.top, s8)
            } else {
                list
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSearching {
            EmptyState(
                glyph: "magnifyingglass",
                title: "Nothing matched",
                message: "Mynah searches by meaning rather than spelling, so try describing "
                    + "the thing rather than quoting it."
            )
        } else if model.topic != nil {
            EmptyState(
                glyph: "text.append",
                title: "Nothing about that yet",
                message: "Mynah hasn't learned anything on this subject.",
                actionTitle: "Show everything",
                action: { model.topic = nil }
            )
        } else {
            // Careful with this sentence, which has now been wrong twice.
            //
            // It first read "No memories yet — Mynah will start remembering once
            // you talk to it", which was true only while the screen browsed as
            // the node operator and could see everything on the machine. Mynah
            // signs as itself (`MynahIdentity`), so an empty list means "nothing
            // this agent can see" and not "nothing is there".
            //
            // The replacement then said "This fills up as you talk to it", and
            // on the machine this was written for that was a false promise: the
            // appliance had stored zero memories against 13,357 on the node,
            // because every failed write was being swallowed by a log sink that
            // defaulted to doing nothing. The screen had no way to know — and
            // still has none. An empty list is consistent with three different
            // situations and this view can only distinguish one of them.
            //
            // So it states the fact it can verify and stops. No promise about
            // what happens next, and an explicit acknowledgement that silence
            // here can also mean something is wrong, because an owner who has
            // been talking to Mynah for a week and sees this needs to suspect a
            // fault rather than conclude they have not said enough yet.
            EmptyState(
                glyph: "text.append",
                title: "Mynah hasn't kept anything yet",
                message: "It keeps its own memories, separate from the other agents on your SAGE "
                    + "node, so this stays empty until it saves one. If you have been talking to "
                    + "it for a while and this is still empty, something is stopping it — the "
                    + "diagnostics in Settings are the thing to send."
            )
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let trouble = model.forgetTrouble {
                    InlineBanner(
                        tone: .critical,
                        headline: "Mynah couldn't forget that.",
                        explanation: trouble.explanation
                    )
                    .padding(.bottom, s5)
                }

                ForEach(Array(model.memories.enumerated()), id: \.element.id) { index, memory in
                    MemoryEntry(
                        memory: memory,
                        isSelected: model.selection == memory.id,
                        isReleasing: model.stillLettingGo.contains(memory.id),
                        isForgetting: model.forgetInFlight.contains(memory.id),
                        onSelect: { model.selection = model.selection == memory.id ? nil : memory.id },
                        onForget: { model.confirmForget(memory) }
                    )
                    if index < model.memories.count - 1 {
                        MynahDivider(leadingInset: s4)
                    }
                }

                if model.hasMore { showMoreRow.padding(.top, s5) }
            }
            .padding(.bottom, s6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var showMoreRow: some View {
        HStack {
            Spacer(minLength: 0)
            if model.isLoadingMore {
                ThinkingIndicator()
            } else {
                MynahButton("Show more", kind: .quiet) {
                    Task { await model.loadMore() }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - One memory

/// A row that opens.
///
/// Collapsed it is the foundation's `MemoryRow` — a sentence, when, what about.
/// Open it becomes the whole sentence with nothing clipped, the exact date, how
/// sure Mynah is, and Forget. A sheet would be heavier than the content, and an
/// inspector column would make a browsing screen into a database viewer.
private struct MemoryEntry: View {
    let memory: Memory
    let isSelected: Bool
    let isReleasing: Bool
    let isForgetting: Bool
    let onSelect: () -> Void
    let onForget: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelect) {
                collapsedOrOpen
                    .contentShape(RoundedRectangle.mynah(r.control))
                    // Full Keyboard Access rings the *focus effect* shape, which
                    // defaults to bounds — square corners over a 10pt continuous
                    // row.
                    .contentShape(.focusEffect, RoundedRectangle.mynah(r.control))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isSelected { detail }
        }
        .background(
            isSelected ? Palette.accent.wash : (isHovering ? Palette.surface.well : .clear),
            in: RoundedRectangle.mynah(r.control)
        )
        .onHover { isHovering = $0 }
        .mynahAnimation(Motion.snap, value: isSelected)
        .mynahAnimation(Motion.fade, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(memory.text)
        .accessibilityValue("Learned \(memory.learned.formatted(.relative(presentation: .named))), \(memory.topic)")
    }

    @ViewBuilder
    private var collapsedOrOpen: some View {
        if isSelected {
            // The whole sentence, unclipped. A screen that promises the owner
            // can see everything Mynah remembers must not truncate the thing
            // they opened in order to read.
            VStack(alignment: .leading, spacing: s2) {
                Text(memory.text)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(memory.topic)
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
            }
            .padding(.horizontal, s4)
            .padding(.vertical, s4)
        } else {
            MemoryRow(text: memory.text, date: memory.learned, topic: memory.topic)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: s4) {
            if isReleasing {
                Text("Mynah has been asked to forget this, and hasn't finished yet. "
                    + "It should be gone shortly.")
                    .mynahFont(.callout)
                    // Work in progress, not a fault. Amber here says something
                    // went wrong with a deletion that is going exactly to plan,
                    // and consensus taking a moment is the ordinary case rather
                    // than the alarming one.
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: s3) {
                // A memory the node sent without a timestamp is still a memory,
                // and it still belongs on a screen that promises the owner can
                // see everything. It says so rather than inventing a date or
                // quietly vanishing from the list.
                factLine(
                    "Learned",
                    memory.learned == .distantPast
                        ? "Not recorded"
                        : memory.learned.formatted(date: .long, time: .shortened)
                )
                factLine("How sure Mynah is", memory.certainty.word)
            }

            Text(memory.certainty.sentence)
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: s4) {
                Spacer(minLength: 0)
                if isForgetting {
                    Text("Forgetting…")
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                } else {
                    // A destructive action is a secondary button with critical
                    // *text*, never a filled red button — the fill turns a
                    // reversible-feeling browse screen into an alarm. The colour
                    // goes on the `Text` rather than the `Button`, because the
                    // shared style sets the label's foreground itself.
                    Button(action: onForget) {
                        Text("Forget this").foregroundStyle(Palette.state.critical)
                    }
                    .buttonStyle(.mynahSecondary)
                }
            }
        }
        .padding(.horizontal, s4)
        .padding(.bottom, s4)
        .transition(.push(from: .top).combined(with: .opacity))
    }

    private func factLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: s4) {
            Text(title)
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
                .frame(width: 132, alignment: .leading)
            Text(value)
                .mynahFont(.bodyEmphasis)
                .foregroundStyle(Palette.ink.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Search field

/// The app's search input.
///
/// Not `.searchable()`: that hangs the field off the window toolbar, which
/// already carries the one control this shell allows, and it would disappear
/// the moment the toolbar collapses. This sits where the owner is looking.
private struct MemorySearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: s3) {
            Image(systemName: "magnifyingglass")
                .mynahIcon(.inline)
                .foregroundStyle(Palette.ink.tertiary)

            TextField("Search what Mynah remembers", text: $text)
                .textFieldStyle(.plain)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.primary)
                .focused($isFocused)

            if !text.isEmpty {
                MynahButton("Clear", kind: .quiet) { text = "" }
                    .padding(.trailing, -s3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.control))
        .mynahBorder(r.control, isFocused ? Palette.accent.fill.opacity(0.65) : Palette.line.hairline)
        .overlay {
            if isFocused {
                RoundedRectangle.mynah(r.control + 3)
                    .strokeBorder(Palette.accent.fill.opacity(0.30), lineWidth: 3)
                    .padding(-3)
            }
        }
        .mynahAnimation(Motion.fade, value: isFocused)
    }
}

// MARK: - Previews

/// Preview data, and the reason `MemoryStoring` exists.
///
/// Named so it can never be mistaken for the shipping store: nothing in the app
/// constructs this, and the app's default argument is the real one.
struct PreviewMemoryStore: MemoryStoring {
    var memories: [Memory]
    var trouble: MemoryTrouble?
    var forgetIsSlow = false

    static let sample: [Memory] = [
        Memory(
            id: "1",
            text: "Prefers the espresso machine descaled every three weeks, not monthly — "
                + "the water here is hard enough that monthly leaves scale in the group head.",
            topic: "Home",
            learned: Date().addingTimeInterval(-3_600),
            certainty: .certain
        ),
        Memory(
            id: "2",
            text: "Flying to Kuala Lumpur on the 14th. Wants the 6am departure, not the redeye.",
            topic: "Travel",
            learned: Date().addingTimeInterval(-86_400 * 2),
            certainty: .fairlySure
        ),
        Memory(
            id: "3",
            text: "Someone called Marcus is meant to be picking up the keys, possibly on Thursday.",
            topic: "Home",
            learned: Date().addingTimeInterval(-86_400 * 9),
            certainty: .unsure
        )
    ]

    func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage {
        if let trouble { throw trouble }
        let filtered = topic.map { name in memories.filter { $0.topic == name } } ?? memories
        return MemoryPage(memories: Array(filtered.dropFirst(offset).prefix(limit)), total: filtered.count)
    }

    func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage {
        if let trouble { throw trouble }
        let matched = memories.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return MemoryPage(memories: matched, total: matched.count)
    }

    func forget(id: String) async throws -> ForgetOutcome {
        if let trouble { throw trouble }
        return forgetIsSlow ? .stillLettingGo : .forgotten
    }
}

private struct MemoriesPreviewPair: View {
    let store: PreviewMemoryStore

    var body: some View {
        HStack(spacing: 0) {
            MemoriesView(store: store).environment(\.colorScheme, .light)
            MemoriesView(store: store).environment(\.colorScheme, .dark)
        }
    }
}

#Preview("Memories") {
    MemoriesPreviewPair(store: PreviewMemoryStore(memories: PreviewMemoryStore.sample))
        .frame(width: 1500, height: 760)
}

#Preview("Memories — nothing yet") {
    MemoriesPreviewPair(store: PreviewMemoryStore(memories: []))
        .frame(width: 1500, height: 620)
}

#Preview("Memories — can't reach it") {
    MemoriesPreviewPair(store: PreviewMemoryStore(memories: [], trouble: .unreachable))
        .frame(width: 1500, height: 520)
}
