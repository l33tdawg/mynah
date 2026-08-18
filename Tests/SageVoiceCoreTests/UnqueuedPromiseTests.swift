// **Mac-only, because the live voice call is a Mac feature.**
//
// `Sources/SageVoiceCore/Call` is excluded from the target off Darwin — see
// `coreExclusions` in Package.swift — so none of the types below exist there.
// The exclusion and this guard are two halves of one decision, and the tests
// have to carry their half explicitly: a test file that cannot compile does not
// fail loudly, it takes the whole target down with it and every other test in
// the suite stops running too. That is what happened here.
#if os(macOS)
import XCTest
@testable import SageVoiceCore

/// **"call works but ferry tickets never showed up".**
///
/// 6 August 2026, the first real call the after-the-call queue ever saw, on
/// 1.8.0, the release whose notes said the queue was *"not yet proven on a real
/// call"*. From the owner's `bridge.log`, verbatim:
///
///     15:38:57 [call] heard: Can you send me the ferry ticket after this call?
///     15:39:01 [call] replying: Will do — I'll send the ferry ticket to your
///                               Signal thread right after we hang up.
///     15:39:08 [call] the call ended
///
/// No `[call] queued for after the call:` line, no `after-the-call.json` on
/// disk, no ticket. Every part of the feature worked except the one that had to
/// happen first: the model never called `after_the_call`. It said the sentence
/// and skipped the tool.
///
/// It was not a coin flip. `BrainPrompts.onACall` read *"call `after_the_call`
/// to queue it … then tell them in one short line that you will do it after you
/// hang up"* — two instructions, only one of which the owner can hear, and the
/// audible one is free. A model optimising for a good-sounding turn takes the
/// free one every time.
///
/// So the prompt no longer hands out the sentence, and — because a prompt asks
/// where this needs something that tells — two layers check the fact:
/// `ToolLoop` against its own trace, with a retry, and `CallTurnServer` against
/// the queue on disk, which is the ground truth the trace cannot see.
final class UnqueuedPromiseTests: XCTestCase {

    /// A fresh subdirectory, for the reason `AfterTheCallTests.temporaryQueue`
    /// documents: `OwnerOnlyFileSecurity.write` chmods the *parent* to 0700 and
    /// swallows the failure, so a queue rooted at the shared temp directory
    /// silently persists nothing.
    private func temporaryQueue() throws -> CallActionQueue {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-unqueued-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("after-the-call.json")
        return CallActionQueue(fileURL: url)
    }

    // MARK: - What counts as a promise

    /// The sentence from the log, exactly as it was spoken down the line.
    func testTheReplyThatShippedTheBug() {
        XCTAssertTrue(AfterTheCall.commitsToDoingItLater(
            "Will do — I'll send the ferry ticket to your Signal thread right after we hang up."
        ))
    }

    func testTheOrdinaryWaysOfPromisingIt() {
        for reply in [
            "Sure, I'll send that over after we hang up.",
            "Noted — I'll message Oki about it once the call is done.",
            "I will get that to you after the call.",
            "Consider it done, right after this call.",
            "Leave it with me — after we hang up I'll sort it.",
            "I'm going to put that together once we're done here."
        ] {
            XCTAssertTrue(AfterTheCall.commitsToDoingItLater(reply), reply)
        }
    }

    // MARK: - What must not count

    /// **The expensive false positive, and the reason the predicate has three
    /// conditions rather than one.**
    ///
    /// This is the honest answer when there is genuinely nothing to queue, and
    /// it is the exact sentence `ToolLoop.unqueuedPromiseCorrection` asks the
    /// model for. Counting it as a broken promise would mean retrying the
    /// model's compliance with the correction, and then replacing a
    /// well-worded, contextual answer with a canned one.
    func testHandingTheNextMoveBackToTheOwnerIsNotAPromise() {
        for reply in [
            "I can't send files while we're on the line — message me in the chat after the "
                + "call and I'll send it over.",
            "Ask me again in the thread after we hang up and I'll dig it out.",
            "Let me know after the call and I'll get it to you.",
            "Text me once we're done and I'll fire it across."
        ] {
            XCTAssertFalse(AfterTheCall.commitsToDoingItLater(reply), reply)
        }
    }

    /// A question or an observation about after the call commits to nothing.
    func testMentioningTheCallEndingIsNotAPromise() {
        for reply in [
            "Do you want that after the call, or now?",
            "There's nothing else outstanding after this call.",
            "That meeting is right after the call with David.",
            "Anything you need once we hang up?"
        ] {
            XCTAssertFalse(AfterTheCall.commitsToDoingItLater(reply), reply)
        }
    }

    /// A commitment with no horizon is an ordinary answer, and the daemon makes
    /// them all day.
    func testAPromiseWithNoAfterTheCallHorizonIsNotThisOne() {
        XCTAssertFalse(AfterTheCall.commitsToDoingItLater("I'll add that to your list now."))
        XCTAssertFalse(AfterTheCall.commitsToDoingItLater("Will do."))
    }

    /// The looser sibling still says yes to all of these — the two predicates
    /// are deliberately different, and this is what stops somebody
    /// "simplifying" them into one.
    func testTheLooseCheckIsStillLooseWhereItNeedsToBe() {
        let honest = "Message me in the chat after the call and I'll send it over."
        XCTAssertTrue(
            AfterTheCall.alreadyPromises(honest),
            "adding a second promise on top of this one would be noise, so the loose check "
                + "must keep catching it"
        )
        XCTAssertFalse(
            AfterTheCall.commitsToDoingItLater(honest),
            "but contradicting it would be calling an honest answer a broken promise"
        )
    }

    // MARK: - The loop catches it and sends the model back

    private func callCatalogue() -> [MCPTool] {
        [
            MCPTool(
                name: AfterTheCallToolSource.toolName,
                description: "queue it",
                inputSchema: .object(["type": .string("object")])
            ),
            MCPTool(
                name: "sage_recall",
                description: "remember",
                inputSchema: .object(["type": .string("object")])
            )
        ]
    }

    /// **The repair.** The model promises without queueing, the loop tells it
    /// so, and the second attempt calls the tool — which is what the owner's own
    /// *"did you add it? i don't see it"* achieved by hand on the written
    /// surface, applied to the spoken one.
    func testAPromiseWithNothingQueuedIsSentBackAndTheSecondTryQueuesIt() async throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let generation = CallActionQueue.Generation(call: "call-1", turn: 1)

        let backend = ReplayingBackend([
            ReplayingBackend.saying("Will do — I'll send the ferry ticket to your Signal thread "
                + "right after we hang up."),
            ReplayingBackend.asking(AfterTheCallToolSource.toolName, arguments: [
                "kind": .string("send_file"), "what": .string("ferry ticket")
            ]),
            ReplayingBackend.saying("Got it — I'll get that to you after we hang up.")
        ])
        let loop = ToolLoop(
            backend: backend,
            mcp: AfterTheCallToolSource(queue: queue),
            configuration: .init(allowedToolNames: [AfterTheCallToolSource.toolName])
        )

        let result = try await CallActionQueue.$current.withValue(generation) {
            try await loop.run(transcript: "send me the ferry ticket after this call",
                               tools: callCatalogue())
        }

        XCTAssertEqual(result.trace.unqueuedPromises, 1)
        XCTAssertEqual(queue.queued(inTurn: generation), 1, "the retry actually queued it")
        XCTAssertTrue(result.reply.contains("after we hang up"), result.reply)
    }

    /// The correction is what the model is shown, so it has to name the fact and
    /// the way out — in that order, like the two beside it.
    func testTheCorrectionNamesTheToolThatWasNotCalled() {
        let correction = ToolLoop.unqueuedPromiseCorrection.lowercased()

        XCTAssertTrue(correction.contains("did not call"))
        XCTAssertTrue(correction.contains(AfterTheCallToolSource.toolName))
        XCTAssertTrue(correction.contains("nothing was written down"))
    }

    /// **Out of retries, the promise must not ship.** It is the one sentence
    /// that guarantees the owner stops asking, which is precisely why leaving it
    /// in is worse than saying nothing.
    func testAModelThatKeepsPromisingIsOverriddenWithSomethingTrue() async throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let generation = CallActionQueue.Generation(call: "call-1", turn: 1)

        let promise = "Will do — I'll send it right after we hang up."
        let backend = ReplayingBackend(
            Array(repeating: ReplayingBackend.saying(promise), count: 4)
        )
        let loop = ToolLoop(
            backend: backend,
            mcp: AfterTheCallToolSource(queue: queue),
            configuration: .init(allowedToolNames: [AfterTheCallToolSource.toolName])
        )

        let result = try await CallActionQueue.$current.withValue(generation) {
            try await loop.run(transcript: "send me the ferry ticket", tools: callCatalogue())
        }

        XCTAssertEqual(result.reply, AfterTheCall.couldNotQueue)
        XCTAssertFalse(result.reply.contains("hang up. I'll"), "no promise survives")
        XCTAssertGreaterThan(result.trace.unqueuedPromises, ToolLoop.maximumPromiseRetries)
    }

    /// **The guard is scoped to a call, not bolted onto every surface.** Off a
    /// call there is no `after_the_call` in the catalogue, and "I'll send that
    /// after the call" is then an ordinary sentence about a call this loop knows
    /// nothing about — the daemon says it while the owner is arranging one.
    func testTheSameSentenceShipsUntouchedWhereThereIsNoQueue() async throws {
        let backend = ReplayingBackend([
            ReplayingBackend.saying("Sure — I'll send that to you after the call.")
        ])
        let loop = ToolLoop(
            backend: backend,
            mcp: AfterTheCallToolSource(queue: try temporaryQueue()),
            configuration: .init(allowedToolNames: ["sage_recall"])
        )

        let result = try await loop.run(
            transcript: "can you send it later",
            tools: [MCPTool(name: "sage_recall", description: "remember",
                            inputSchema: .object(["type": .string("object")]))]
        )

        XCTAssertEqual(result.trace.unqueuedPromises, 0)
        XCTAssertEqual(result.reply, "Sure — I'll send that to you after the call.")
    }

    /// A turn that promised *and* queued is telling the truth and must be left
    /// alone. This is the whole happy path, and breaking it would make the
    /// feature useless in the name of protecting it.
    func testAPromiseBackedByAQueuedActionIsLeftAlone() async throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let generation = CallActionQueue.Generation(call: "call-1", turn: 1)

        let backend = ReplayingBackend([
            ReplayingBackend.asking(AfterTheCallToolSource.toolName, arguments: [
                "kind": .string("send_file"), "what": .string("ferry ticket")
            ]),
            ReplayingBackend.saying("Will do — I'll send the ferry ticket after we hang up.")
        ])
        let loop = ToolLoop(
            backend: backend,
            mcp: AfterTheCallToolSource(queue: queue),
            configuration: .init(allowedToolNames: [AfterTheCallToolSource.toolName])
        )

        let result = try await CallActionQueue.$current.withValue(generation) {
            try await loop.run(transcript: "send me the ferry ticket", tools: callCatalogue())
        }

        XCTAssertEqual(result.trace.unqueuedPromises, 0)
        XCTAssertEqual(result.reply, "Will do — I'll send the ferry ticket after we hang up.")
    }

    // MARK: - The queue is the ground truth

    /// **Scoped to the call, not the turn**, and the difference is a promise the
    /// appliance is going to keep. Queue in turn one, be asked about it in turn
    /// three, and "yes, that's still going out after we hang up" is ordinary
    /// speech — the per-turn count is zero there, and contradicting it would be
    /// the appliance calling itself a liar about something it has on disk.
    func testAPromiseAboutSomethingQueuedInAnEarlierTurnIsNotABrokenOne() throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let first = CallActionQueue.Generation(call: "call-1", turn: 1)
        let later = CallActionQueue.Generation(call: "call-1", turn: 3)

        _ = queue.enqueue(generation: first, kind: .file, what: "ferry ticket",
                          who: nil, asked: "ferry ticket")

        XCTAssertEqual(queue.queued(inTurn: later), 0, "nothing queued in this turn")
        XCTAssertTrue(queue.anythingQueued(onCall: "call-1"), "but the call has something")
    }

    /// Nothing anywhere on the call is the unambiguous case, and it is the one
    /// that shipped.
    func testACallThatQueuedNothingSaysSo() throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        XCTAssertFalse(queue.anythingQueued(onCall: "call-1"))
    }

    /// One call's work is not another's — a queue holding yesterday's abandoned
    /// entry must not vouch for today's promise.
    func testAnotherCallsWorkDoesNotCountAsThisCalls() throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        _ = queue.enqueue(generation: .init(call: "call-1", turn: 1), kind: .file,
                          what: "ferry ticket", who: nil, asked: "ferry ticket")
        queue.closeCall()
        queue.beginCall("call-2")

        XCTAssertTrue(queue.anythingQueued(onCall: "call-1"))
        XCTAssertFalse(queue.anythingQueued(onCall: "call-2"))
    }

    /// **`draining` counts.** By the time the drain is running the promise is
    /// being kept, so an entry in that state is evidence for it, not against.
    /// Reading only `queued` here would make every promise look broken the
    /// instant the work started.
    func testWorkAlreadyBeingDoneStillVouchesForThePromise() throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        _ = queue.enqueue(generation: .init(call: "call-1", turn: 1), kind: .file,
                          what: "ferry ticket", who: nil, asked: "ferry ticket")
        _ = queue.claim(forCall: "call-1")

        XCTAssertTrue(queue.anythingQueued(onCall: "call-1"))
    }

    // MARK: - The prompt

    /// **The prompt no longer hands out the sentence.** It used to say "then
    /// tell them in one short line that you will do it after you hang up" beside
    /// the instruction to call the tool, which let a model satisfy the audible
    /// half and skip the half that works.
    func testThePromptDoesNotAuthoriseThePromiseInAdvance() {
        let prompt = BrainPrompts.onACall(base: "BASE")

        XCTAssertFalse(
            prompt.contains("tell them in one short line that you will do it after you hang up"),
            "this is the free sentence the ferry ticket was lost to"
        )
        XCTAssertTrue(prompt.contains("FIRST thing you do is call"))
        XCTAssertTrue(prompt.contains(AfterTheCallToolSource.toolName))
    }

    /// And it states the rule in the form the loop enforces, so the model is
    /// asked for the same thing it will be held to.
    func testThePromptForbidsPromisingWithoutTheToolCall() {
        let prompt = BrainPrompts.onACall(base: "BASE").lowercased()

        XCTAssertTrue(prompt.contains("never tell the owner you will send"))
        XCTAssertTrue(prompt.contains("unless you have called"))
    }

    // MARK: - What the owner hears instead

    /// **Every dead end needs a door.** The correction is useless if it leaves
    /// the owner with a thing they asked for, a promise they now know is
    /// worthless, and no idea what to do — the Signal thread has the tools a
    /// call does not, and asking there works in ten seconds.
    func testTheCorrectedLineNamesTheNextThingToDo() {
        let line = AfterTheCall.couldNotQueue.lowercased()

        XCTAssertTrue(line.contains("haven't got it written down"))
        XCTAssertTrue(line.contains("chat"), "no door: \(AfterTheCall.couldNotQueue)")
        XCTAssertFalse(AfterTheCall.commitsToDoingItLater(AfterTheCall.couldNotQueue),
                       "the sentence that corrects a false promise must not read as another one")
    }

    // MARK: - The second reason the ticket never came

    /// **The owner's real notes directory, as it stood on the day.** The
    /// caption they sent the photo with became the title; the words they used on
    /// the phone were different ones for the same thing.
    private func notesDirectoryLikeTheOwners() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-notes-\(UUID().uuidString)", isDirectory: true)
        let attachments = root.appendingPathComponent(
            SignalAttachmentStore.subdirectory, isDirectory: true
        )
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(
            to: attachments.appendingPathComponent("here-s-the-ferry-booking-please-store-it-4ee798.jpg")
        )
        try Data("# trip".utf8).write(to: root.appendingPathComponent("thailand-trip-bookings.md"))
        return root
    }

    private func notesDirectory(with files: [String: UInt64]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-drain-branches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, size) in files {
            let url = root.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: size)
            try handle.close()
        }
        return root
    }

    private func assertReportDeliveryControlsRemoval(
        title: String,
        notesDirectory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for reportOutcome in [AfterTheCallDelivery.failed, .sent] {
            let queue = try temporaryQueue()
            queue.beginCall("call-1")
            let entry = try XCTUnwrap(queue.enqueue(
                generation: .init(call: "call-1", turn: 1), kind: .file,
                what: title, who: nil, asked: "send \(title)"
            ), file: file, line: line)
            let drain = AfterTheCallDrain(
                queue: queue,
                notesDirectory: notesDirectory,
                tools: AfterTheCallToolSource(queue: queue),
                deliver: { _, _ in reportOutcome },
                runInstruction: { _ in .failed }
            )

            await drain.drain(mine: [entry], abandoned: [])

            XCTAssertEqual(
                queue.everything().map(\.key),
                reportOutcome == .failed ? [entry.key] : [],
                "the branch did not make removal depend on its owner-facing report",
                file: file,
                line: line
            )
        }
    }

    /// **The matcher cannot join "ticket" to "booking", and must not try.**
    ///
    /// Four widening rules and none of them get there, because none of them can:
    /// that is a question about meaning, and `slugs(matching:)` is deliberately
    /// word-wise so "art" cannot match "cartier". Fixing this by loosening the
    /// matcher would buy the ferry ticket at the price of sending the wrong file
    /// to somebody else.
    func testTheWordsTheOwnerSaidDoNotMatchTheWordsTheFileIsFiledUnder() {
        let stored = ["here-s-the-ferry-booking-please-store-it", "thailand-trip-bookings"]

        XCTAssertEqual(StoredFiles.slugs(matching: "ferry-ticket", among: stored), [])
        XCTAssertEqual(
            StoredFiles.slugs(matching: "ferry-booking", among: stored),
            ["here-s-the-ferry-booking-please-store-it"],
            "the matcher is not broken — it is being asked a question it cannot answer"
        )
    }

    /// So an unresolved title goes to a brain turn, which is the path that
    /// demonstrably worked: a minute after hanging up the owner typed "send me
    /// the ferry ticket" into Signal and `list_notes` → `read_note` →
    /// `send_file` got it right first time.
    func testAnUnmatchedTitleIsHandedToTheBrainRatherThanApologisedFor() async throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let entry = try XCTUnwrap(queue.enqueue(
            generation: .init(call: "call-1", turn: 1), kind: .file,
            what: "the ferry ticket", who: nil, asked: "the ferry ticket"
        ))

        let watcher = DrainWatcher()
        let drain = AfterTheCallDrain(
            queue: queue,
            notesDirectory: try notesDirectoryLikeTheOwners(),
            tools: AfterTheCallToolSource(queue: queue),
            deliver: { text, files in await watcher.delivered(text, files); return .sent },
            runInstruction: { text in await watcher.instructed(text); return .sent }
        )

        await drain.drain(mine: [entry], abandoned: [])

        let instructions = await watcher.instructions
        XCTAssertEqual(instructions.count, 1, "the brain was never asked")
        XCTAssertTrue(instructions[0].contains("the ferry ticket"), instructions[0])
        let apologies = await watcher.messages
        XCTAssertTrue(apologies.isEmpty, "it apologised instead of trying")
        XCTAssertTrue(queue.everything().isEmpty, "the entry was dealt with")
    }

    /// **The narrow permission.** The failure mode of asking a model to resolve
    /// a fuzzy name is that it sends the closest thing rather than admitting it
    /// is unsure — and a wrong file arriving unannounced an hour after a call is
    /// worse than no file, because the owner acts on it.
    func testTheBrainIsToldNotToSendTheNearestThingInstead() async throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let entry = try XCTUnwrap(queue.enqueue(
            generation: .init(call: "call-1", turn: 1), kind: .file,
            what: "the ferry ticket", who: nil, asked: "the ferry ticket"
        ))

        let watcher = DrainWatcher()
        let drain = AfterTheCallDrain(
            queue: queue,
            notesDirectory: try notesDirectoryLikeTheOwners(),
            tools: AfterTheCallToolSource(queue: queue),
            deliver: { _, _ in .sent },
            runInstruction: { text in await watcher.instructed(text); return .sent }
        )
        await drain.drain(mine: [entry], abandoned: [])

        let asked = await watcher.instructions
        let instruction = try XCTUnwrap(asked.first).lowercased()
        XCTAssertTrue(instruction.contains("do not send a different file"), instruction)
        XCTAssertTrue(instruction.contains("could not find it"), instruction)
    }

    func testABrainResolvedFileWhoseAttachmentFailedStaysQueuedWithoutACannedContradiction() async throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let entry = try XCTUnwrap(queue.enqueue(
            generation: .init(call: "call-1", turn: 1), kind: .file,
            what: "the ferry ticket", who: nil, asked: "the ferry ticket"
        ))
        let watcher = DrainWatcher()
        let drain = AfterTheCallDrain(
            queue: queue,
            notesDirectory: try notesDirectoryLikeTheOwners(),
            tools: AfterTheCallToolSource(queue: queue),
            deliver: { text, files in
                await watcher.delivered(text, files)
                return .sent
            },
            runInstruction: { _ in .sentWithoutTheFiles }
        )

        await drain.drain(mine: [entry], abandoned: [])

        XCTAssertEqual(queue.everything().map(\.key), [entry.key])
        let cannedReports = await watcher.messages
        XCTAssertTrue(cannedReports.isEmpty, "a truthful attachment failure was contradicted")
    }

    /// A turn that could not run at all still owes the owner an explanation, and
    /// the old message is exactly that. The fallback adds a path; it does not
    /// remove the floor.
    func testABrainTurnThatCannotRunStillTellsTheOwnerWhatHappened() async throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let entry = try XCTUnwrap(queue.enqueue(
            generation: .init(call: "call-1", turn: 1), kind: .file,
            what: "the ferry ticket", who: nil, asked: "the ferry ticket"
        ))

        let watcher = DrainWatcher()
        let drain = AfterTheCallDrain(
            queue: queue,
            notesDirectory: try notesDirectoryLikeTheOwners(),
            tools: AfterTheCallToolSource(queue: queue),
            deliver: { text, files in await watcher.delivered(text, files); return .sent },
            runInstruction: { _ in .failed }
        )
        await drain.drain(mine: [entry], abandoned: [])

        let messages = await watcher.messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("couldn't find it"), messages[0])
        XCTAssertTrue(messages[0].contains("What I do have"), messages[0])
    }

    func testAnUndeliveredMissingFileReportStaysQueuedOnItsOriginatingThread() async throws {
        let queue = try temporaryQueue()
        let origin = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )
        queue.expectCall(from: origin)
        queue.beginCall("call-1")
        let entry = try XCTUnwrap(queue.enqueue(
            generation: .init(call: "call-1", turn: 1), kind: .file,
            what: "a file that does not exist", who: nil, asked: "send the missing file"
        ))

        let recipientWatcher = RecipientWatcher()
        let drain = AfterTheCallDrain(
            queue: queue,
            notesDirectory: try notesDirectoryLikeTheOwners(),
            tools: AfterTheCallToolSource(queue: queue),
            deliver: { _, _, recipient in
                await recipientWatcher.saw(recipient)
                return .failed
            },
            runInstruction: { _, recipient in
                await recipientWatcher.saw(recipient)
                return .failed
            }
        )
        await drain.drain(mine: [entry], abandoned: [])

        XCTAssertEqual(queue.everything().map(\.key), [entry.key])
        let recipients = await recipientWatcher.recipients
        XCTAssertFalse(recipients.isEmpty)
        XCTAssertTrue(recipients.allSatisfy { $0 == origin })
    }

    func testAnExactFileRefusalIsRemovedOnlyAfterItsReportDelivers() async throws {
        let notes = try notesDirectory(with: [
            "oversized-deck.md": UInt64(NotesToolSource.maximumAttachmentBytes + 1)
        ])
        guard case .one = StoredFiles(directory: notes).match(title: "oversized deck") else {
            return XCTFail("test fixture no longer reaches the exact-match refusal branch")
        }
        try await assertReportDeliveryControlsRemoval(title: "oversized deck", notesDirectory: notes)
    }

    func testAnAmbiguousFileReportIsRemovedOnlyAfterItDelivers() async throws {
        let notes = try notesDirectory(with: ["q3-budget.md": 1, "q3-forecast.md": 1])
        guard case .several = StoredFiles(directory: notes).match(title: "q3") else {
            return XCTFail("test fixture no longer reaches the ambiguous-match branch")
        }
        try await assertReportDeliveryControlsRemoval(title: "q3", notesDirectory: notes)
    }

    func testAMissingFileReportIsRemovedOnlyAfterItDelivers() async throws {
        let notes = try notesDirectory(with: ["something-else.md": 1])
        guard case .nothing = StoredFiles(directory: notes).match(title: "missing deck") else {
            return XCTFail("test fixture no longer reaches the missing-match branch")
        }
        try await assertReportDeliveryControlsRemoval(title: "missing deck", notesDirectory: notes)
    }

    /// **The fast path stays fast.** A title the matcher resolves outright is
    /// sent from the drain's own notes instance — no model, no turn ceiling, no
    /// waiting. Adding a fallback must not turn every send into a brain turn.
    func testAnExactMatchNeverPaysForABrainTurn() async throws {
        let queue = try temporaryQueue()
        queue.beginCall("call-1")
        let entry = try XCTUnwrap(queue.enqueue(
            generation: .init(call: "call-1", turn: 1), kind: .file,
            what: "thailand trip bookings", who: nil, asked: "thailand trip bookings"
        ))

        let watcher = DrainWatcher()
        let drain = AfterTheCallDrain(
            queue: queue,
            notesDirectory: try notesDirectoryLikeTheOwners(),
            tools: AfterTheCallToolSource(queue: queue),
            deliver: { text, files in await watcher.delivered(text, files); return .sent },
            runInstruction: { text in await watcher.instructed(text); return .sent }
        )
        await drain.drain(mine: [entry], abandoned: [])

        let asked = await watcher.instructions
        let attached = await watcher.attachmentCounts
        XCTAssertTrue(asked.isEmpty, "a resolved title asked the brain anyway")
        XCTAssertEqual(attached, [1], "the file did not ride")
    }

    /// The log can tell this apart from its two neighbours, because all three
    /// call for different fixes.
    func testTheLogDistinguishesItFromTheOtherTwoFailures() {
        var trace = ToolLoopTrace(model: "m", toolsOffered: 16)
        trace.unqueuedPromises = 2

        XCTAssertTrue(trace.summary.contains("[UNQUEUED 2]"), trace.summary)
        XCTAssertFalse(trace.summary.contains("[UNBACKED"), trace.summary)
        XCTAssertFalse(trace.summary.contains("[PROMISED"), trace.summary)
    }
}

/// What the drain did, in order. An actor because the drain's two closures are
/// `@Sendable` and it runs them from a detached context in production.
private actor DrainWatcher {
    private(set) var messages: [String] = []
    private(set) var attachmentCounts: [Int] = []
    private(set) var instructions: [String] = []

    func delivered(_ text: String, _ files: [URL]) {
        messages.append(text)
        attachmentCounts.append(files.count)
    }

    func instructed(_ text: String) {
        instructions.append(text)
    }
}

private actor RecipientWatcher {
    private(set) var recipients: [ChannelRecipient?] = []

    func saw(_ recipient: ChannelRecipient?) {
        recipients.append(recipient)
    }
}

/// A backend that replays a scripted list of replies, one per request.
///
/// A local copy of `ToolLoopTests`' stub because that one is `private` to its
/// file, and widening it would make every test that uses it a dependency of
/// this one.
private final class ReplayingBackend: BrainBackend, @unchecked Sendable {
    let identifier = "replaying"
    let modelName = "stub-model"
    let isLocal = true

    private let lock = NSLock()
    private var script: [BrainReply]

    init(_ script: [BrainReply]) {
        self.script = script
    }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        lock.lock()
        defer { lock.unlock() }
        guard !script.isEmpty else {
            throw BrainBackendError.requestRejected("the stub ran out of scripted replies")
        }
        return script.removeFirst()
    }

    static func saying(_ text: String) -> BrainReply {
        BrainReply(
            model: "stub-model",
            message: .assistant(text),
            stopReason: .endTurn,
            usage: BrainUsage(inputTokens: 10, outputTokens: 5)
        )
    }

    static func asking(_ name: String, arguments: [String: JSONValue] = [:]) -> BrainReply {
        BrainReply(
            model: "stub-model",
            message: BrainMessage(
                role: .assistant,
                content: "",
                toolCalls: [BrainToolCall(id: "call_1", name: name, arguments: arguments)]
            ),
            stopReason: .toolUse,
            usage: BrainUsage(inputTokens: 10, outputTokens: 5)
        )
    }
}
#endif  // os(macOS)
