import XCTest
@testable import SageVoiceCore

/// **A call queues actions for after the call, and never sends during it.**
///
/// The owner's ruling, 5 August 2026: "calls cannot send files bro - calls are
/// for actionable things that happen AFTER the call ... but sending files
/// should be done at the end".
///
/// The note recording that ruling said the call catalogue "must keep
/// subtracting `NotesToolSource.toolNames`", which reads as a description of
/// what the code already did. **It never did.** The call builds its loop from
/// `Configuration.forStyle(.spoken)`, whose `allowedToolNames` defaulted to
/// `voiceToolAllowlist`, and that unioned the notes tools in. The one
/// `.subtracting(NotesToolSource.toolNames)` in the tree was an
/// `expectedToolNames` health check on the SAGE source and had nothing to do
/// with what a model may call. So `send_file` was live on every call from the
/// day calls shipped, and the rule was a rule nothing enforced.
///
/// These tests are what enforce it.
///
/// **The catalogue assertions moved to `ApplianceCatalogueTests`** when
/// curation moved into `CompositeToolSource`. They used to read a name out of a
/// `Set<String>` in `BrainPrompts`; they now compose the real call catalogue
/// and call `send_file` on it, which is the difference between asserting the
/// filter and asserting the mechanism. What stays here is the wiring check —
/// that the call surface is actually built from the call catalogue — and
/// everything about the queue itself.
final class AfterTheCallTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A fresh subdirectory, not the shared temp directory itself.
    /// `OwnerOnlyFileSecurity.write` chmods the *parent* to 0700, which fails on
    /// a directory this process does not own — and it fails silently, because
    /// the store swallows write errors on purpose. Writing straight into
    /// `NSTemporaryDirectory()` therefore produced a queue that never persisted
    /// anything and three tests that looked like real durability failures.
    private func temporaryQueue() throws -> (CallActionQueue, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-after-the-call-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("after-the-call.json")
        return (CallActionQueue(fileURL: url), url)
    }

    private func generation(_ call: String, _ turn: Int = 1) -> CallActionQueue.Generation {
        CallActionQueue.Generation(call: call, turn: turn)
    }

    // MARK: - The catalogue

    /// **Filtering the allowlist was the weaker half, and it is gone.**
    /// `CompositeToolSource` builds its name→provider table from what each
    /// source publishes, so a notes source left registered would still route
    /// `send_file` for a model that produced the name anyway. Not registering
    /// it is what makes the name genuinely unreachable — proven end to end in
    /// `ApplianceCatalogueTests.testACallCannotReachTheNotesTools`, which calls
    /// the tool and gets `Failure.unknownTool` back.
    ///
    /// This is the other half: that the daemon is wired to that catalogue at
    /// all. A perfect call catalogue nothing is built from proves nothing.
    ///
    /// **It used to assert a third thing** — that `main.swift` contained the
    /// literal `callConfiguration.allowedToolNames = BrainPrompts
    /// .callToolAllowlist`. That line is deleted, and deliberately: it was set
    /// arithmetic undoing a union performed four lines from where it was
    /// written. The assertion is inverted rather than dropped, because the way
    /// this regresses is somebody reaching for a name filter again instead of
    /// leaving the source unregistered.
    func testTheCallSourceDoesNotRegisterTheNotesProviderAtAll() throws {
        let main = try text("Sources/sage-voiced/main.swift")
        XCTAssertTrue(
            main.contains("func makeCallToolSource("),
            "the call still builds its catalogue from makeToolSource, which registers the notes "
                + "provider — so send_file stays routable however the allowlist is filtered"
        )
        XCTAssertTrue(
            main.contains("ApplianceCatalogue.call("),
            "makeCallToolSource no longer composes the call catalogue, so whatever it returns "
                + "has not been through the one place that knows a call registers no notes source"
        )
        XCTAssertTrue(
            main.contains("mcp: callTools"),
            "the call loop is not wired to the call-only catalogue"
        )
        XCTAssertFalse(
            code(main).contains("callConfiguration.allowedToolNames"),
            "the call surface is filtering tool names again. A filtered name still routes if its "
                + "provider is registered — that is exactly how send_file stayed live on every "
                + "call while a design note claimed it was subtracted."
        )
    }

    /// Comments stripped, because the assertion above is about what the daemon
    /// *does* and the line it forbids is quoted in a comment two lines from
    /// where it used to live — a tombstone saying why it went. A grep that
    /// cannot tell code from prose turns "explain the deletion" into "reinstate
    /// the defect", which teaches the next person to delete the explanation.
    ///
    /// Line comments only. This is not a Swift parser and does not need to be:
    /// the file has no block comment, and a guard that quietly did less than it
    /// claimed would be worse than this one being narrow on purpose.
    private func code(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The prompt instructs, in the imperative, to use `list_notes` then
    /// `send_file`. On a call those tools are gone, and a prompt naming a tool
    /// the model cannot call is the exact rot `PromptNamesOnlyRealToolsTests`
    /// exists to catch — one surface over, where it never looked.
    func testTheCallPromptRetractsExactlyTheToolsItRemoved() {
        let prompt = BrainPrompts.onACall(base: "BASE")
        XCTAssertTrue(prompt.contains("BASE"), "the call prompt replaces the shared body instead of layering on it")

        guard let line = prompt
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("NOT ON A CALL:") })
        else {
            return XCTFail("the call prompt has no machine-readable retraction line, so a tool "
                + "removed from the catalogue can go on being named in the prompt unnoticed")
        }
        let retracted = Set(
            line.replacingOccurrences(of: "NOT ON A CALL:", with: "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        XCTAssertEqual(
            retracted, NotesToolSource.toolNames,
            "the retraction line and the actual subtraction disagree, so the model is either "
                + "told it lost a tool it still has or kept one it does not"
        )
        XCTAssertTrue(
            prompt.contains(AfterTheCallToolSource.toolName),
            "the prompt never names the one tool the call does have"
        )
    }

    func testReachableCallGuidanceNamesTheOriginatingChatRatherThanSignal() async throws {
        let queue = try temporaryQueue().0
        let tools = try await AfterTheCallToolSource(queue: queue).listTools()
        let description = try XCTUnwrap(tools.first?.description).lowercased()
        let queued = AfterTheCallToolSource.queued.lowercased()
        let ceiling = CallTurnServer.tookTooLong.lowercased()

        XCTAssertTrue(description.contains("same chat that requested the call"), description)
        XCTAssertTrue(queued.contains("chat that requested the call"), queued)
        XCTAssertTrue(ceiling.contains("your chat"), ceiling)
        XCTAssertFalse(description.contains("signal"), description)
        XCTAssertFalse(queued.contains("signal"), queued)
        XCTAssertFalse(ceiling.contains("signal"), ceiling)
    }

    // MARK: - The orphaned turn

    /// **The bug that survives the obvious design.**
    ///
    /// `withDeadline` runs the turn in an unstructured task and walks away on
    /// overrun; `MCPClient` reads the node's pipe with no deadline, so the
    /// orphan can come back minutes later and still dispatch its tool calls.
    /// A "is a call open?" check passes in exactly that window: the caller heard
    /// `tookTooLong`, hung up, redialled, and the orphan queues call A's request
    /// against call B — which then performs it and writes it into call B's
    /// transcript, for a call the owner was told had failed.
    func testATurnFromAnEndedCallCannotQueueIntoTheNextOne() throws {
        let (queue, _) = try temporaryQueue()
        let callA = generation("A")

        queue.beginCall("A")
        _ = queue.claim(forCall: "A")          // A ends having queued nothing
        queue.beginCall("B")                    // the caller redials

        XCTAssertNil(
            queue.enqueue(generation: callA, kind: .file, what: "the ferry ticket", who: nil, asked: "x"),
            "a turn belonging to a call that has ended queued work against the call that is open "
                + "now, so the owner would be sent something they asked for on a call they were "
                + "told had failed"
        )
        XCTAssertTrue(queue.everything().isEmpty)
    }

    /// The counterpart: the live call's own turn is accepted.
    func testTheLiveCallsOwnTurnIsQueued() throws {
        let (queue, _) = try temporaryQueue()
        queue.beginCall("A")
        let entry = queue.enqueue(
            generation: generation("A"), kind: .file, what: "the ferry ticket", who: nil, asked: "x"
        )
        XCTAssertNotNil(entry)
        XCTAssertEqual(queue.everything().count, 1)
    }

    /// The spoken backstop must count what THIS turn queued. A process-wide
    /// counter would report an orphan's enqueue against whichever turn happens
    /// to be running — the defect `FillerTally` was made a per-turn box for.
    func testQueuedCountIsPerTurnNotPerProcess() throws {
        let (queue, _) = try temporaryQueue()
        queue.beginCall("A")
        _ = queue.enqueue(generation: generation("A", 1), kind: .file, what: "a", who: nil, asked: "a")
        _ = queue.enqueue(generation: generation("A", 2), kind: .file, what: "b", who: nil, asked: "b")

        XCTAssertEqual(queue.queued(inTurn: generation("A", 1)), 1)
        XCTAssertEqual(queue.queued(inTurn: generation("A", 2)), 1)
        XCTAssertEqual(
            queue.queued(inTurn: generation("A", 3)), 0,
            "a turn that queued nothing is told it did, so the caller hears a promise about work "
                + "they never asked for"
        )
    }

    // MARK: - Surviving the crash

    /// **Claimed, not cleared.**
    ///
    /// Taking the entries and emptying the file leaves the only copy of the
    /// owner's queued work in a detached task's memory — and launchd SIGTERMs
    /// this daemon on every reconcile. The appliance would have posted "I'll
    /// send you three files" into the thread with nothing on disk and no path
    /// that would ever mention it again.
    func testClaimingLeavesTheWorkOnDiskUntilItIsConfirmed() throws {
        let (queue, url) = try temporaryQueue()
        queue.beginCall("A")
        _ = queue.enqueue(generation: generation("A"), kind: .file, what: "the deck", who: nil, asked: "x")

        let taken = queue.claim(forCall: "A")
        XCTAssertEqual(taken.mine.count, 1)

        // A second instance is the next process after a crash.
        let afterCrash = CallActionQueue(fileURL: url)
        XCTAssertEqual(
            afterCrash.everything().count, 1,
            "the queue was emptied at hang-up, so a restart mid-drain loses work the appliance "
                + "has already promised out loud"
        )
        XCTAssertEqual(
            afterCrash.everything().first?.state, .draining,
            "a recovered entry is indistinguishable from one that was never started, so it would "
                + "be performed again rather than reported"
        )
    }

    /// And the confirmed outcome is the only thing that deletes.
    func testOnlyAConfirmedOutcomeRemovesAnEntry() throws {
        let (queue, url) = try temporaryQueue()
        queue.beginCall("A")
        let entry = try XCTUnwrap(
            queue.enqueue(generation: generation("A"), kind: .file, what: "the deck", who: nil, asked: "x")
        )
        _ = queue.claim(forCall: "A")
        queue.remove(entry)
        XCTAssertTrue(CallActionQueue(fileURL: url).everything().isEmpty)
    }

    /// Startup claims everything, because nothing is live then.
    func testStartupClaimsEverythingAsAbandoned() throws {
        let (queue, url) = try temporaryQueue()
        queue.beginCall("A")
        _ = queue.enqueue(generation: generation("A"), kind: .file, what: "the deck", who: nil, asked: "x")

        let next = CallActionQueue(fileURL: url)
        let found = next.claim(forCall: nil)
        XCTAssertTrue(found.mine.isEmpty)
        XCTAssertEqual(
            found.abandoned.count, 1,
            "work left by a dead process is not surfaced at startup, so the only reader is the "
                + "end of the NEXT call — a door that opens only if the owner rings back"
        )
    }

    func testQueuePersistsTheExactOriginatingWhatsAppThread() throws {
        let (queue, url) = try temporaryQueue()
        let origin = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )
        queue.expectCall(from: origin)
        queue.beginCall("A")
        _ = queue.enqueue(
            generation: generation("A"), kind: .file, what: "the deck", who: nil, asked: "send it"
        )

        let recovered = try XCTUnwrap(CallActionQueue(fileURL: url).everything().first?.recipient)
        XCTAssertEqual(recovered.channelRecipient, origin)
        XCTAssertEqual(recovered.channelRecipient.description, "whatsapp:60123821767@s.whatsapp.net")
        XCTAssertEqual(recovered.channelRecipient.address, "161228928336031@lid")
    }

    func testLegacyQueueEntryWithoutRecipientStillDecodes() throws {
        let (queue, url) = try temporaryQueue()
        queue.beginCall("A")
        _ = queue.enqueue(
            generation: generation("A"), kind: .file, what: "the deck", who: nil, asked: "send it"
        )

        let recovered = try XCTUnwrap(CallActionQueue(fileURL: url).everything().first)
        XCTAssertNil(recovered.recipient)
    }

    func testLegacyRecoveryFailsOverToTheNextLinkedChannel() async {
        let signal = ChannelRecipient(kind: .signal, address: "+60123821767")
        let whatsapp = ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net")
        let attempts = RecipientAttempts()

        let outcome = await AfterTheCallDrain.firstDelivery(to: [signal, whatsapp]) { recipient in
            await attempts.record(recipient)
            return recipient.kind == .signal ? .sentWithoutTheFiles : .sent
        }

        XCTAssertEqual(outcome, .sent)
        let attemptedRecipients = await attempts.values
        XCTAssertEqual(attemptedRecipients, [signal, whatsapp])
    }

    // MARK: - Changing your mind

    /// "send me the budget after this — no wait, forget that" is ordinary
    /// speech, and an append-only queue does both.
    func testTheOwnerCanTakeBackWhatTheyQueued() throws {
        let (queue, _) = try temporaryQueue()
        queue.beginCall("A")
        _ = queue.enqueue(generation: generation("A"), kind: .file, what: "the budget", who: nil, asked: "x")
        _ = queue.enqueue(generation: generation("A", 2), kind: .file, what: "the Q3 deck", who: nil, asked: "y")

        XCTAssertEqual(queue.forget(generation: generation("A", 2)), 2)
        XCTAssertTrue(queue.everything().isEmpty)
    }

    /// But not from a call that has ended.
    func testAnEndedCallCannotRetractAnything() throws {
        let (queue, _) = try temporaryQueue()
        queue.beginCall("A")
        _ = queue.enqueue(generation: generation("A"), kind: .file, what: "the budget", who: nil, asked: "x")
        _ = queue.claim(forCall: "A")
        queue.beginCall("B")
        XCTAssertEqual(queue.forget(generation: generation("A")), 0)
    }

    // MARK: - What the model is told

    /// The tool must never let the model report the thing as done. A model that
    /// has just called a tool successfully is strongly inclined to say so, and
    /// that claim is the exact lie this feature exists to end.
    func testTheToolResultForbidsClaimingItIsDone() async throws {
        let (queue, _) = try temporaryQueue()
        queue.beginCall("A")
        let source = AfterTheCallToolSource(queue: queue)

        let result = try await CallActionQueue.$current.withValue(generation("A")) {
            try await source.call(
                name: AfterTheCallToolSource.toolName,
                arguments: ["kind": .string("send_file"), "what": .string("the ferry ticket")]
            )
        }
        XCTAssertTrue(result.contains("QUEUED FOR AFTER THE CALL"))
        for forbidden in ["sent", "attached", "done"] {
            XCTAssertTrue(
                result.contains(forbidden),
                "the tool result does not tell the model to avoid saying \"\(forbidden)\", which "
                    + "is what it will otherwise say the moment the call succeeds"
            )
        }
        XCTAssertEqual(queue.everything().count, 1)
    }

    /// A late orphan gets a refusal that names the one thing it must not do.
    func testALateOrphanIsToldNotToClaimAnything() async throws {
        let (queue, _) = try temporaryQueue()
        let source = AfterTheCallToolSource(queue: queue)
        // No task-local at all: the turn is running outside any call.
        let result = try await source.call(
            name: AfterTheCallToolSource.toolName,
            arguments: ["kind": .string("send_file"), "what": .string("x")]
        )
        XCTAssertTrue(result.contains("NOTHING WAS QUEUED"))
        XCTAssertTrue(queue.everything().isEmpty)
    }

    /// `message_agent` without a recipient must refuse rather than queue a
    /// message with nowhere to go — the drain would resolve `nil` and drop it.
    func testMessagingAnAgentWithoutANameIsRefused() async throws {
        let (queue, _) = try temporaryQueue()
        queue.beginCall("A")
        let source = AfterTheCallToolSource(queue: queue)
        let result = try await CallActionQueue.$current.withValue(generation("A")) {
            try await source.call(
                name: AfterTheCallToolSource.toolName,
                arguments: ["kind": .string("message_agent"), "what": .string("hello")]
            )
        }
        XCTAssertTrue(result.contains("NOTHING WAS QUEUED"))
        XCTAssertTrue(queue.everything().isEmpty)
    }

    /// One name, not four. The call catalogue's budget is the scarcest one.
    func testTheSourcePublishesExactlyOneTool() async throws {
        let (queue, _) = try temporaryQueue()
        let published = try await AfterTheCallToolSource(queue: queue).listTools()
        XCTAssertEqual(published.map(\.name), [AfterTheCallToolSource.toolName])
    }

    // MARK: - What the caller hears

    func testTheCallerIsToldEvenWhenTheModelForgets() {
        XCTAssertTrue(
            AfterTheCall.promising("Sure thing.").contains(AfterTheCall.promise),
            "a reply that never mentions the queued work leaves the caller with no idea it "
                + "was taken, and a file arriving later with no explanation"
        )
    }

    func testItDoesNotPromiseTwice() {
        let already = "Yep, I'll send that after we hang up."
        XCTAssertEqual(AfterTheCall.promising(already), already)
    }

    // MARK: - Classification

    /// **Queueing is not acting.** `readOnlyTools` is inverted on purpose —
    /// anything unlisted counts as having changed something, which is what lets
    /// a claim of completed action through unchallenged. If `after_the_call`
    /// counted as an action, "I've sent the file" would be accepted on the
    /// strength of a queue write.
    func testQueueingDoesNotCountAsHavingDoneAnything() {
        XCTAssertTrue(
            ToolLoopTrace.readOnlyTools.contains(AfterTheCallToolSource.toolName),
            "queueing counts as acting, so the unbacked-claim guard would accept \"I've sent "
                + "the file\" when nothing has been sent"
        )
        XCTAssertTrue(
            ToolLoopTrace.sendingTools.contains(AfterTheCallToolSource.toolName),
            "nothing records that the request was ever made, so \"it said it queued something "
                + "and nothing drained\" is unanswerable from the log"
        )
    }

    // MARK: - The transcript, and what the next call remembers

    func testTheQueuedListIsBoundedSoItCannotEatTheClosingSummary() throws {
        var transcript = CallTranscript()
        transcript.heard("send me everything")
        transcript.queued(Array(repeating: String(repeating: "x", count: 400), count: 9))

        let line = try XCTUnwrap(transcript.lines.last?.text)
        XCTAssertLessThan(
            line.count, 2_000,
            "an unbounded queued line is the last thing in the transcript, and LastCall walks "
                + "backwards from the end against a 700-character budget"
        )
        XCTAssertTrue(line.contains("and 4 more"), "the list is not capped, so all nine are written out")
    }

    /// **A long final line used to erase the whole closing summary.**
    ///
    /// `LastCall.from` walks the transcript backwards and stopped dead at the
    /// first piece that overflowed, so a single over-budget last line left
    /// `closing` empty and saved that over a real record — the next call opening
    /// having forgotten everything, in the case with the most to remember.
    func testAnOverlongLastLineDoesNotWipeWhatTheNextCallRemembers() {
        var transcript = CallTranscript()
        transcript.heard("the short thing I said first")
        transcript.said(String(repeating: "y", count: 900))

        let record = LastCall.from(transcript)
        XCTAssertNotNil(record)
        XCTAssertFalse(
            record?.closing.isEmpty ?? true,
            "the closing summary is empty, so the next call opens knowing nothing about this one"
        )
    }

    // MARK: - Delivery honesty

    /// **A `true` from `reply` does not mean the file went.**
    ///
    /// `reply` retries without attachments when signal-cli refuses a send and
    /// returns that retry's success. A queue that deleted its entry on that
    /// boolean would tell the owner "here's the budget deck" with no deck
    /// attached and consider the promise kept — the silent broken promise this
    /// whole feature exists to end, arriving through the code meant to end it.
    func testTheDaemonCanRefuseToLaunderAFailedAttachmentSend() throws {
        let daemon = try text("Sources/SageVoiceCore/VoiceBridgeDaemon.swift")
        XCTAssertTrue(
            daemon.contains("attachmentsAreThePoint"),
            "reply has no way to say \"the files were the point\", so an after-the-call send "
                + "whose attachment was refused reports success"
        )
        XCTAssertTrue(
            daemon.contains("guard !attachmentsAreThePoint else {"),
            "the text-only fallback is still unconditional, so the caller cannot tell a delivered "
                + "file from a dropped one"
        )
        XCTAssertTrue(
            daemon.contains("case sentWithoutTheFiles") || daemon.contains("sentWithoutTheFiles"),
            "there is no three-way result, so the drain has only a Bool to decide on"
        )
    }

    /// The drain must not share the daemon's single outgoing buffer: the daemon
    /// discards that buffer on every incoming message and staples it to whatever
    /// reply is going out. Someone who just asked for a file after a call is
    /// unusually likely to message the thread in that exact window.
    func testTheDrainOwnsItsOwnNotesInstance() throws {
        let drain = try text("Sources/SageVoiceCore/Call/AfterTheCallDrain.swift")
        XCTAssertTrue(
            drain.contains("self.notes = NotesToolSource("),
            "the drain shares the daemon's NotesToolSource, so an incoming Signal message in the "
                + "hang-up window either discards the queued file or attaches it to an unrelated reply"
        )
    }

    /// The drain is started detached, or the shutdown that makes the work
    /// outstanding is the same event that kills it.
    func testTheDrainIsDetachedFromEveryCancelledTree() throws {
        let main = try text("Sources/sage-voiced/main.swift")
        XCTAssertTrue(
            main.contains("Task.detached {\n                await afterTheCallDrain.drain("),
            "the drain runs inside a tree that is cancelled at hang-up or shutdown, so the work "
                + "the call promised dies with the turn that promised it"
        )
        XCTAssertTrue(
            main.contains("await afterTheCallDrain.recoverAtStartup()"),
            "nothing reads the queue at startup, so a crash between hang-up and drain is silent "
                + "until the owner happens to place another call"
        )
    }

    /// The claim happens before the transcript is posted and before the call is
    /// remembered — `postTranscript` resets the transcript before it awaits
    /// delivery, so anything appended after it is never seen.
    func testTheQueuedListIsWrittenBeforeTheTranscriptIsPosted() throws {
        let server = try text("Sources/SageVoiceCore/Call/CallTurnServer.swift")
        // Both hang-up arms — the clean close and the endpoint error — must
        // carry it, which is why this counts rather than merely finding one.
        let pattern = try NSRegularExpression(
            pattern: #"queueTheAfterCallWork\(\)\s*\n\s*rememberThisCall\(\)\s*\n\s*await postTranscript\(\)"#
        )
        let inOrder = pattern.numberOfMatches(
            in: server,
            range: NSRange(server.startIndex..., in: server)
        )
        XCTAssertEqual(
            inOrder, 2,
            "the after-call work is not claimed between the turn being stopped and the transcript "
                + "being posted, so what was queued never reaches the owner's thread"
        )
    }
}

private actor RecipientAttempts {
    private(set) var values: [ChannelRecipient] = []

    func record(_ recipient: ChannelRecipient) {
        values.append(recipient)
    }
}
