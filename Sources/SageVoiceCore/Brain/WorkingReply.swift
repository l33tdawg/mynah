import Foundation

/// What the appliance says while the owner is still waiting.
///
/// A local turn that calls tools takes 20–50 seconds, and silence for that long
/// reads as broken — the owner has twice reported a working appliance as hung.
/// Streaming would be the real fix and is not available over Signal, so the next
/// best thing is the thing a person does: say what you are doing.
///
/// This deliberately replaces an earlier feature that sent a fixed
/// acknowledgement the moment a message arrived. The owner's verdict on that was
/// "they sound very fake and don't make sense", and they were right, for a
/// reason worth writing down: it fired *before* the model had decided anything,
/// so it was guessing. A turn that says "let me look that up" and then answers
/// from memory has told the owner something untrue about itself.
///
/// So nothing is said until the model has committed to a tool, and what gets
/// said is derived from the tool it actually chose. "Hang on, checking" is a
/// promise the appliance is already keeping.
///
/// ## Why there is more than one line per tool
///
/// The same sentence every morning is how a person notices they are talking to a
/// script. Variety here is not decoration: it is the difference between an
/// assistant and a vending machine, and it costs nothing — these strings never
/// reach the model, so they cannot affect routing, latency, or the prompt cache.
///
/// What variety must *not* do is lie. Every alternative for a tool has to be
/// true of that tool, which is why they are grouped by tool rather than drawn
/// from one pool of friendly noises.
public enum WorkingReply {

    // MARK: - Instant

    /// Said the moment the message lands, before any model call.
    ///
    /// `line(forTools:)` cannot be instant: it waits for the model to choose a
    /// tool, and choosing costs a whole model call — 15–40 s on this appliance.
    /// Observed in the thread as "Having a look." arriving most of a minute after
    /// the question, which is late enough to be worse than nothing, because by
    /// then the owner has already decided it is broken.
    ///
    /// The obvious fix is the one this product already rejected: a fixed
    /// acknowledgement sent on arrival. The owner's verdict was "they sound very
    /// fake and don't make sense", and the reason is worth restating — it fired
    /// before anything was known, so it was guessing, and a turn that says "let
    /// me look that up" and then answers from memory has told the owner
    /// something untrue about itself.
    ///
    /// What is different here is the source. This is derived from *the owner's
    /// own sentence*, which is available instantly and is not a guess about the
    /// model's behaviour. If they asked about their backlog, "let me check the
    /// backlog" is true because they said backlog — not because anything
    /// predicted a tool call.
    ///
    /// Silence remains the default. Anything that cannot be classified with
    /// confidence says nothing, because a wrong instant line is exactly the
    /// failure this is trying not to repeat.
    public static func instantLine(
        forRequest request: String,
        previous: String? = nil,
        chooser: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> String? {
        guard let options = instantOptions(forRequest: request), !options.isEmpty else { return nil }
        let fresh = options.filter { $0 != previous }
        let pool = fresh.isEmpty ? options : fresh
        return pool[min(max(chooser(pool.count), 0), pool.count - 1)]
    }

    /// Classifies the request from its wording alone. Deliberately conservative:
    /// every branch here has to be true of *any* turn that reaches it.
    static func instantOptions(forRequest request: String) -> [String]? {
        let text = request.lowercased()

        func mentions(_ words: [String]) -> Bool {
            words.contains { text.contains($0) }
        }

        // Fast writes answer before an acknowledgement would land, and the
        // thread is the owner's own Note to Self — two bubbles where one would
        // do is noise. "add a note ... before Friday" already behaves this way
        // and reads correctly.
        guard !mentions(["add a note", "add a task", "remind me", "save that", "remember that", "note that"]) else {
            return nil
        }
        // Nothing to acknowledge.
        guard !mentions(["thanks", "thank you", "never mind", "nevermind", "forget it", "cancel", "good night", "goodnight"]) else {
            return nil
        }
        guard text.count > 12 else { return nil }

        if mentions(["backlog", "task list", "todo", "to-do", "inbox"]) {
            return [
                "Let me check your backlog.",
                "Checking the list now.",
                "One sec, pulling up your tasks."
            ]
        }
        // Stems, not whole phrases. "what did we talk about" and "the shops we
        // talked about" are the same question, and matching only the past tense
        // sent the first one to the generic branch.
        if mentions(["we talk", "we discuss", "we said", "you told me", "from before", "earlier", "last time", "remember when"]) {
            return [
                "Let me go back through that.",
                "Digging that up now.",
                "One sec, looking back."
            ]
        }
        if mentions(["note", "document", "write up", "markdown", "list of", "compile", "export"]) {
            return [
                "On it — let me pull that together.",
                "Right, working on that now.",
                "Give me a minute on that."
            ]
        }
        if mentions(["news", "latest", "price", "who is", "what's on", "look up", "search", "find me"]) {
            return [
                "Looking into that now.",
                "On it — give me a moment.",
                "Right, let me find out."
            ]
        }
        // Everything else. Speaking is the default, and that is a correction:
        // this started as a keyword allowlist, and "the ramen shops near klcc"
        // matched none of it — so the owner waited about 30 seconds for the
        // tool-decision line, which is the exact failure the instant line
        // exists to remove. An allowlist is the wrong shape for "say something
        // unless it would be wrong", because the cases where it is wrong are
        // few and nameable while the cases where it is right are unbounded.
        //
        // Safe as a default because these three name nothing: no tool, no
        // source, no claim beyond having received the message. They are true of
        // any turn that reaches here, which small talk and fast writes do not.
        return [
            "Let me have a look.",
            "One moment.",
            "On it."
        ]
    }

    // MARK: - Not saying it twice

    /// Whether two lines carry the same news.
    ///
    /// Observed twice in the thread: "Looking that up online — give me a few
    /// seconds." followed by "Looking online for the rest of it.", and "On it —
    /// having a look online." followed by the same. Both pairs are individually
    /// true and together read as a stutter, which undoes the point of varying
    /// the wording in the first place.
    ///
    /// Compares meaningful words rather than whole strings, because the whole
    /// problem is two different strings meaning one thing.
    public static func saysTheSameThing(_ line: String, as previous: String?) -> Bool {
        guard let previous else { return false }
        let a = significantWords(line)
        let b = significantWords(previous)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // Half is deliberately lenient. A false positive costs one update the
        // owner would not have missed; a false negative is the stutter.
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.5
    }

    private static func significantWords(_ line: String) -> Set<String> {
        Set(
            line.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count > 2 && !filler.contains($0) }
                // Crudest possible stem, and it has to be here: the observed
                // stutter was "having a look online" then "Looking online",
                // which share their whole meaning and not one exact token.
                // Four characters collapses look/looking, check/checking,
                // search/searching without pulling unrelated words together.
                .map { String($0.prefix(4)) }
        )
    }

    /// Words that carry no news, so two lines sharing only these are not saying
    /// the same thing.
    private static let filler: Set<String> = [
        "the", "and", "for", "you", "let", "give", "few", "one", "now", "just",
        "some", "get", "sec", "that", "this", "them", "there", "here", "with",
        "moment", "second", "seconds", "minute", "hang", "still"
    ]

    // MARK: - First word

    /// Alternatives for a set of chosen tools, or `nil` to stay quiet.
    ///
    /// Quiet is the default for anything fast. A `sage_remember` finishes in
    /// milliseconds, so announcing it would put two messages in the thread where
    /// one would do — noise, in a Note to Self the owner also uses for real
    /// notes.
    static func lines(forTools tools: [String]) -> [String]? {
        guard let primary = tools.first else { return nil }

        switch primary {
        case "web_search":
            return [
                "Looking that up online — give me a few seconds.",
                "Searching for that now.",
                // "Let me check" on its own would be true of half the catalogue.
                // Every line here has to be recognisably about the outside world,
                // or variety has quietly become vagueness.
                "Let me search and see what's out there.",
                "On it — having a look online."
            ]

        case "sage_recall", "sage_timeline", "sage_list", "sage_corroborate":
            return [
                "Digging through my memory, hang on.",
                "Let me see what I've got on that.",
                "Checking what we've said about this before.",
                "Going back through my notes."
            ]

        case "sage_backlog", "sage_inbox":
            return [
                "Checking that now, one moment.",
                "Having a look.",
                "One sec, pulling that up."
            ]

        case "sage_pipe", "sage_find_agent":
            // The only genuinely long one: another agent has to pick it up,
            // do the work, and come back. Worth setting expectations wider.
            return [
                "Sure — sending that over now. I'll come back to you when it lands.",
                "Passing that on. I'll let you know what comes back.",
                "Handing that off — I'll follow up once they've picked it up."
            ]

        case "sage_status", "sage_federation", "sage_scope_list", "sage_scope_get":
            return [
                "Checking the network, one sec.",
                "Let me look at what's running.",
                "Having a look at the nodes."
            ]

        case "sage_gov_propose", "sage_gov_vote", "sage_gov_status":
            return [
                "Working on the governance side, hang on.",
                "Let me take care of the governance bit."
            ]

        case "write_note", "read_note", "list_notes":
            return [
                "Let me pull that together.",
                "Working on that document now.",
                "Give me a moment to write that up."
            ]

        default:
            // Writes (sage_remember, sage_task, sage_rename, sage_link…) return
            // fast enough that the answer beats the acknowledgement.
            return nil
        }
    }

    /// One line for the chosen tools, avoiding `previous`.
    ///
    /// The exclusion is the entire point. Random choice from four options still
    /// repeats about a quarter of the time, and hearing the same sentence twice
    /// in a row is *more* obviously mechanical than hearing it always — it reads
    /// as a system that tried to vary itself and failed.
    ///
    /// - Parameter previous: the line last sent to this owner, if any.
    public static func line(
        forTools tools: [String],
        previous: String? = nil,
        chooser: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> String? {
        guard let options = lines(forTools: tools), !options.isEmpty else { return nil }
        let fresh = options.filter { $0 != previous }
        // Every option was the last one said, which means there is only one.
        // Saying it again beats saying nothing at all.
        let pool = fresh.isEmpty ? options : fresh
        return pool[min(max(chooser(pool.count), 0), pool.count - 1)]
    }

    // MARK: - Still going

    /// Gap between progress messages.
    ///
    /// 45 s, because the first line goes out as soon as the model commits to a
    /// tool — a second or two in — and a tool-calling turn on this appliance runs
    /// 30–90 s per iteration. Shorter than this and two messages arrive close
    /// enough together to read as a stuck loop rather than someone working.
    public static let progressAfterSeconds: TimeInterval = 45

    /// How many progress messages one turn may send.
    ///
    /// Three. A person working for five minutes says two or three things about
    /// it, not six; past that, the updates themselves become the thing the owner
    /// is waiting through. With a 300 s budget and a 45 s cadence this covers the
    /// first ~3 minutes and then goes quiet, which is also what a person does
    /// once they are deep in something.
    public static let maximumProgressMessages = 3

    /// What the turn has actually produced, as far as a progress message may
    /// speak about it.
    ///
    /// Everything here is evidence, never inference. That distinction is the
    /// whole reason the first version of this feature was ripped out: it spoke
    /// before it knew anything, and the owner's verdict was "they sound very
    /// fake and don't make sense". A line that says "found a few options in
    /// Tokyo" has to be backed by results that exist and by Tokyo appearing in
    /// them — otherwise it is the same failure with better wording.
    public struct Findings: Sendable, Equatable {
        /// Roughly how many items the last tool returned. `nil` when the output
        /// had no countable shape.
        public var count: Int?
        /// A place or proper noun present in *both* the owner's request and the
        /// tool output. Never taken from one alone: from the request only it is
        /// a guess about what was found, and from the output only it is a
        /// stranger's word put in the appliance's mouth.
        public var subject: String?

        public init(count: Int? = nil, subject: String? = nil) {
            self.count = count
            self.subject = subject
        }

        public static let none = Findings()
    }

    /// Countable items in a tool result: numbered entries first, then URLs.
    ///
    /// Deliberately crude and deliberately vague downstream — this produces "a
    /// few" and "a couple", never "7", because the count is a shape heuristic
    /// over text and an exact number would claim a precision it does not have.
    public static func resultCount(in text: String) -> Int? {
        let lines = text.split(separator: "\n")
        let numbered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first.isNumber else { return false }
            return trimmed.dropFirst().first.map { $0 == "." || $0 == ")" } ?? false
        }.count
        if numbered > 0 { return numbered }
        let urls = SourceLinks.extract(from: text, limit: 50).count
        return urls > 0 ? urls : nil
    }

    /// A proper noun the owner used that the tool output also contains.
    ///
    /// Two sources agreeing is what makes it sayable. Latin tokens must be
    /// capitalised mid-sentence — the first word of a transcript is capitalised
    /// by ASR convention and proves nothing — and CJK runs are taken as-is,
    /// since 大阪 carries no case to check.
    public static func sharedSubject(request: String, result: String) -> String? {
        let words = request
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "?" || $0 == "." })
            .map(String.init)
        // Drop the first token: "Tokyo shops" and "Looking for shops" both
        // capitalise it, and only one of them means anything.
        for word in words.dropFirst() {
            let cleaned = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard !cleaned.isEmpty, !Self.notASubject.contains(cleaned.lowercased()) else { continue }
            let isCJK = cleaned.unicodeScalars.contains { $0.value >= 0x3040 && $0.value <= 0x9FFF }
            let isProper = cleaned.first?.isUppercase == true
            guard isCJK || isProper else { continue }
            // Two characters for CJK, three for Latin. 大阪 and 東京 are whole
            // place names at two; "St" and "Mr" are not. A single minimum
            // length cannot serve both, and the Latin one silently discarded
            // every Japanese city in a product whose owner travels to Japan.
            guard cleaned.count >= (isCJK ? 2 : 3) else { continue }
            if result.localizedCaseInsensitiveContains(cleaned) { return cleaned }
        }
        return nil
    }

    /// Capitalised words that are not subjects. Short on purpose: the shared
    /// requirement with the tool output already filters almost everything, and a
    /// long list here would be a second thing to keep in step with reality.
    private static let notASubject: Set<String> = [
        "the", "and", "for", "can", "you", "please", "yeah", "bro", "mate",
        "what", "where", "which", "give", "find", "look", "some", "any", "all",
        "list", "note", "file", "urls", "links", "shops", "stores"
    ]

    /// The next progress message, naming what has actually happened so far.
    ///
    /// A bare "still working on it" is filler, and the owner has already rejected
    /// filler once in this product. This says what came back, because that is
    /// both more useful and the thing a person would actually say: *"memory came
    /// back a bit thin, checking online now"* tells the owner the shape of the
    /// answer they are about to get and gives them a chance to redirect it.
    ///
    /// - Parameters:
    ///   - completed: tool names already run, in order.
    ///   - pending: the tool now in flight, if one is.
    ///   - index: how many progress messages have already gone out this turn.
    ///     Later ones acknowledge the wait rather than repeating the status,
    ///     because saying "still looking" three times is the same as saying
    ///     nothing three times.
    public static func progressLine(
        completed: [String],
        pending: String?,
        index: Int = 0,
        findings: Findings = .none
    ) -> String? {
        // Nothing has finished yet: the first line already said this, and
        // repeating it with no new information is the filler this avoids.
        guard let last = completed.last else { return nil }

        let searched = completed.contains { $0 == "web_search" }
        let recalled = completed.contains { $0.hasPrefix("sage_") }
        // "a few options in Tokyo" — only when something was actually found and
        // the place came from both the owner's words and the results.
        let found = Self.foundPhrase(findings)

        // What is about to happen beats what already did, at any point in the
        // turn — it is the only part the owner can still redirect.
        if let pending {
            switch pending {
            case "web_search" where recalled:
                return "Memory didn't have all of it — checking online now."
            case "web_search":
                return "Looking online for the rest of it."
            case "write_note":
                return found.map { "\($0) — let me compile that." }
                    ?? "Got what I need, writing it up now."
            case "sage_pipe", "sage_find_agent":
                return "Passing part of this to another agent now."
            default:
                break
            }
        }

        switch index {
        case 0:
            if let found { return "\(found) — still gathering the rest." }
            if searched { return "Still reading through what came back." }
            if recalled { return "Found some of it, still looking for the rest." }
            return "Still on it — \(Self.spokenToolName(last)) took a moment."
        case 1:
            if let found { return "\(found). Pulling it together now." }
            return "Taking a bit longer than usual — there's more here than I expected."
        default:
            // The last thing said before the turn goes quiet, so it commits to
            // finishing rather than describing the state again.
            return "Almost there."
        }
    }

    /// "Found a few options in Tokyo", or `nil` when nothing was found worth
    /// claiming. Vague by design — see `resultCount`.
    private static func foundPhrase(_ findings: Findings) -> String? {
        guard let count = findings.count, count > 0 else { return nil }
        let quantity: String
        switch count {
        case 1: quantity = "one option"
        case 2: quantity = "a couple of options"
        case 3...5: quantity = "a few options"
        default: quantity = "quite a few options"
        }
        guard let subject = findings.subject else { return "Found \(quantity)" }
        return "Found \(quantity) in \(subject)"
    }

    /// A tool name as something sayable. Never shown for a tool the owner has
    /// no reason to know about — those fall back to the generic phrasing above.
    static func spokenToolName(_ tool: String) -> String {
        switch tool {
        case "web_search": return "the search"
        case "sage_recall", "sage_timeline", "sage_list": return "the memory lookup"
        case "sage_backlog", "sage_inbox": return "that check"
        default: return "that"
        }
    }
}
