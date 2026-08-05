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

    /// **There was a `Certainty` here and it is gone entirely.**
    ///
    /// It turned the node's confidence float into "Certain" / "Fairly sure" /
    /// "Not sure" and printed it in the opened card, on the reasoning that the
    /// owner should never see `0.82` because that is a fact about a consensus
    /// algorithm. That reasoning was right and stopped one step short: a fact
    /// about a consensus algorithm does not get better by being rounded into
    /// English. It is still a number from the machine's own bookkeeping, and
    /// nothing the owner reads it as changes what they do next.
    ///
    /// *"the how sure mynah is etc is fucking irrelevant bro — you only want to
    /// show the user shit that matters."*
    ///
    /// What matters, and is now all this card carries: what it says, what it is
    /// filed under, whether it is a task or something remembered, when it was
    /// stored, and the one button that acts on it.

    /// Which kind of thing this row is.
    ///
    /// SAGE stores a task and a memory in the same list, and the only thing
    /// telling them apart was the literal `[TASK] ` the node prefixes onto the
    /// text — which the owner was left to parse by eye, in the middle of a
    /// sentence, on every row.
    enum Kind: Sendable, Hashable {
        case remembered
        case task

        var word: String {
            switch self {
            case .remembered: return "Memory"
            case .task: return "Task"
            }
        }
    }

    let id: String
    let text: String
    /// The node's own name for where this memory is filed, or `nil` when it
    /// filed it under none.
    ///
    /// Separate from `topic` — the word the owner reads — because **a label is
    /// not a query key**, and this screen spent a day proving it. `topic`
    /// invents "General" for a memory with no domain, that invented word went
    /// into the filter menu, and picking it sent `domain: "General"` back to a
    /// node that has no such domain. From `mynah.log` on 31 July:
    ///
    ///     domain not found: sage-v11-development
    ///     domain name contains whitespace
    ///
    /// Neither is a name this screen should ever have been able to send. Only
    /// `domain` may be put in a query, and only when it is non-nil.
    let domain: String?
    let learned: Date

    /// The node's marker, read once here rather than by the owner on every row.
    var kind: Kind {
        text.hasPrefix(Self.taskMarker) ? .task : .remembered
    }

    /// The sentence without the machine's prefix on the front of it.
    ///
    /// `[TASK] Book hotel for Wednesday` is the node talking to itself. The
    /// owner gets "Book hotel for Wednesday" and a chip that says Task, which
    /// is the same information in the place they were already looking.
    var displayText: String {
        kind == .task
            ? String(text.dropFirst(Self.taskMarker.count)).trimmingCharacters(in: .whitespaces)
            : text
    }

    private static let taskMarker = "[TASK]"

    /// What the memory is about, as the owner reads it.
    ///
    /// A memory the node filed under no domain still has to say something in a
    /// column headed by what it is about, so this invents a word. That is fine
    /// for a label and fatal for a filter — see `domain`.
    ///
    /// `MemorySubjectName` handles the other end of the same problem: the
    /// node's name for an agent's home domain is that agent's public key, which
    /// is true, unique, and unreadable.
    var topic: String {
        guard let domain else { return "General" }
        return MemorySubjectName.display(
            domain,
            applianceAgentID: SageAgentIdentity.applianceAgentID()
        )
    }
}

/// One page of memories, plus how many exist behind it.
struct MemoryPage: Sendable {
    var memories: [Memory]
    /// What the node says the whole filtered set contains. Used only to decide
    /// whether a "Show more" row is honest, never rendered as a count — the
    /// number the owner sees is the number of rows they can actually see.
    var total: Int

    /// Whether every domain this page claims to cover actually answered.
    ///
    /// **A page that cannot testify about every domain must not replace the
    /// list on screen.** `refresh()` assigns `memories = page.memories` outright
    /// on the stated ground that a first page "is the whole truth". That was
    /// sound when `recent()` was one call that either succeeded or threw; once
    /// it became a per-domain merge that tolerates a refusal, a background
    /// refresh could silently delete rows the owner was looking at — no spinner,
    /// no banner, and the count line confidently reporting the smaller number.
    ///
    /// Defaults to `true` so every existing construction keeps meaning what it
    /// said: only the merge knows how to be partial.
    var isComplete: Bool = true

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
    /// The question was too wide for the node to authorize in one pass.
    ///
    /// Distinct from `refused` for the same reason `locked` is: quitting and
    /// reopening asks the identical too-wide question and gets the identical
    /// answer, so sending the owner round that loop is guaranteed to waste
    /// their time. Narrowing is the only thing that works, and they can do it.
    case tooBroad
    /// The filter names a domain the node will not resolve.
    ///
    /// The remedy is one click — clear the filter — and it is emphatically not
    /// a reinstall, which is where `refused` used to send people.
    case unknownTopic

    var headline: String {
        switch self {
        case .notSetUp: return "Mynah hasn't got a memory on this Mac yet."
        case .unreachable: return "Mynah can't get to what it remembers."
        case .refused: return "Mynah wouldn't open its memory."
        case .locked: return "Your SAGE node is locked."
        case .unreadable: return "Mynah's memory answered with something unexpected."
        case .tooBroad: return "Ask for a narrower slice of what Mynah remembers."
        case .unknownTopic: return "Choose Everything to get the list back."
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
            // "Copy", because that is what the button in Settings says. It was
            // "send", and the owner went looking for a Send and reported that
            // there was no diagnostics in Settings at all. There is; it is
            // called something else. Instructions that name a control have to
            // use the control's own word.
            return "Quit Mynah and open it again. If it still won't open, copy the diagnostics "
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
        case .tooBroad:
            // No "try again", deliberately. The same request fails the same way
            // every time, and an owner who has been told to retry will retry.
            return "There is more here than Mynah can check the permissions on in one go. "
                + "Search for what you're after, or pick a single topic — everything is "
                + "still there, and both ask a question small enough to answer."
        case .unknownTopic:
            return "The topic you picked isn't one Mynah's memory recognises any more. "
                + "Nothing has been lost — clear the filter and the rest comes back."
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
        if locked.contains(where: said.contains) { return .locked }

        // **Measured, signing as the appliance's own key rather than as a
        // developer's.** That distinction is the whole reason this took a day:
        // every check of `sage_list` had been made over a Claude Code MCP
        // connection, which signs as an agent with far more standing, and it
        // returned memories every time. Asked as Mynah, the plain unfiltered
        // first page — the one the owner lands on — answers:
        //
        //     Query too broad: app-v23 authorization scan budget exceeded
        //
        // which fell through to `.refused`, whose advice is to quit and reopen.
        // The next launch asks the same too-wide question and gets the same
        // refusal, so the screen was telling the owner to do the one thing that
        // provably could not work, forever.
        let tooBroad = ["query too broad", "scan budget exceeded", "too many domains"]
        if tooBroad.contains(where: said.contains) { return .tooBroad }

        // From the same log: `domain not found: sage-v11-development` — another
        // agent's domain, offered as a filter chip by this screen — and
        // `domain name contains whitespace`. `Memory.domain` stops this screen
        // manufacturing either. This stays because the node may retire a domain
        // while it is the selected filter, and that is a real state with a
        // one-click answer rather than a reinstall.
        let unknownTopic = ["domain not found", "contains whitespace", "unknown domain"]
        if unknownTopic.contains(where: said.contains) { return .unknownTopic }

        return .refused
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

    /// The domains this appliance owns, according to the node.
    ///
    /// On the protocol because the *controls* need it, not just the queries.
    /// Scoping the list and the search was done by asking `sage_domains`, while
    /// `isMynahs` — which decides whether a card gets a Forget cross, and what
    /// "forget everything Mynah owns" walks — kept using a hardcoded pair. So a
    /// third owned domain would have been listed and shown and then quietly
    /// treated as somebody else's.
    func domainsMynahOwns() async -> [String]
}

extension MemoryStoring {
    /// Stores that have no node to ask fall back to the pair that was hardcoded.
    func domainsMynahOwns() async -> [String] { MynahOwnedDomains.knownPair }
}

/// The domains this appliance is known to write to, for when the node cannot say.
///
/// **One copy, because there were two and they were the same list.** The store's
/// fallback and the model's `ownDomains` both spelled out `voice-interface` and
/// `mynah-home`; adding a third owned domain meant remembering both, and the
/// whole class of bug being fixed here is a fix applied to one site while an
/// identical one goes unwatched.
///
/// Both are established rather than guessed. `voice-interface` is
/// `SageRitual.memoryDomain`, this app's own constant for where it stores what it
/// is told. `mynah-home` is not this identity's: a `sage_backlog` signed as the
/// Claude Code agent returns `local-<that id>` and `voice-interface` and never
/// `mynah-home`, and a `sage_list` for it is refused with "agent does not have
/// read access".
///
/// **A fallback, never the answer.** Falling back to these beats falling back to
/// unscoped: a node that cannot answer should cost the owner a domain he rarely
/// has, not show him somebody else's memories under his own heading — or worse,
/// offer him a Forget cross on them.
/// **It is no longer a pair, and the reason matters more than the count.**
///
/// `voice-interface` was never Mynah's. It is the developer's own agent's
/// subject — readable by this appliance, absent from its `writable_domains`,
/// and confirmed as such by the owner on 5 August: *"voice-interface is YOUR
/// DOMAIN - we will transfer it back to you"*. Listing it here offered the owner
/// a Forget cross on another agent's memories, which is the exact harm the note
/// above says this fallback exists to prevent.
///
/// Signed as the appliance key `74140c2d…` against his live 11.17.9 node,
/// `sage_status` returns `owned_domains: [mynah-home, sage-v3.6.0-audit,
/// user-interaction]` — so `mynah-home` is right, and the real answer is to ask
/// rather than to keep a list here at all. This stays as the fallback for a node
/// that will not answer.
enum MynahOwnedDomains {
    static let knownPair = [SageRitual.memoryDomain]
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

    private let log = MynahLog(category: "memories")

    private var client: MCPClient?

    /// What `sage_domains` said this appliance owns, asked once per connection.
    /// See `ownedDomains()`.
    private var cachedOwnedDomains: [String]?

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

    /// The same signed connection, for anything else on this Mac that needs to
    /// talk to the node as the appliance.
    ///
    /// Exposed rather than duplicated because an `MCPClient` **spawns a node
    /// process**. A second one for the agent inbox would be a second
    /// `sage-gui mcp` child answering as the same identity, and this codebase
    /// has already paid once for two things believing they were the appliance —
    /// the ghost key, which the node answered emptily rather than refusing.
    /// One appliance, one connection.
    func toolProvider() throws -> any ToolProviding {
        try connection()
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
        // Cleared with the connection it was read over. A node that came back
        // may have come back as a different one, and a stale owned-domain list
        // is how this screen would go on scoping to a domain that is no longer
        // Mynah's.
        cachedOwnedDomains = nil
    }

    // MARK: Queries

    func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage {
        if let topic, !topic.isEmpty {
            return try await page(from: "sage_list", arguments: [
                "limit": .int(limit),
                "offset": .int(offset),
                "sort": .string("newest"),
                "domain": .string(topic)
            ])
        }
        return try await everythingMynahOwns(limit: limit, offset: offset)
    }

    /// The unfiltered list, asked one owned domain at a time.
    ///
    /// **It used to ask with no `domain` at all, and that is not the same
    /// question.** Unscoped, `sage_list` answers with everything this agent may
    /// *read*, and the owner watched his Memories screen — headed "What Mynah
    /// remembers" — fill up with `mynah-sage-auth` entries: the SAGE team's own
    /// working notes, *"SAGE v11.17.5 patch release…"*, *"[DON'T] Do not disrupt
    /// Chrome tabs owned by another active control session"*. Fifty-nine things,
    /// most of them nothing to do with him.
    ///
    /// Reading them may well be permitted — a Companion profile reads within
    /// clearance and writes only to its own home — but *permitted to read* and
    /// *its own* are different sentences, and only one of them is what that
    /// heading promises. The destructive path never had this confusion:
    /// `forgetEverythingMynahOwns` has always filtered to the owned set first,
    /// so nothing of another agent's was ever at risk.
    ///
    /// Merged in memory rather than paged by the node, because `sage_list` takes
    /// one domain and there is no cross-domain cursor. Each domain is asked for
    /// `offset + limit` newest, the results are merged by date and then sliced —
    /// correct as long as no single domain is starved, which two domains and a
    /// page size in the tens comfortably satisfies. If that stops being true the
    /// symptom is a missing older row, not a wrong one.
    private func everythingMynahOwns(limit: Int, offset: Int) async throws -> MemoryPage {
        let domains = await ownedDomains()

        var everything: [Memory] = []
        var total = 0
        var lastError: Error?
        var incomplete = false
        for domain in domains {
            do {
                let page = try await page(from: "sage_list", arguments: [
                    "limit": .int(offset + limit),
                    "offset": .int(0),
                    "sort": .string("newest"),
                    "domain": .string(domain)
                ])
                everything.append(contentsOf: page.memories)
                total += page.total
            } catch MemoryTrouble.tooBroad {
                // **`.tooBroad` is the one error the caller can actually fix,
                // and swallowing it here defeated the fix.**
                //
                // `fetchFirstPage` exists to catch exactly this and re-ask at 20
                // rows, then 8. Each domain here is asked for `offset + limit` —
                // 60 on the first page, the size the owner's own node refuses
                // with "scan budget exceeded". When one domain answered and the
                // other was refused, this returned *success*, the ladder never
                // fired, the screen went `.ready`, and an entire class of his
                // memories — realistically his task list — was simply absent
                // with no error anywhere.
                //
                // The comment below is a real ruling and still holds for every
                // other error. It is a false dichotomy for this one: the third
                // option is to ask smaller and get everything, which is what the
                // ladder above was written to do.
                throw MemoryTrouble.tooBroad
            } catch {
                // One unreadable domain must not blank the screen. The owner
                // seeing half his memories beats him seeing an error where his
                // memories were.
                log.error("listing \(domain) failed: \(String(describing: error))")
                lastError = error
                incomplete = true
            }
        }
        if everything.isEmpty, let lastError { throw lastError }

        let newestFirst = everything.sorted { $0.learned > $1.learned }
        let window = newestFirst.dropFirst(offset).prefix(limit)
        return MemoryPage(memories: Array(window), total: total, isComplete: !incomplete)
    }

    /// The domains this appliance actually owns, from the node.
    ///
    /// `sage_domains` is 11.17.4's answer to exactly this question — "this
    /// signed caller's authoritative current owned domains" — and it replaces a
    /// hardcoded pair that was right only for as long as nobody added a third.
    ///
    /// Cached for the life of the connection: ownership does not change while
    /// the app is open, and this is on the path of every page of every scroll.
    ///
    /// **Falls back to the known pair rather than to unscoped.** Unscoped is not
    /// the cautious choice here — it is the bug. A node that cannot answer
    /// should cost the owner a domain he rarely has, not show him somebody
    /// else's memories under his own heading.
    func domainsMynahOwns() async -> [String] { await ownedDomains() }

    private func ownedDomains() async -> [String] {
        if let cachedOwnedDomains { return cachedOwnedDomains }

        let fallback = MynahOwnedDomains.knownPair
        do {
            let payload = try await payload(from: "sage_domains", arguments: [:])
            let named = (payload["domains"]?.arrayValue ?? []).compactMap {
                $0.stringValue ?? $0["domain"]?.stringValue ?? $0["name"]?.stringValue
            }
            guard !named.isEmpty else {
                log.error("sage_domains named none, so falling back to the known pair")
                cachedOwnedDomains = fallback
                return fallback
            }
            cachedOwnedDomains = named
            return named
        } catch {
            log.error("sage_domains failed, falling back to the known pair: \(String(describing: error))")
            cachedOwnedDomains = fallback
            return fallback
        }
    }

    /// **The scoping fix landed on the list and not on the search.**
    ///
    /// With a topic picked, `sage_recall` is asked for that domain and comes
    /// back scoped. With none, it is asked for nothing in particular — and an
    /// unscoped recall answers with everything this caller may *read*, which is
    /// precisely the question that put the SAGE team's working notes on a screen
    /// headed "What Mynah remembers". The owner reported that; `recent` was
    /// fixed and this was not, one method below it.
    ///
    /// Filtered after the fact rather than asked N times: `sage_recall` takes
    /// one domain and ranks by relevance across the corpus, so N top-k requests
    /// merged locally would be a different and worse ordering. Dropping what is
    /// not Mynah's keeps the node's ranking and shows only what the heading
    /// claims.
    func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage {
        var arguments: [String: JSONValue] = [
            "query": .string(query),
            "top_k": .int(limit)
        ]
        if let topic, !topic.isEmpty { arguments["domain"] = .string(topic) }
        let found = try await page(from: "sage_recall", arguments: arguments)
        guard topic?.isEmpty ?? true else { return found }

        let owned = Set(await ownedDomains().map { $0.lowercased() })
        let mine = found.memories.filter { memory in
            guard let domain = memory.domain?.lowercased() else { return false }
            return owned.contains(domain)
                || MemorySubjectName.isOwnHome(
                    domain,
                    applianceAgentID: SageAgentIdentity.applianceAgentID()
                )
        }
        return MemoryPage(memories: mine, total: found.total)
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
            log.error("\(tool) returned no memories array")
            throw MemoryTrouble.unreadable
        }
        let memories = entries.compactMap(Self.memory(from:))
        return MemoryPage(
            memories: memories,
            total: payload["total_count"]?.intValue ?? memories.count
        )
    }

    /// Any MCP tool, through the connection this actor already holds.
    ///
    /// Exposed so surfaces other than Memories can reach the node **as the
    /// appliance** without spawning a second one — the handshake costs about
    /// four seconds, and two children would mean two identities' worth of
    /// confusion on a screen that exists to say who Mynah is.
    ///
    /// `ApplianceRoster` is the first caller. It used to read `GET /v1/agents`
    /// unsigned, which is the one endpoint a locked node answers in full, and
    /// therefore the one that cannot answer "who may Mynah contact".
    func callTool(_ tool: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await payload(from: tool, arguments: arguments)
    }

    private func payload(from tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        let client = try connection()
        let text: String
        do {
            text = try await client.call(name: tool, arguments: arguments)
        } catch let error as MCPClientError {
            log.error("\(tool) failed: \(String(describing: error))")
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
            log.error("\(tool) failed: \(String(describing: error))")
            reset()
            throw MemoryTrouble.unreachable
        }

        guard let payload = Self.embeddedObject(in: text) else {
            log.error("\(tool) returned unparseable text")
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
    /// agent, not to this app.
    ///
    /// **The reading moved to `SageReply` and this forwards to it.** It was
    /// written here, correctly, and stayed here — so the task board read a
    /// backlog through it while `SageAgentMessaging` parsed the whole string
    /// and reported an empty inbox every time the node appended a reminder. A
    /// fix that lives only where somebody hit the bug is half a fix.
    static func embeddedObject(in text: String) -> JSONValue? {
        SageReply.value(in: text)
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
            // Trimmed, and `nil` rather than a blank: a domain that arrives
            // padded goes back out padded, and the node rejects its own name
            // with "domain name contains whitespace".
            domain: (entry["domain"]?.stringValue).flatMap {
                let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            },
            // `confidence` is deliberately not read. The node sends it, and it
            // is its own bookkeeping — see `Memory`'s note where `Certainty`
            // used to be.
            learned: Self.date(from: entry["created_at"]?.stringValue) ?? .distantPast
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

    /// The one the app uses. Lives longer than the screen so that leaving
    /// Memories and coming back is free — see `MemoriesView.init`.
    @MainActor static let shared = MemoriesModel(store: SageMemoryStore.shared)

    private let store: any MemoryStoring
    private let log = MynahLog(category: "memories")

    private(set) var phase: Phase = .loading
    private(set) var memories: [Memory] = []
    private(set) var hasMore = false
    private(set) var isLoadingMore = false

    /// A refresh running behind rows that are already on screen. Not rendered as
    /// a spinner anywhere on purpose — the owner did not ask for it, and the
    /// answer usually is "nothing changed".
    private(set) var isRefreshing = false

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
            // `performLoad` clears a filter the node has stopped resolving and
            // then reloads *in its own task*, so letting this fire there would
            // start a second, racing load — and the reload the owner sees would
            // be whichever of the two the scheduler favoured.
            guard !isRepairingFilter else { return }
            selection = nil
            // `startLoad()` and not `Task { await load() }` — see `startLoad`.
            // The spawned form registered the task too late to be cancellable,
            // so a caller that loaded straight after changing the filter got two
            // loads and kept whichever the scheduler favoured.
            startLoad()
        }
    }

    /// Set while `performLoad` is clearing a filter on the owner's behalf. See
    /// the `didSet` above, which must not treat that as the owner choosing.
    private var isRepairingFilter = false

    /// Domains the node refused to resolve while this screen has been open.
    ///
    /// Removing a dead chip is not enough on its own, because the name comes
    /// back: the memories still *report* that domain, so the next successful
    /// load merges it straight back into the menu. The owner picks it again,
    /// it fails again, and the screen quietly repairs itself again — a filter
    /// that flickers rather than one that works.
    ///
    /// Session-scoped deliberately. A domain that starts resolving between one
    /// launch and the next should be offered again; the node's answer is the
    /// authority, and this only remembers the answers it has actually heard.
    private var unresolvableTopics: Set<String> = []

    var selection: Memory.ID?
    /// The memory the confirmation dialog is about. Non-nil is what presents it.
    var pendingForget: Memory?
    /// Presenting the confirmation for clearing everything Mynah owns.
    var isConfirmingClear = false
    /// The second question, asked only when nothing is filtered.
    var isConfirmingClearEverything = false
    var isClearing = false
    /// What the last bulk clear did, including what it deliberately did not do.
    var clearedReport: String?

    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init(store: any MemoryStoring = SageMemoryStore.shared) {
        self.store = store
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Which shelf of this page the owner is looking at.
    ///
    /// The owner: *"we should have a filter on this page -> all / tasks only"*,
    /// and then *"we can't view or remove files - should be in this what mynah
    /// remembers section - a sub tab where you have filter by all / tasks - put
    /// a files box"*.
    ///
    /// Files sit here rather than on a page of their own because they are the
    /// same question — what has this appliance kept — and because there was no
    /// answer to it anywhere: three directories have been accumulating notes,
    /// converted documents and every photo ever sent, and nothing listed them.
    enum Shelf: String, CaseIterable, Identifiable, Sendable {
        case all
        case tasks
        case files

        var id: String { rawValue }

        var word: String {
            switch self {
            case .all: return "All"
            case .tasks: return "Tasks"
            case .files: return "Files"
            }
        }
    }

    var shelf: Shelf = .all {
        didSet {
            guard shelf != oldValue else { return }
            selection = nil
            if shelf == .files { Task { await loadFiles() } }
        }
    }

    /// The memories actually on screen.
    ///
    /// Narrowed here rather than at the node: `kind` is derived from the stored
    /// text (`Memory.kind`), so there is no domain or query that means "tasks"
    /// and asking for one would return a different, wrong set.
    /// **The Files shelf shows no memories, and saying so here is what makes the
    /// destructive control safe.**
    ///
    /// This was `shelf == .tasks ? tasks : memories`, so `.files` fell through to
    /// *every* memory. Three things then lined up into the worst bug this screen
    /// has had:
    ///
    ///  - `mynahOwned` filters `shown`, so it was every memory Mynah owns —
    ///    including the whole task list;
    ///  - the Forget-all button renders whenever that is non-empty, so it was on
    ///    screen on a tab that lists photos;
    ///  - `isFiltered` is true on any shelf but All, which *suppresses the second
    ///    confirmation* and switches the dialog to the scoped wording.
    ///
    /// So: open Memories to delete one photo, press a button offering to tidy up,
    /// answer a dialog that says "Forget the ones shown?" — and lose every task,
    /// appointment and preference the appliance has. One click, one confirmation,
    /// and the sentence on the dialog was the opposite of what happened.
    ///
    /// Fixed here rather than by hiding the button, deliberately. A second guard
    /// at the control would leave `mynahOwned` still lying about what is on
    /// screen, and this file has been bitten repeatedly by a fix landing at one
    /// of two sites. An empty list is the truth — there are no memories on the
    /// Files shelf — and every consumer becomes correct at once.
    var shown: [Memory] {
        switch shelf {
        case .all: return memories
        case .tasks: return memories.filter { $0.kind == .task }
        case .files: return []
        }
    }

    /// The one number on this screen, and it counts rows the owner can see —
    /// not the node's total, which includes things filtered out on the way here.
    var visibleCount: Int { shelf == .files ? files.count : shown.count }

    /// How many rows have actually been fetched, whatever the shelf shows of
    /// them. Named in the empty state so "none here" cannot be mistaken for
    /// "none at all" — see `countSentence`.
    var loadedCount: Int { memories.count }

    /// A search or a subject is narrowing the list.
    ///
    /// **This decides what "clear" means, which is why it is a named property
    /// and not an inline check.** The owner: *"we should add a logic then when
    /// its filtered, and i click clear all, it clears the ones filtered ONLY and
    /// not everything"*, and unfiltered *"we should warn first to get double
    /// confirmation they know the impact is it will wipe all tasks etc"*.
    ///
    /// The scoping half was already true and invisible: `mynahOwned` filters
    /// `memories`, and `memories` is whatever the current filter loaded. What
    /// was missing is that nothing on screen said so, and a destructive button
    /// whose blast radius you have to infer from the implementation is one
    /// nobody should press.
    /// Narrowing to Tasks counts, for the same reason a subject does: "Forget
    /// all" must clear what is on screen and nothing else.
    var isFiltered: Bool { isSearching || topic != nil || shelf != .all }

    /// Whether clearing needs a second question.
    ///
    /// Only when nothing is filtered. Narrowing to a subject and clearing it is
    /// an ordinary, recoverable-sized act; clearing everything takes the task
    /// list with it, because a task on this node *is* a memory — which is not
    /// obvious from a page titled "What Mynah remembers".
    var clearingNeedsSecondConfirmation: Bool { !isFiltered }

    // MARK: Loading

    /// **The one place the Memories screen decides whether to cost anything.**
    ///
    /// The model used to be `@State` on the view, so leaving the pane destroyed
    /// it and coming back built an empty one — which meant a full round trip to
    /// the node, a blank screen, and every card redrawn, every single time:
    /// *"we should also cache the memory page so we don't fucking refresh each
    /// and every time"*. The model is shared now, so what was on screen is still
    /// on screen when they come back.
    ///
    /// A cache that never notices anything is a different bug though, so
    /// re-entry still asks the node — quietly, behind what is already drawn, and
    /// changing only what actually changed.
    func loadIfNeeded() async {
        guard !memories.isEmpty || phase != .loading else {
            await load()
            return
        }
        await refresh()
    }

    /// Ask again without taking anything off the screen.
    ///
    /// Deliberately not `load()`. That sets `phase = .loading`, which empties the
    /// list and replaces it with a spinner — correct the first time, and the
    /// whole of what the owner was complaining about on every visit after.
    func refresh() async {
        guard phase == .ready, !isRefreshing, !isSearching else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let page: MemoryPage
        do {
            page = try await fetchFirstPage()
        } catch {
            // A background refresh that fails changes nothing. The owner did not
            // ask for this and is looking at a list that still works; an error
            // banner over good rows would be reporting our problem as theirs.
            // A real failure still surfaces through `load()`, which is what a
            // filter change, a search or Reload goes through.
            log.error("background refresh failed, keeping what is on screen: \(error)")
            return
        }
        guard !Task.isCancelled else { return }

        // **An incomplete page changes nothing at all.**
        //
        // Routing it to the additive branch was wrong and worse than the bug it
        // fixed. That branch inserts unknown rows at the top without a re-sort,
        // on the sound premise that a *whole* first page is the newest N of the
        // whole set — so anything new in it is newer than everything on screen.
        // A partial page is the newest N of a *subset*, so its rows can be older
        // than the bottom of the list and still get pinned above it. And the
        // additive branch never removes, so while any owned domain keeps
        // failing — which `ownedDomains`' fallback pair can make permanent — a
        // memory the owner asked Mynah to forget would stay on this screen for
        // ever, telling him it is still remembered when it is not.
        //
        // A page that cannot testify about every domain is exactly the case
        // `refresh()` already handles above: it is a failed background refresh.
        // Keep what is on screen and say so in the log.
        guard page.isComplete else {
            log.error("background refresh saw only part of the owner's domains; keeping what is on screen")
            return
        }

        if memories.count <= Self.pageSize {
            // Everything on screen is inside the window this page speaks for, so
            // it is the whole truth: new ones in, forgotten ones out.
            //
            // **`page.isComplete` is load-bearing.** "The whole truth" was true
            // when `recent()` was one call that either succeeded or threw. It is
            // now a per-domain merge that tolerates a refusal, so a page can
            // arrive missing an entire domain and still look successful — and
            // this branch would then delete the owner's task list off the screen
            // he was reading, with no spinner and no banner. A page that cannot
            // testify about every domain falls through to the additive branch.
            //
            // Guarded on inequality because assigning an equal array still
            // invalidates the view and redraws every card — which is the flicker
            // this method exists to remove, reintroduced by the fix for it.
            guard page.memories != memories else { return }
            memories = page.memories
            hasMore = page.memories.count < page.total
            mergeTopics(from: page.memories)
        } else {
            // The owner has pressed "Show more", so they are holding rows this
            // page was never asked about. Additive only: anything genuinely new
            // goes on top, and nothing is removed, because a first page cannot
            // testify about the two hundred rows below it. Dropping them here
            // would delete the bottom of the list on every visit.
            let known = Set(memories.map(\.id))
            let fresh = page.memories.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else { return }
            memories.insert(contentsOf: fresh, at: 0)
            mergeTopics(from: fresh)
        }
    }

    /// Replaces whatever load is in flight with a new one, and — the part that
    /// matters — registers it **before returning**.
    ///
    /// The `topic` and `searchText` observers used to start their reload with a
    /// bare `Task { await load() }`. That reads as "the same thing, later", and
    /// the "later" is the bug: `loadTask` was assigned inside the spawned task,
    /// so it was still nil until the scheduler got round to running it. Anything
    /// that called `load()` in that window cancelled nothing, and two loads ran
    /// against one screen.
    ///
    /// Both then raced to finish, and the loser had already cancelled the
    /// winner: whichever load was cancelled returned early at one of the
    /// `Task.isCancelled` guards in `performLoad`, so the repair that clears a
    /// dead filter could be the half that got dropped — leaving the owner
    /// holding a filter that cannot succeed, roughly one time in five.
    ///
    /// Assigning synchronously makes the ordering a fact rather than a
    /// scheduling outcome: by the time this returns there is exactly one
    /// registered load, and the next caller cancels precisely it.
    @discardableResult
    private func startLoad() -> Task<Void, Never> {
        loadTask?.cancel()
        let task = Task { await performLoad() }
        loadTask = task
        return task
    }

    func load() async {
        await startLoad().value
    }

    private func performLoad() async {
        phase = .loading
        // Before the page, so no row is ever laid out — and no Forget cross ever
        // drawn — against a stale idea of what this appliance owns.
        await refreshOwnedDomains()
        do {
            let page = try await fetchFirstPage()
            guard !Task.isCancelled else { return }
            memories = page.memories
            hasMore = !isSearching && page.memories.count < page.total
            mergeTopics(from: page.memories)
            phase = .ready
        } catch let trouble as MemoryTrouble {
            guard !Task.isCancelled else { return }
            // The filter names something the node will not resolve, and the
            // remedy — clear it — needs no owner. Doing it for them beats
            // showing a screen whose only instruction is a click this code
            // could have performed itself.
            //
            // The dead chip goes with it. Leaving it in the menu invites the
            // owner to pick it again and watch the same thing happen.
            if trouble == .unknownTopic, let dead = topic {
                unresolvableTopics.insert(dead)
                topics.removeAll { $0 == dead }
                log.error("dropped the topic filter \(dead): the node does not resolve it")
                isRepairingFilter = true
                topic = nil
                isRepairingFilter = false
                // Inline and awaited, in this task, rather than through the
                // property's `didSet`. That spawns a detached task, so the
                // reload would outlive the load the caller is waiting on and
                // the screen would still be showing "loading" when this
                // returned. Terminating: the filter is nil now, and this branch
                // needs one to run.
                await performLoad()
                return
            }
            phase = .failed(trouble)
        } catch {
            guard !Task.isCancelled else { return }
            log.error("memory load failed: \(String(describing: error))")
            phase = .failed(.unreachable)
        }
    }

    /// How far this screen will narrow its own question before handing the
    /// problem to the owner.
    ///
    /// The node authorizes a listing by scanning what the caller may disclose,
    /// and refuses outright when that scan runs past its budget — so a page
    /// size is not only how much comes back, it is how much has to be checked.
    /// Sixty is the size that fails on the owner's Mac today.
    ///
    /// Asking for less is not a retry in the usual sense: the first request did
    /// not fail for a reason that time or luck can change, it failed because it
    /// was too big, and this is the same question made smaller. A short list the
    /// owner can read and scroll beats a correct-sized request that renders an
    /// error, and `hasMore` already exists to fetch the rest.
    private static let narrowerPages = [20, 8]

    private func fetchFirstPage() async throws -> MemoryPage {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else {
            return try await store.search(query, topic: topic, limit: Self.searchLimit)
        }

        var lastTrouble: MemoryTrouble = .tooBroad
        for limit in [Self.pageSize] + Self.narrowerPages {
            do {
                return try await store.recent(topic: topic, limit: limit, offset: 0)
            } catch MemoryTrouble.tooBroad {
                guard !Task.isCancelled else { throw MemoryTrouble.tooBroad }
                lastTrouble = .tooBroad
                log.error("\(limit) memories was too broad to authorize; asking for fewer")
            }
        }
        // Every size refused. The owner is told to narrow it themselves, which
        // is now a true instruction rather than a guess — this has already
        // tried the cheap version of that advice three times.
        throw lastTrouble
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
            log.error("show more failed: \(String(describing: error))")
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
        // `domain`, never `topic`. This one line is where the label and the
        // query key used to be the same string: every chip built here goes
        // straight back to the node as a `domain` filter, so a chip the node
        // cannot resolve is a filter that cannot succeed. See `Memory.domain`.
        let merged = Set(topics)
            .union(memories.compactMap(\.domain))
            .subtracting(unresolvableTopics)
        topics = merged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The filter menu's own version of `Memory.topic`: what a subject is
    /// called on screen, never what it is called in a query.
    func readableTopic(_ raw: String) -> String {
        MemorySubjectName.display(raw, applianceAgentID: SageAgentIdentity.applianceAgentID())
    }

    // MARK: Files

    /// What is on disk, newest first. Empty until the Files shelf is opened.
    private(set) var files: [SavedFile] = []
    private(set) var isLoadingFiles = false
    private(set) var fileTrouble: String?
    var pendingFileRemoval: SavedFile?

    private let savedFiles = SavedFilesStore()

    /// Read fresh every time the shelf is opened.
    ///
    /// Not cached and not watched: files arrive from a different process — the
    /// daemon writes documents and keeps attachments — so anything this window
    /// remembered would be wrong by the time it was read. Listing three
    /// directories is cheap enough to simply do again.
    func loadFiles() async {
        isLoadingFiles = true
        fileTrouble = nil
        defer { isLoadingFiles = false }
        let store = savedFiles
        files = await Task.detached { store.all() }.value
    }

    func confirmRemove(_ file: SavedFile) {
        pendingFileRemoval = file
    }

    /// Deletes one file and takes it off the list.
    ///
    /// Removed from `files` only after the store says it went, so a failed
    /// delete leaves the row where it is rather than hiding a file that is still
    /// on disk — which is the version of this bug the owner would find months
    /// later, looking for the thing he thought he had removed.
    func remove(_ file: SavedFile) async {
        fileTrouble = nil
        do {
            let store = savedFiles
            try await Task.detached { try store.remove(file) }.value
            files.removeAll { $0.id == file.id }
        } catch {
            log.error("could not remove \(file.name): \(String(describing: error))")
            fileTrouble = "Mynah couldn’t remove \(file.name)."
        }
    }

    // MARK: Forgetting

    func confirmForget(_ memory: Memory) {
        pendingForget = memory
    }

    /// The ones this appliance filed itself, which are the only ones it may
    /// clear in bulk.
    ///
    /// **The list on screen is not Mynah's list.** A node holds every agent's
    /// memories and this screen shows what Mynah is allowed to read, so a
    /// "forget everything" that walked the visible rows would deprecate a Claude
    /// Code session's memories, another agent's weekly reports, and anything
    /// else the owner had granted read access to. Those are not Mynah's to
    /// throw away, and the owner's own safety net — *"it has its notes fallback
    /// conversation history thing so it can easily re-add it if asked"* — covers
    /// Mynah's memories and none of theirs.
    ///
    /// `isOwnHome` compares the domain against this appliance's own agent id,
    /// which is the node's own definition of ownership rather than a guess from
    /// the text.
    /// **`shown`, not `memories`.** The bulk clear has always been scoped to
    /// what the filter loaded, and the shelf is a filter — so narrowing to Tasks
    /// and pressing Forget all clears tasks, exactly as narrowing to a subject
    /// clears that subject.
    var mynahOwned: [Memory] { shown.filter(isMynahs) }

    /// Whether this one is Mynah's to act on.
    ///
    /// **Per memory, because a control has to know.** The bulk clear could work
    /// from a filtered list; a cross on a card cannot. Adding that cross without
    /// this put one on every row, including memories filed by other agents on
    /// the node — which the owner found immediately, because pressing it can
    /// only ever produce "Mynah couldn't forget that."
    ///
    /// A button that is certain to fail is worse than no button: it teaches that
    /// the controls are unreliable, when in fact this one was never permitted.
    func isMynahs(_ memory: Memory) -> Bool {
        guard let domain = memory.domain else { return false }
        if MemorySubjectName.isOwnHome(domain, applianceAgentID: SageAgentIdentity.applianceAgentID()) {
            return true
        }
        return ownDomains.contains(domain.lowercased())
    }

    /// What the node says this appliance owns, lowercased for comparison.
    ///
    /// **Synchronous, because a control cannot await.** `isMynahs` decides
    /// whether a card draws a Forget cross, and SwiftUI asks that question while
    /// laying out a row. So the answer is fetched once per load and held here
    /// rather than asked per row.
    ///
    /// Seeded with `MynahOwnedDomains.knownPair` so the screen is correct before
    /// the first answer arrives and stays correct if none ever does — see that
    /// type for why the fallback is this rather than nothing.
    private(set) var ownDomains: Set<String> = Set(
        MynahOwnedDomains.knownPair.map { $0.lowercased() }
    )

    /// Asks the node what it owns, and keeps it.
    ///
    /// Failure is not reported to the owner: the seeded pair is a working answer
    /// and a banner about domain resolution on the Memories page would be noise
    /// about something they cannot act on.
    private func refreshOwnedDomains() async {
        let named = await store.domainsMynahOwns()
        guard !named.isEmpty else { return }
        ownDomains = Set(named.map { $0.lowercased() })
    }

    /// Clears what Mynah filed, one at a time, and says what it could not.
    ///
    /// Sequential rather than concurrent: each one is a consensus write, and
    /// forty at once is a burst the node answers by refusing some of them —
    /// which would look identical to "some of these are not yours" and hide the
    /// distinction this whole method exists to preserve.
    func forgetEverythingMynahOwns() async {
        let mine = mynahOwned
        guard !mine.isEmpty else { return }
        isClearing = true
        clearedReport = nil
        forgetTrouble = nil
        defer { isClearing = false }

        var cleared = 0
        var refused = 0
        for memory in mine {
            do {
                switch try await store.forget(id: memory.id) {
                case .forgotten:
                    memories.removeAll { $0.id == memory.id }
                    stillLettingGo.remove(memory.id)
                    cleared += 1
                case .stillLettingGo:
                    stillLettingGo.insert(memory.id)
                    cleared += 1
                }
            } catch {
                // Kept going. One refusal is not a reason to leave the rest,
                // and the count at the end is what the owner needs.
                log.error("bulk forget failed for \(memory.id): \(String(describing: error))")
                refused += 1
            }
        }
        selection = nil

        let others = memories.count
        var parts = ["Forgot \(cleared) of Mynah\u{2019}s own memories"]
        if refused > 0 { parts.append("\(refused) could not be forgotten") }
        if others > 0 { parts.append("\(others) belonging to other agents were left alone") }
        clearedReport = parts.joined(separator: " \u{00B7} ") + "."
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
            log.error("forget failed: \(String(describing: error))")
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
    ///
    /// **The default store path shares one model, and that is the caching.**
    /// `RootView` builds this view fresh out of a `switch` every time the owner
    /// selects Memories, so a model owned by the view was thrown away on the way
    /// out and rebuilt empty on the way in — a node round trip and a full redraw
    /// per visit. Nothing was wrong with the loading code; it was being asked to
    /// start from nothing each time.
    ///
    /// An injected store still gets its own model, because that is the seam the
    /// tests and previews drive and they must not share state with each other or
    /// with the owner's real screen.
    @MainActor
    init(store: (any MemoryStoring)? = nil) {
        _model = State(initialValue: store.map { MemoriesModel(store: $0) } ?? .shared)
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
        // Two dialogs, and which one runs depends on whether anything is
        // filtered. Clearing a subject is a small, deliberate act; clearing
        // everything takes the task list with it and gets asked twice.
        .confirmationDialog(
            model.isFiltered ? "Forget the ones shown?" : "Forget everything Mynah remembers?",
            isPresented: $model.isConfirmingClear
        ) {
            Button("Forget them", role: .destructive) {
                model.isConfirmingClear = false
                if model.clearingNeedsSecondConfirmation {
                    model.isConfirmingClearEverything = true
                } else {
                    Task { await model.forgetEverythingMynahOwns() }
                }
            }
            Button("Keep them", role: .cancel) { model.isConfirmingClear = false }
        } message: {
            // The count and the boundary, because both are load-bearing. The
            // owner is looking at a list that is mostly not Mynah's, and a
            // dialog that said "forget everything" over that list would be
            // promising something much larger than it does.
            let mine = model.mynahOwned.count
            let others = model.memories.count - mine
            let scope = model.isFiltered
                ? "This deprecates the \(mine) shown here that Mynah filed itself. "
                    + "Anything the filter is hiding is left alone."
                : "This deprecates the \(mine) memories Mynah filed itself."
            Text(
                others > 0
                    ? scope + " The \(others) belonging to other agents on this node are left alone."
                    : scope
            )
        }
        // **The second question, and it names the thing that is not obvious.**
        //
        // A task on this node *is* a memory, so clearing everything empties the
        // task list — from a page titled "What Mynah remembers", which mentions
        // tasks nowhere. The owner asked for this by name: *"we should warn
        // first to get double confirmation they know the impact is it will wipe
        // all tasks etc"*.
        //
        // The affirmative button says what it does rather than "OK". A second
        // dialog whose buttons read the same as the first is a second click, not
        // a second thought.
        .confirmationDialog(
            "This clears your task list too",
            isPresented: $model.isConfirmingClearEverything,
            titleVisibility: .visible
        ) {
            Button("Forget everything", role: .destructive) {
                model.isConfirmingClearEverything = false
                Task { await model.forgetEverythingMynahOwns() }
            }
            Button("Cancel", role: .cancel) { model.isConfirmingClearEverything = false }
        } message: {
            Text("Every task, note and preference Mynah filed goes with it — appointments, "
                 + "bookings, the lot. It can't be brought back. To clear only part of it, "
                 + "close this, pick a subject or search first, then clear.")
        }
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
        HStack(alignment: .firstTextBaseline, spacing: s5) {
            VStack(alignment: .leading, spacing: s2) {
                Text("What Mynah remembers")
                    .mynahFont(.title1)
                    .foregroundStyle(Palette.ink.primary)
                countLine
            }
            Spacer(minLength: 0)
            clearControl
        }
    }

    /// Clears what Mynah filed — and only that.
    ///
    /// Hidden when there is nothing of Mynah's to clear, rather than disabled: a
    /// greyed button on a screen full of rows invites the owner to work out why
    /// it will not press, and the answer ("those forty are somebody else's")
    /// belongs in the confirmation, not in a tooltip on a dead control.
    @ViewBuilder
    private var clearControl: some View {
        let mine = model.mynahOwned.count
        if mine > 0 {
            if model.isClearing {
                ProgressView().controlSize(.small).tint(Palette.accent.fill)
            } else {
                MynahButton("Forget all Mynah's", kind: .quiet) {
                    model.isConfirmingClear = true
                }
                .help("Deprecate the \(mine) memories Mynah filed itself. Other agents' are left alone.")
            }
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
        // **"Nothing yet" is a claim about the list, and on the Tasks shelf it
        // was a claim about one page of it.**
        //
        // The shelf filters what is already loaded rather than asking the node
        // for tasks — `kind` is derived from the stored text, so there is no
        // query that means "tasks". A first page whose sixty rows happen to hold
        // no task therefore told the owner he had nothing on his list while he
        // did, with nothing on screen naming a next action.
        if count == 0 {
            // **Only on a shelf whose count and paging are the same list.**
            //
            // `count` is `files.count` on the Files shelf while `hasMore` and
            // `loadedCount` describe memory paging, so this sentence read
            // "None in the newest 20" above FilesBox's own honest "Nothing kept
            // yet" — two contradictory lines on one screen, one of them counting
            // something that is not on it and implying rows he cannot reach.
            guard model.shelf != .files else { return "Nothing yet" }
            return model.hasMore && model.loadedCount > 0
                ? "None in the newest \(model.loadedCount)"
                : "Nothing yet"
        }
        return count == 1 ? "1 thing" : "\(count) things"
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: s4) {
            // The foundation's own tab strip rather than a new control. The
            // owner asked for "a sub tab", and this is the thing this app
            // already uses to divide a pane.
            MynahTabBar(
                tabs: MemoriesModel.Shelf.allCases,
                selection: Binding(get: { model.shelf }, set: { model.shelf = $0 }),
                title: \.word
            )

            // Searching and subjects are questions about remembered things, so
            // they go when the owner is looking at files — a subject filter over
            // a list of PDFs would be a control that does nothing.
            if model.shelf != .files {
                HStack(spacing: s4) {
                    MemorySearchField(text: Binding(
                        get: { model.searchText },
                        set: { model.searchText = $0 }
                    ))
                    if model.topics.count > 1 { topicPicker }
                }
            }
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
            // Labelled with the readable name, filtered with the node's. The
            // separation `Memory.domain` established holds here too: what the
            // owner reads and what gets sent are allowed to differ, and this is
            // the only safe way to prettify a name that is also a query key.
            ForEach(model.topics, id: \.self) { topic in
                Button(model.readableTopic(topic)) { model.topic = topic }
            }
        } label: {
            HStack(spacing: s3) {
                Text(model.topic.map(model.readableTopic) ?? "Everything")
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
        // Files come off this Mac's disk, not off the node, so none of the
        // phases below — which describe a node round trip — apply to them.
        if model.shelf == .files {
            FilesBox(model: model)
        } else {
            memoriesContent
        }
    }

    @ViewBuilder
    private var memoriesContent: some View {
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
            // **This used to send the owner away to rephrase, and rephrasing
            // could not have worked.**
            //
            // A search is `sage_recall`, and recall is silently narrowed to
            // what this agent may read — measured: an unfiltered query against
            // a node of 13,372 memories returned three, all from the one
            // subject the caller owns, with nothing in the response saying
            // ~700 subjects had been excluded. So "nothing matched" was being
            // said about a corpus the search never looked at, and the advice
            // that followed it — describe rather than quote — put the fault on
            // the owner's wording.
            //
            // The second sentence is not a hedge. It is the difference between
            // somebody trying three more phrasings and somebody understanding
            // that the thing they are looking for was never in scope.
            EmptyState(
                glyph: "magnifyingglass",
                title: MemoriesEmpty.searchTitle,
                message: MemoriesEmpty.searchMessage
            )
        } else if model.topic != nil {
            // **Closed and empty are the same picture here, and this used to
            // pick the reassuring one.**
            //
            // Measured as the appliance: naming a subject another agent owns
            // returns `0 of 0` — not a refusal, not an error, zero rows. So
            // this screen genuinely cannot tell "nothing has been kept here"
            // from "this belongs to somebody else". It said the first, which is
            // the same substitution as a locked board reading as an empty
            // plate.
            //
            // Saying it cannot tell is not a failure of the copy. It is the
            // only true sentence available until SAGE distinguishes the two,
            // and an owner who knows the question is open will go and look in
            // CEREBRUM rather than conclude the subject is bare.
            EmptyState(
                glyph: "text.append",
                title: MemoriesEmpty.subjectTitle,
                message: MemoriesEmpty.subjectMessage,
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
            // Cards are separated by air, not by rules. A hairline between two
            // bordered cards reads as a third edge and makes the column look
            // like a table someone drew boxes on.
            LazyVStack(alignment: .leading, spacing: s3) {
                if let trouble = model.forgetTrouble {
                    InlineBanner(
                        tone: .critical,
                        headline: "Mynah couldn't forget that.",
                        explanation: trouble.explanation
                    )
                    .padding(.bottom, s5)
                }

                ForEach(model.shown) { memory in
                    MemoryEntry(
                        memory: memory,
                        isSelected: model.selection == memory.id,
                        isReleasing: model.stillLettingGo.contains(memory.id),
                        isForgetting: model.forgetInFlight.contains(memory.id),
                        onSelect: { model.selection = model.selection == memory.id ? nil : memory.id },
                        // Nil on anything filed by another agent, so no cross
                        // appears where forgetting is not permitted.
                        onForget: model.isMynahs(memory) ? { model.confirmForget(memory) } : nil,
                        isSomebodyElses: !model.isMynahs(memory)
                    )
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

/// A shadow only while the card is raised.
///
/// A branch rather than `.mynahShadow(...)` with a zero radius: a shadow with
/// no size is still a shadow, composited under every card in a list the owner
/// scrolls. This screen can hold hundreds of them.
private struct MemoryCardLift: ViewModifier {
    let isRaised: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isRaised {
            content.mynahShadow(.card)
        } else {
            content
        }
    }
}

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
    /// Absent when this memory is not Mynah's to forget.
    let onForget: (() -> Void)?
    /// Filed by another agent on the same node. Readable, never removable.
    var isSomebodyElses = false

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

            if isSelected {
                // **One motion, not two.** This had `move(edge: .top)` as well,
                // on the theory that sliding the detail out from under the
                // header is what makes it read as unrolling. It is not, and the
                // owner saw the seam immediately: *"the animation slide down is
                // a bit weird - text slides down then the box"*.
                //
                // The card's height is already animating on the same spring, so
                // `move` was a second, independent motion of the same content —
                // the text travelling down inside a box that was travelling
                // down too, at a different visual rate, with a spring's
                // overshoot on both. Text arriving ahead of its container is
                // exactly what that looks like.
                //
                // The `clipShape` below is what does the unrolling: the detail
                // sits still and the card uncovers it. All this has to add is
                // the fade, so the text is not briefly legible through a gap
                // that has not opened yet.
                detail.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **Every card is raised. A task is marked, not dimmed.**
        //
        // Tasks used to sit on `surface.sunken` — recessed, so the two kinds
        // were separable down a scrolling list without reading either. They
        // were, and the separation said the wrong thing. The owner, looking at
        // his own screen: *"a bit unclear which is which - the grey cards for
        // tasks look like they're just deactivated or something"*.
        //
        // He is right, and it is the ordinary meaning of the treatment: a
        // recessed grey panel is what every other interface on this Mac uses for
        // something switched off. A task is the *most* live thing on this page —
        // it is the only kind with a date that can pass — so the one thing it
        // must not read as is disabled.
        //
        // So distinction by presence: same surface, and a stripe down the
        // leading edge. Monochrome because the palette is (see `Palette.status`
        // for why there is no third colour to reach for), which also means the
        // mark cannot be mistaken for a state — it is ink, and ink is what
        // everything on this screen is made of.
        .background(Palette.surface.raised, in: RoundedRectangle.mynah(r.card))
        .overlay(alignment: .leading) {
            if memory.kind == .task {
                Rectangle()
                    .fill(Palette.accent.fill)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
        // The border carries the state, not a fill. A tinted card body competes
        // with the sentence inside it, which is the one thing on this screen
        // the owner came to read.
        .mynahBorder(r.card, borderColour)
        .clipShape(RoundedRectangle.mynah(r.card))
        // **The one on the card, not the one inside it.**
        //
        // Forgetting a single memory has always been possible and always
        // required opening the card first, so the owner read the screen as
        // having "a button to clear all but not a 'x' for each". He was
        // describing what he could see, which is the only thing that counts.
        //
        // Same treatment as the task board: on hover, not permanently. A cross
        // on every card turns a list of what an appliance knows into a list of
        // things to delete, which is the wrong invitation for a page somebody
        // is reading.
        .overlay(alignment: .topTrailing) {
            if let onForget, isHovering, !isForgetting, !isReleasing {
                Button(action: onForget) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.ink.secondary)
                        .frame(width: 18, height: 18)
                        .background(Palette.surface.sunken, in: Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Forget this")
                .accessibilityLabel("Forget this memory")
                .padding(s3)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .modifier(MemoryCardLift(isRaised: isSelected || isHovering))
        .onHover { isHovering = $0 }
        .mynahAnimation(Motion.snap, value: isSelected)
        .mynahAnimation(Motion.fade, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(memory.text)
        .accessibilityValue("Stored \(memory.learned.formatted(.relative(presentation: .named))), \(memory.topic)")
    }

    /// Three states, told apart by one edge: resting, under the pointer, open.
    private var borderColour: Color {
        if isSelected { return Palette.accent.fill.opacity(0.55) }
        return isHovering ? Palette.line.strong : Palette.line.hairline
    }

    @ViewBuilder
    private var collapsedOrOpen: some View {
        if isSelected {
            // The whole sentence, unclipped. A screen that promises the owner
            // can see everything Mynah remembers must not truncate the thing
            // they opened in order to read.
            VStack(alignment: .leading, spacing: s3) {
                Text(memory.displayText)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: s2) {
                    if memory.kind == .task { KindChip(kind: .task) }
                    SubjectChip(subject: memory.topic)
                }
            }
            .padding(.horizontal, s4)
            .padding(.vertical, s4)
        } else {
            MemoryRow(
                text: memory.displayText,
                date: memory.learned,
                topic: memory.topic,
                isTask: memory.kind == .task
            )
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: s4) {
            // **The page is titled "What Mynah remembers" and this row is not
            // that.** A SAGE node holds every agent's memories, and this screen
            // lists what Mynah is *allowed to read* — so a Claude Code session's
            // notes sit under a heading claiming Mynah filed them.
            //
            // The owner, reading his own dev-session memories on it: *"these are
            // not its memories thus it can't forget them - but why do they show
            // up to begin with ? they look like they belogn to you"*. They did,
            // and nothing on the card said so until it refused to delete one.
            //
            // Said here rather than by hiding the row: the memories are real,
            // Mynah can genuinely use them to answer, and a list that silently
            // dropped them would explain even less than one that mislabels them.
            // The subject filter above still narrows to whichever agent's the
            // owner wants.
            if isSomebodyElses {
                Text("Another agent on this node filed this. Mynah can read it, and can't forget it.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            // One line, not a label column.
            //
            // `factLine` reserves 132pt for its label because it was written for
            // a stack of facts — certainty, domain, stored — that had to line up
            // with each other. Those are gone and only this one is left, so the
            // column now reserves space for a table of one and leaves a hand's
            // width of nothing between the word and the date.
            //
            // A memory the node sent without a timestamp is still a memory, and
            // it still belongs on a screen that promises the owner can see
            // everything. It says so rather than inventing a date.
            HStack(alignment: .firstTextBaseline, spacing: s3) {
                Text("Stored")
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
                Text(
                    memory.learned == .distantPast
                        ? "Not recorded"
                        : memory.learned.formatted(date: .long, time: .shortened)
                )
                .mynahFont(.bodyEmphasis)
                .foregroundStyle(Palette.ink.primary)
                .textSelection(.enabled)
            }

            HStack(spacing: s4) {
                Spacer(minLength: 0)
                if isForgetting {
                    Text("Forgetting…")
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                } else if let onForget {
                    // A destructive action is a secondary button with critical
                    // *text*, never a filled red button — the fill turns a
                    // reversible-feeling browse screen into an alarm. The colour
                    // goes on the `Text` rather than the `Button`, because the
                    // shared style sets the label's foreground itself.
                    //
                    // Absent entirely on another agent's memory. It was offered
                    // there and could only ever answer "Mynah couldn't forget
                    // that", which is how the owner found this.
                    Button(action: onForget) {
                        Text("Forget this").foregroundStyle(Palette.state.critical)
                    }
                    .buttonStyle(.mynahSecondary)
                }
            }
        }
        .padding(.horizontal, s4)
        .padding(.bottom, s4)
        // Opacity alone. `.push(from: .top)` slides the panel down from above
        // its own card while the card is still growing to hold it, so the text
        // arrives before the box does — *"the animation slide down is a bit
        // weird - text slides down then the box"*. A reveal has one moving
        // part: the card's height. The contents just become visible.
        .transition(.opacity)
    }

}

// MARK: - Search field

/// The app's search input.
///
/// Everything the appliance has on disk, and the only place it can be removed.
///
/// Three directories have been filling up for the life of the appliance with
/// nothing listing them: notes Mynah wrote, documents converted from them, and
/// every photo or PDF the owner has ever sent over Signal. The owner: *"we can't
/// view or remove files"*, and *"there's no way to clean that up"*.
///
/// Opening a file is `NSWorkspace`, not a viewer built here. Whatever the owner
/// already uses for a PDF is better than anything this window would draw, and a
/// half-built preview is how a file screen becomes a file manager.
private struct FilesBox: View {
    @Bindable var model: MemoriesModel

    var body: some View {
        VStack(alignment: .leading, spacing: s4) {
            if let trouble = model.fileTrouble {
                InlineBanner(
                    tone: .critical,
                    headline: trouble,
                    explanation: "It is still on this Mac. Try again, or remove it in Finder."
                )
            }

            if model.isLoadingFiles && model.files.isEmpty {
                HStack(spacing: s4) {
                    ThinkingIndicator()
                    Text("Looking through what Mynah has kept…")
                        .mynahFont(.body)
                        .foregroundStyle(Palette.ink.secondary)
                }
                .padding(.vertical, s6)
            } else if model.files.isEmpty {
                // Not a failure, and worded so it does not read as one.
                Text("Nothing kept yet. Documents Mynah writes and files you send it will show up here.")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
                    .padding(.vertical, s6)
            } else {
                ScrollView {
                    LazyVStack(spacing: s3) {
                        ForEach(model.files) { file in
                            SavedFileRow(
                                file: file,
                                onOpen: { NSWorkspace.shared.open(file.url) },
                                onReveal: {
                                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                },
                                onRemove: { model.confirmRemove(file) }
                            )
                        }
                    }
                    .padding(.bottom, s6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.loadFiles() }
        .confirmationDialog(
            model.pendingFileRemoval.map { "Delete \($0.name)?" } ?? "Delete this file?",
            isPresented: Binding(
                get: { model.pendingFileRemoval != nil },
                set: { if !$0 { model.pendingFileRemoval = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let file = model.pendingFileRemoval else { return }
                model.pendingFileRemoval = nil
                Task { await model.remove(file) }
            }
            Button("Keep it", role: .cancel) { model.pendingFileRemoval = nil }
        } message: {
            // Named plainly, because one of these three kinds is the owner's own
            // file and may have no other copy anywhere.
            // **The reassurance was false for the notes that matter.**
            //
            // "Mynah can write another if you ask" is true of a note it wrote
            // from a conversation. It is not true of the companion note beside a
            // received file: that note exists to describe *that* attachment, and
            // once the attachment is gone there is nothing to write it from.
            // Deleting either half of the pair leaves the other pointing at
            // nothing — Mynah then insists it still has the file, and sends a
            // note naming a path that is not there.
            Text(Self.consequence(of: model.pendingFileRemoval))
        }
    }
}

private extension FilesBox {
    /// What deleting this one actually costs, said accurately for each kind.
    static func consequence(of file: SavedFile?) -> String {
        switch file?.kind {
        case .attachment:
            return "This is a file you sent Mynah. Deleting it removes it from this Mac, "
                + "and the note describing it will point at a file that is no longer there."
        case .note:
            return "If this note describes a file you sent, deleting it leaves that file "
                + "with nothing naming it — Mynah will not find it when you ask."
        case .document:
            return "This removes it from this Mac. Mynah can produce it again from the note it came from."
        case .none:
            return "This removes it from this Mac."
        }
    }
}

/// One file: what it is, how big, when, and the three things you can do with it.
private struct SavedFileRow: View {
    let file: SavedFile
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: s4) {
            VStack(alignment: .leading, spacing: s2) {
                Text(file.name)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: s2) {
                    Text(file.saved.formatted(.relative(presentation: .named)))
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                    Text("·").mynahFont(.label).foregroundStyle(Palette.ink.quaternary)
                    Text(file.readableSize)
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                    SubjectChip(subject: file.kind.word)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // On hover, like the Forget cross on a memory card and for the same
            // reason: a row of buttons on every line turns a list of what the
            // appliance has into a list of things to delete.
            if isHovering {
                MynahButton("Open", kind: .quiet, action: onOpen)
                MynahButton("Show", kind: .quiet, action: onReveal)
                MynahButton("Delete", kind: .quiet, action: onRemove)
            }
        }
        .padding(.horizontal, s4)
        .padding(.vertical, s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.raised, in: RoundedRectangle.mynah(r.card))
        .mynahBorder(r.card, Palette.line.hairline)
        .onHover { isHovering = $0 }
        .mynahAnimation(Motion.fade, value: isHovering)
    }
}

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
            domain: "Home",
            learned: Date().addingTimeInterval(-3_600)
        ),
        Memory(
            id: "2",
            text: "Flying to Kuala Lumpur on the 14th. Wants the 6am departure, not the redeye.",
            domain: "Travel",
            learned: Date().addingTimeInterval(-86_400 * 2)
        ),
        // A task, carrying the node's own prefix, so the previews show what the
        // chip and the recessed card actually do to a mixed list.
        Memory(
            id: "3",
            text: "[TASK] Book the hire car for the 14th",
            domain: "Travel",
            learned: Date().addingTimeInterval(-86_400 * 2)
        ),
        Memory(
            id: "4",
            text: "Someone called Marcus is meant to be picking up the keys, possibly on Thursday.",
            domain: "Home",
            learned: Date().addingTimeInterval(-86_400 * 9)
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


// MARK: - What an empty screen is allowed to claim

/// The two empty states produced by a **narrowed** read, kept as values.
///
/// Named constants rather than literals inside the view because the tests that
/// hold these honest were greping the source and the source wraps: the sentence
/// `"This screen cannot tell which"` is three string segments in the file and
/// never appears contiguously, so a check for it passed nothing and would have
/// gone on passing nothing. team-lead's rule from this morning, arriving where
/// it belongs — **a test that greps source is testing the wrong thing, and its
/// failure mode is silence.** Assert on a value.
///
/// `thread`'s rule is what the copy has to satisfy: *a result set that has been
/// silently narrowed must never be presented as a complete answer to the
/// question that was asked.*
enum MemoriesEmpty {

    static let searchTitle = "Nothing Mynah can read matched"

    /// **The old version sent the owner away to rephrase, and rephrasing could
    /// not have worked.** A search is `sage_recall`, which is silently narrowed
    /// to what this agent may read — measured, as the appliance: an unfiltered
    /// query against 13,372 memories returned three, all from the one subject
    /// the caller owns, with nothing in the response saying that some seven
    /// hundred subjects had been excluded.
    ///
    /// The last clause is not a hedge. It is the difference between somebody
    /// trying three more phrasings and somebody understanding that what they
    /// want was never in scope.
    static let searchMessage =
        "Mynah searches by meaning rather than spelling, so it is worth describing the "
            + "thing rather than quoting it. But this only searches what Mynah is allowed "
            + "to read — anything another agent keeps to itself will not appear here, "
            + "however you word it."

    static let subjectTitle = "Nothing Mynah can read here"

    /// **Closed and empty are the same picture, and this used to pick the
    /// reassuring one.** Naming a subject another agent owns returns `0 of 0` —
    /// not a refusal, not an error, zero rows. So the screen genuinely cannot
    /// tell "nothing kept here" from "belongs to somebody else", and saying so
    /// is the only true sentence available.
    ///
    /// **No count.** How much was filtered is a number SAGE does not return and
    /// an open request to that team; implying one would be inventing the most
    /// consequential fact on the screen, which is the habit this whole area is
    /// being corrected for.
    static let subjectMessage =
        "Either nothing has been kept under this subject, or it belongs to another agent "
            + "and Mynah is not allowed to see it. This screen cannot tell which — both "
            + "look the same from here."
}
