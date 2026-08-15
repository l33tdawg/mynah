import Foundation

/// What happened to one after-the-call message.
///
/// Three states rather than a `Bool`, because the middle one is the whole
/// point. `VoiceBridgeDaemon.reply` retries without attachments when signal-cli
/// refuses a send and returns the retry's success — so a plain `true` can mean
/// "the owner got a sentence about a file, and no file". A queue that deleted
/// its entry on that would be the silent broken promise this feature exists to
/// end, arriving through the very code meant to end it.
public enum AfterTheCallDelivery: Equatable, Sendable {
    case sent
    case sentWithoutTheFiles
    case failed
}

/// **Does what the call promised, once the line is down.**
///
/// Runs in a `Task.detached` so it inherits no cancellation: the turn that
/// queued the work was cancelled at hang-up by design, and the drain must
/// outlive it. That is also why it takes plain values rather than reading the
/// queue itself — the claim happens synchronously on the call actor, before
/// this is ever started.
public struct AfterTheCallDrain: Sendable {

    /// Tries configured owner channels in order for a legacy queue record that
    /// predates persisted origin routing. Stops at the first channel that
    /// actually reached the owner; a failed preferred channel must not prevent
    /// a working linked channel from carrying the recovery report.
    public static func firstDelivery(
        to recipients: [ChannelRecipient],
        attempt: @Sendable (ChannelRecipient) async -> AfterTheCallDelivery
    ) async -> AfterTheCallDelivery {
        var bestOutcome: AfterTheCallDelivery = .failed
        for recipient in recipients {
            let outcome = await attempt(recipient)
            if outcome == .sent { return .sent }
            if outcome == .sentWithoutTheFiles { bestOutcome = outcome }
        }
        return bestOutcome
    }

    private let queue: CallActionQueue
    private let tools: any ToolProviding
    /// **Its own `NotesToolSource`, not the daemon's.**
    ///
    /// `outgoing` is one array on one instance, appended by `send_file` and
    /// emptied by `drainOutgoingFiles()`. The daemon empties that same buffer
    /// on every incoming message — discarding what it finds — and staples
    /// whatever is in it to whatever reply is going out. The drain runs
    /// concurrently with the daemon and there are suspension points between its
    /// append and its drain, so sharing the instance means an owner who
    /// messages the thread in the seconds after hanging up either loses the
    /// queued file or receives it attached to an unrelated reply.
    ///
    /// That is the exact hazard that keeps the notes source off the call
    /// catalogue in the first place; it would be absurd to reintroduce it here.
    /// A second instance over the same directory keeps `StoredFiles` resolution
    /// against a live listing and keeps the 95 MB Signal ceiling, with a
    /// private buffer nothing else can reach into.
    private let notes: NotesToolSource
    private let deliver: @Sendable (String, [URL], ChannelRecipient?) async -> AfterTheCallDelivery
    private let runInstruction: @Sendable (String, ChannelRecipient?) async -> AfterTheCallDelivery
    private let log: @Sendable (String) -> Void

    public init(
        queue: CallActionQueue,
        notesDirectory: URL,
        tools: any ToolProviding,
        deliver: @escaping @Sendable (String, [URL], ChannelRecipient?) async -> AfterTheCallDelivery,
        runInstruction: @escaping @Sendable (String, ChannelRecipient?) async -> AfterTheCallDelivery,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.queue = queue
        self.tools = tools
        self.notes = NotesToolSource(
            directory: notesDirectory,
            delivery: .attachedToReply,
            log: log
        )
        self.deliver = deliver
        self.runInstruction = runInstruction
        self.log = log
    }

    /// Source-compatible seam for callers that do not need to observe routing.
    /// Production uses the recipient-aware initializer above.
    public init(
        queue: CallActionQueue,
        notesDirectory: URL,
        tools: any ToolProviding,
        deliver: @escaping @Sendable (String, [URL]) async -> AfterTheCallDelivery,
        runInstruction: @escaping @Sendable (String) async -> AfterTheCallDelivery,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            queue: queue,
            notesDirectory: notesDirectory,
            tools: tools,
            deliver: { text, files, _ in await deliver(text, files) },
            runInstruction: { text, _ in await runInstruction(text) },
            log: log
        )
    }

    // MARK: - Entry points

    /// Everything left on disk at startup is work this appliance was in the
    /// middle of when it died, or work a call queued and never got to.
    ///
    /// **Reported, never performed.** `AgentSendJournal`'s doctrine: an
    /// appliance that replays a queue after a crash can deliver a message the
    /// owner has since changed their mind about. But that doctrine is about not
    /// *doing* stale work — it says nothing about not *telling*, and going
    /// quiet is how the appliance ends up having promised something in writing
    /// that nothing will ever mention again.
    ///
    /// Without this, the only reader of the queue file is the end of the *next*
    /// call — a door that opens only if the owner happens to ring back.
    public func recoverAtStartup() async {
        let found = queue.claim(forCall: nil)
        let stale = found.mine + found.abandoned
        guard !stale.isEmpty else { return }
        log("[call] \(stale.count) after-the-call action(s) survived a restart; reporting them")
        await report(stale)
    }

    public func drain(mine: [CallActionQueue.Entry], abandoned: [CallActionQueue.Entry]) async {
        if !abandoned.isEmpty {
            log("[call] \(abandoned.count) action(s) from an earlier call were never done; reporting them")
            await report(abandoned)
        }
        guard !mine.isEmpty else { return }

        // Deterministic work first. An instruction runs a whole brain turn at
        // the turn ceiling, so putting it last means a file and a message are
        // already off the queue before anything spends minutes — which matters
        // because launchd SIGTERMs this daemon on every reconcile.
        let ordered = mine.filter { $0.kind != .instruction } + mine.filter { $0.kind == .instruction }
        for entry in ordered {
            // **One entry, one do/catch.** Without this an ambiguous agent name
            // on the first entry — a refusal the resolver is right to make —
            // would take the other two with it.
            do {
                try await perform(entry)
            } catch {
                log("[call] a queued action failed: \(error)")
                let outcome = await deliver(
                    "I couldn't \(entry.spokenLine) after our call. \(error.localizedDescription)",
                    [], recipient(for: entry)
                )
                // A delivered refusal is a confirmed outcome. A refusal that
                // did not reach the owner is still owed.
                if outcome != .failed { queue.remove(entry) }
            }
        }
    }

    // MARK: - One entry

    private func perform(_ entry: CallActionQueue.Entry) async throws {
        switch entry.kind {
        case .file: try await sendTheFile(entry)
        case .agent: try await messageTheAgent(entry)
        case .instruction:
            let outcome = await runInstruction(entry.what, recipient(for: entry))
            if outcome == .sent { queue.remove(entry) }
        }
    }

    private func sendTheFile(_ entry: CallActionQueue.Entry) async throws {
        // Resolved here, at drain time, against a live directory listing —
        // never from a path captured during the call. `NoteSlug.slug(from:)` is
        // an alphanumeric allowlist, so `..` and `/` are unrepresentable and
        // nothing but the caller's spoken title was ever stored.
        switch StoredFiles(directory: notes.notesDirectory).match(title: entry.what) {
        case .one:
            _ = try await notes.call(
                name: NotesToolSource.sendToolName,
                arguments: ["title": .string(entry.what)]
            )
            let files = notes.drainOutgoingFiles()
            guard !files.isEmpty else {
                // The size gate refused it, or the export vanished between the
                // match and the send.
                let outcome = await deliver(
                    "I couldn't send \(entry.what) after our call — it's still here on the Mac, "
                        + "but it couldn't be delivered. Ask me for it here and I'll try again.",
                    [], recipient(for: entry)
                )
                if outcome != .failed { queue.remove(entry) }
                return
            }
            let outcome = await deliver("Here's \(entry.what), as you asked on the call.", files, recipient(for: entry))
            // `.sentWithoutTheFiles` is NOT done. The owner has been told, and
            // the entry stays so the next call reports it rather than the
            // appliance quietly considering the promise kept.
            if outcome == .sent { queue.remove(entry) }

        // **A string matcher is not the last word on what the owner meant.**
        //
        // Both of these used to end here, in a message explaining the failure,
        // and on the queue's first real call that would have been the second
        // reason the ferry ticket never arrived. The caller said "the ferry
        // ticket". It is filed under the caption they sent it with,
        // `here-s-the-ferry-booking-please-store-it`. Four widening rules and
        // none of them join "ticket" to "booking", because none of them can:
        // that is a question about meaning, and `slugs(matching:)` is
        // deliberately word-wise so that "art" cannot match "cartier".
        //
        // Loosening it is the wrong repair — a fuzzier matcher sends the wrong
        // file more often, and rule 2's comment is right that a title matching
        // exactly must never compete with one that merely shares a word.
        //
        // The right one is already in the product and was demonstrated the same
        // afternoon: a minute after hanging up the owner typed "send me the
        // ferry ticket" into Signal, and the daemon ran `list_notes`,
        // `read_note`, `send_file` and got it right first time. A model reading
        // the catalogue resolves this; a matcher cannot. So when the matcher
        // has no single answer, the request goes down that same path rather
        // than into an apology.
        //
        // `.several` goes too, and the "naming the candidates costs a turn,
        // guessing costs a file going somewhere it should not" rule is not
        // being softened: that rule is about *recipients*, learned from the
        // 1ab7aa10 / 74140c2d mix-up, and `messageTheAgent` still refuses an
        // ambiguous name outright. Here the recipient is fixed — it is the
        // owner, on their own thread — and the only question is which of their
        // own files they meant. On a call there is nobody left to ask, as the
        // note below says, so the alternative to letting the model choose is
        // not asking: it is making the owner ask again.
        case .several(let candidates):
            if await theBrainCanFindIt(entry) { return }
            // **Owner-facing prose, written here.** `NotesToolSource`'s refusal
            // strings are addressed to the model in the third person and tell it
            // to call `send_file` again — posting them verbatim would have the
            // owner read himself referred to as "the owner" and be instructed to
            // invoke a tool. On a call there is nobody left to ask, so this
            // message is the entire recovery.
            let outcome = await deliver(
                "You asked me to send \(entry.what) after the call, but I couldn't tell which one "
                    + "you meant — I have \(Self.list(candidates)). Say which and I'll send it.",
                [], recipient(for: entry)
            )
            if outcome != .failed { queue.remove(entry) }

        case .nothing(let available):
            if await theBrainCanFindIt(entry) { return }
            let door = available.isEmpty
                ? "I don't have any saved files yet."
                : "What I do have: \(Self.list(available))."
            let outcome = await deliver(
                "You asked me to send \(entry.what) after the call and I couldn't find it. \(door)",
                [], recipient(for: entry)
            )
            if outcome != .failed { queue.remove(entry) }
        }
    }

    /// Hands an unresolved file request to a full brain turn, which can read the
    /// catalogue and decide what the owner meant.
    ///
    /// Returns whether the request has been dealt with — a turn that runs and
    /// honestly reports finding nothing has dealt with it just as much as one
    /// that sends the file, and better than the canned sentence it replaces.
    /// Only a turn that could not run at all falls through.
    ///
    /// **The instruction forbids the near-miss on purpose.** The failure mode of
    /// asking a model to resolve a fuzzy name is that it sends the closest thing
    /// rather than admitting it is unsure, and a wrong file arriving unannounced
    /// an hour after a call is worse than no file: the owner acts on it. So the
    /// permission granted here is narrow — read the list, send the one they
    /// meant, and if that is not there, say so and name what is.
    private func theBrainCanFindIt(_ entry: CallActionQueue.Entry) async -> Bool {
        log("[call] no single match for \"\(entry.what)\"; asking the brain to find it")
        let outcome = await runInstruction("""
            On the call that just ended the owner asked you to send them "\(entry.asked)". \
            List the saved files, work out which one they meant, and send it with send_file. \
            If nothing there is actually the thing they asked for, tell them plainly that you \
            could not find it and name what you do have — do not send a different file instead, \
            and do not say you have sent something you have not.
            """, recipient(for: entry))
        switch outcome {
        case .sent:
            queue.remove(entry)
            return true
        case .sentWithoutTheFiles:
            // The brain found the request and told the owner the attachment
            // failed. Do not follow that with a contradictory canned
            // "ambiguous/missing" report, and do not discharge the file.
            return true
        case .failed:
            return false
        }
    }

    private func messageTheAgent(_ entry: CallActionQueue.Entry) async throws {
        guard let who = entry.who else { return }
        let messaging = SageAgentMessaging(tools: tools)
        // Resolved at drain time, and `findAgent` refuses an ambiguous name
        // rather than picking — the guard the 1ab7aa10 / 74140c2d mix-up
        // lacked, which is how the owner's messages reached strangers.
        let address = try await messaging.findAgent(named: who)
        // The entry's own key, minted at enqueue. A re-drain presents the same
        // key and SAGE returns the original message_id instead of sending twice.
        _ = try await messaging.send(entry.what, to: address, intent: nil, retrying: entry.key)
        let outcome = await deliver(
            "I've sent your message to \(address.displayName).", [], recipient(for: entry)
        )
        if outcome != .failed { queue.remove(entry) }
    }

    // MARK: - Telling the owner about work that will not happen

    private func report(_ entries: [CallActionQueue.Entry]) async {
        for entry in entries {
            let outcome = await deliver(
                "On an earlier call you asked me to \(entry.spokenLine), and I didn't get to it — "
                    + "I was restarted before I could. Ask me here and I'll do it now.",
                [], recipient(for: entry)
            )
            // Cleared only once the owner has actually been told. A report that
            // failed to send is still owed.
            if outcome != .failed { queue.remove(entry) }
        }
    }

    private func recipient(for entry: CallActionQueue.Entry) -> ChannelRecipient? {
        entry.recipient?.channelRecipient
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}
