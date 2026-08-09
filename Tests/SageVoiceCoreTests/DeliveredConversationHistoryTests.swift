import XCTest
@testable import SageVoiceCore

/// A conversation is the words that crossed the wire, not everything Mynah
/// composed while a transport was unavailable.
final class DeliveredConversationHistoryTests: XCTestCase {

    func testFailedWhatsAppAnswerIsNotReplayedAsConversationHistory() async throws {
        let fixture = try Fixture(answers: ["Blue.", "Green."], failures: 1)
        let message = fixture.message("do the thing", id: "wa-1", sequence: 1)

        let first = await fixture.daemon.handle(message)
        XCTAssertEqual(fixture.backend.recordedRequests.count, 1, "first outcome: \(first)")
        XCTAssertTrue(
            fixture.store.load().isEmpty,
            "an answer WhatsApp refused was written down as though the owner received it"
        )

        // The bridge still owns the unacknowledged message and presents it
        // again. The completed draft is retried directly; neither the model nor
        // its tools should run a second time.
        _ = await fixture.daemon.handle(message)

        let turns = try XCTUnwrap(fixture.store.load()[fixture.recipient.description])
        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns.map(\.content), ["do the thing", "Blue."])

        let requests = fixture.backend.recordedRequests
        XCTAssertEqual(requests.count, 1, "the replay reran the completed model turn")
    }

    func testFailedProactiveAnnouncementIsNotRemembered() async throws {
        let fixture = try Fixture(answers: [], failures: 1)

        let failed = await fixture.daemon.announce("news that did not land", to: fixture.recipient)
        XCTAssertFalse(failed)
        XCTAssertTrue(
            fixture.store.load().isEmpty,
            "a failed proactive send poisoned the next turn with news the owner never saw"
        )

        let delivered = await fixture.daemon.announce("news that landed", to: fixture.recipient)
        XCTAssertTrue(delivered)
        let turns = try XCTUnwrap(fixture.store.load()[fixture.recipient.description])
        XCTAssertEqual(turns.map(\.role), [.assistant])
        XCTAssertEqual(turns.map(\.content), ["news that landed"])
    }

    func testFailedAfterCallReportIsNotRemembered() async throws {
        let fixture = try Fixture(answers: [], failures: 1)

        let failed = await fixture.daemon.postAfterTheCall(
            "a report that did not land", to: fixture.recipient
        )
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(
            fixture.store.load().isEmpty,
            "an undelivered after-call report entered history while its queue entry stayed outstanding"
        )

        let delivered = await fixture.daemon.postAfterTheCall(
            "a report that landed", to: fixture.recipient
        )
        XCTAssertEqual(delivered, .sent)
        XCTAssertEqual(
            fixture.store.load()[fixture.recipient.description]?.map(\.content),
            ["a report that landed"]
        )
    }

    func testRestartReplayDeliversCompletedTurnWithoutRepeatingItsMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-delivery-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let pending = PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json"))
        let channel = FailableChannel(failures: 1)
        let tools = MutatingTools()
        let recipient = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )
        let message = ChannelMessage(
            kind: .whatsapp, recipient: recipient, id: "mutation-1", text: "save this",
            acknowledgementToken: 9, acknowledgementEpoch: "spool-a"
        )
        let firstBrain = AnsweringBackend(replies: [
            BrainReply(
                model: "stub",
                message: BrainMessage(role: .assistant, content: "", toolCalls: [
                    BrainToolCall(id: "write-1", name: "write_note", arguments: ["text": .string("kept")])
                ]),
                stopReason: .toolUse
            ),
            BrainReply(model: "stub", message: .assistant("Saved."), stopReason: .endTurn),
        ])
        let first = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: firstBrain, mcp: tools), conversations: conversations,
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )

        _ = await first.handle(message)
        XCTAssertEqual(tools.callCount, 1)
        XCTAssertTrue(conversations.load().isEmpty)

        // A fresh daemon models launchd restarting the process. Its backend has
        // no scripted reply: reaching it is a test failure, and repeating the
        // tool would increment the counter.
        let replayBrain = AnsweringBackend(replies: [])
        let restarted = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: replayBrain, mcp: tools), conversations: conversations,
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        let replayWithResolvedIdentity = ChannelMessage(
            kind: message.kind,
            recipient: ChannelRecipient(
                kind: .whatsapp,
                address: "60123821767@s.whatsapp.net"
            ),
            id: message.id,
            text: message.text,
            acknowledgementToken: message.acknowledgementToken,
            acknowledgementEpoch: message.acknowledgementEpoch
        )
        _ = await restarted.handle(replayWithResolvedIdentity)

        XCTAssertEqual(tools.callCount, 1, "the write ran again when the spool replayed the question")
        XCTAssertEqual(replayBrain.recordedRequests.count, 0, "the completed turn went back through the model")
        XCTAssertEqual(
            conversations.load()[replayWithResolvedIdentity.recipient.description]?.map(\.content),
            ["save this", "Saved."]
        )
    }

    func testPartialReplayOfCoalescedTurnUsesCompletedResultWithoutRepeatingMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-pending-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let pending = PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json"))
        let channel = FailableChannel(failures: 1)
        let tools = MutatingTools()
        let lidRecipient = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )
        let firstMessage = ChannelMessage(
            kind: .whatsapp, recipient: lidRecipient, id: "coalesced-a", text: "save",
            acknowledgementToken: 20, acknowledgementEpoch: "spool-a"
        )
        let secondMessage = ChannelMessage(
            kind: .whatsapp, recipient: lidRecipient, id: "coalesced-b", text: "this",
            acknowledgementToken: 21, acknowledgementEpoch: "spool-a"
        )
        let firstBrain = AnsweringBackend(replies: [
            BrainReply(
                model: "stub",
                message: BrainMessage(role: .assistant, content: "", toolCalls: [
                    BrainToolCall(id: "write-1", name: "write_note", arguments: [:])
                ]),
                stopReason: .toolUse
            ),
            BrainReply(model: "stub", message: .assistant("Saved."), stopReason: .endTurn),
        ])
        let first = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: firstBrain, mcp: tools), conversations: conversations,
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )

        _ = await first.handle([firstMessage, secondMessage])
        XCTAssertEqual(tools.callCount, 1)
        XCTAssertTrue(conversations.load().isEmpty)

        let replayBrain = AnsweringBackend(replies: [])
        let restarted = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: replayBrain, mcp: tools), conversations: conversations,
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        let replayedSecondOnly = ChannelMessage(
            kind: .whatsapp,
            recipient: ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net"),
            id: secondMessage.id,
            text: secondMessage.text,
            acknowledgementToken: secondMessage.acknowledgementToken,
            acknowledgementEpoch: secondMessage.acknowledgementEpoch
        )
        _ = await restarted.handle(replayedSecondOnly)

        XCTAssertEqual(tools.callCount, 1, "a partial spool replay repeated the completed mutation")
        XCTAssertEqual(replayBrain.recordedRequests.count, 0, "a partial replay returned to the model")
        let turns = try XCTUnwrap(conversations.load()[replayedSecondOnly.recipient.description])
        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns.last?.content, "Saved.")
    }

    func testCrashAfterSuccessfulSendBeforeAckStillDoesNotRepeatMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sent-before-ack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let pending = PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json"))
        let channel = FailableChannel(failures: 0)
        let tools = MutatingTools()
        let recipient = ChannelRecipient(kind: .whatsapp, address: "161228928336031@lid")
        let message = ChannelMessage(
            kind: .whatsapp, recipient: recipient, id: "sent-1", text: "save this",
            acknowledgementToken: 10, acknowledgementEpoch: "spool-a"
        )
        func brain() -> AnsweringBackend { AnsweringBackend(replies: [
            BrainReply(
                model: "stub",
                message: BrainMessage(role: .assistant, content: "", toolCalls: [
                    BrainToolCall(id: "write-1", name: "write_note", arguments: [:])
                ]),
                stopReason: .toolUse
            ),
            BrainReply(model: "stub", message: .assistant("Saved."), stopReason: .endTurn),
        ]) }
        let firstBrain = brain()
        let first = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: firstBrain, mcp: tools), conversations: conversations,
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        _ = await first.handle(message) // Simulates crash before run() can acknowledge.
        XCTAssertEqual(tools.callCount, 1)
        let announced = await first.announce("An interleaved update.", to: recipient)
        XCTAssertTrue(announced)

        let resolvedRecipient = ChannelRecipient(
            kind: .whatsapp,
            address: recipient.address,
            identity: "60123821767@s.whatsapp.net"
        )
        let replayMessage = ChannelMessage(
            kind: message.kind, recipient: resolvedRecipient, id: message.id, text: message.text,
            acknowledgementToken: message.acknowledgementToken,
            acknowledgementEpoch: message.acknowledgementEpoch
        )
        let newMessage = ChannelMessage(
            kind: .whatsapp, recipient: resolvedRecipient, id: "sent-new", text: "new work",
            acknowledgementToken: 11, acknowledgementEpoch: "spool-a"
        )
        let replayBrain = AnsweringBackend(["New answer."])
        let replayChannel = FailableChannel(failures: 0, incoming: [replayMessage, newMessage])
        let restarted = VoiceBridgeDaemon(
            channels: ChannelSet([replayChannel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: replayBrain, mcp: tools),
            configuration: .init(messageQuietWindow: .zero),
            conversations: conversations,
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        await restarted.run()

        XCTAssertEqual(tools.callCount, 1)
        XCTAssertEqual(replayBrain.recordedRequests.count, 1)
        XCTAssertEqual(
            conversations.load()[resolvedRecipient.description]?.map(\.content),
            ["save this", "Saved.", "An interleaved update.", "new work", "New answer."]
        )
    }

    func testPartialReplayCoalescedWithNewMessagePeelsCompletedTurnBeforeNewWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-partial-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let pending = PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json"))
        let tools = MutatingTools()
        let recipient = ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net")
        let firstMessage = ChannelMessage(
            kind: .whatsapp, recipient: recipient, id: "mixed-a", text: "save",
            acknowledgementToken: 30, acknowledgementEpoch: "spool-a"
        )
        let secondMessage = ChannelMessage(
            kind: .whatsapp, recipient: recipient, id: "mixed-b", text: "this",
            acknowledgementToken: 31, acknowledgementEpoch: "spool-a"
        )
        let firstBrain = AnsweringBackend(replies: [
            BrainReply(
                model: "stub",
                message: BrainMessage(role: .assistant, content: "", toolCalls: [
                    BrainToolCall(id: "write-1", name: "write_note", arguments: [:])
                ]), stopReason: .toolUse
            ),
            BrainReply(model: "stub", message: .assistant("Saved."), stopReason: .endTurn),
        ])
        let firstChannel = FailableChannel(failures: 1)
        let first = VoiceBridgeDaemon(
            channels: ChannelSet([firstChannel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: firstBrain, mcp: tools), conversations: conversations,
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        _ = await first.handle([firstMessage, secondMessage])

        let newMessage = ChannelMessage(
            kind: .whatsapp, recipient: recipient, id: "new-c", text: "new work",
            acknowledgementToken: 32, acknowledgementEpoch: "spool-a"
        )
        let replayBrain = AnsweringBackend(["New answer."])
        let replayChannel = FailableChannel(failures: 0, incoming: [secondMessage, newMessage])
        let restarted = VoiceBridgeDaemon(
            channels: ChannelSet([replayChannel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: replayBrain, mcp: tools),
            configuration: .init(messageQuietWindow: .zero),
            conversations: conversations,
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        await restarted.run()

        XCTAssertEqual(tools.callCount, 1, "mixed replay reran the old mutation")
        XCTAssertEqual(replayBrain.recordedRequests.count, 1, "new work was not handled exactly once")
        let turns = try XCTUnwrap(conversations.load()[recipient.description])
        XCTAssertEqual(turns.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(turns.map(\.content).suffix(3), ["Saved.", "new work", "New answer."])
    }

    func testJournalWriteFailureStillProtectsSameProcessReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unwritable-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A directory cannot be atomically replaced with the journal file.
        let invalidJournalTarget = directory.appendingPathComponent("pending-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidJournalTarget, withIntermediateDirectories: true)
        let channel = FailableChannel(failures: 1)
        let tools = MutatingTools()
        let brain = AnsweringBackend(replies: [
            BrainReply(
                model: "stub",
                message: BrainMessage(role: .assistant, content: "", toolCalls: [
                    BrainToolCall(id: "write-1", name: "write_note", arguments: [:])
                ]),
                stopReason: .toolUse
            ),
            BrainReply(model: "stub", message: .assistant("Saved."), stopReason: .endTurn),
        ])
        let daemon = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: brain, mcp: tools),
            pendingDeliveries: PendingDeliveryStore(fileURL: invalidJournalTarget),
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        let message = ChannelMessage(
            kind: .whatsapp,
            recipient: ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net"),
            id: "volatile-1", text: "save this", acknowledgementToken: 11,
            acknowledgementEpoch: "spool-a"
        )

        _ = await daemon.handle(message)
        _ = await daemon.handle(message)

        XCTAssertEqual(tools.callCount, 1, "a failed disk journal silently repeated the mutation")
        XCTAssertEqual(brain.recordedRequests.count, 2, "the volatile journal did not bypass the model")
    }

    func testFailedJournalRevisionDoesNotLeaveItsOlderDiskEntryAfterAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-revision-failure-\(UUID().uuidString)", isDirectory: true)
        let journalDirectory = directory.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: journalDirectory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let pending = PendingDeliveryStore(fileURL: journalDirectory.appendingPathComponent("pending.json"))
        let recipient = ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net")
        let message = ChannelMessage(
            kind: .whatsapp, recipient: recipient, id: "revision-failure", text: "save this",
            acknowledgementToken: 40, acknowledgementEpoch: "spool-a"
        )
        let channel = RevisionFailingChannel(message: message, journalDirectory: journalDirectory)
        let tools = MutatingTools()
        let brain = AnsweringBackend(replies: [
            BrainReply(
                model: "stub",
                message: BrainMessage(role: .assistant, content: "", toolCalls: [
                    BrainToolCall(id: "write-1", name: "write_note", arguments: [:])
                ]), stopReason: .toolUse
            ),
            BrainReply(model: "stub", message: .assistant("Saved."), stopReason: .endTurn),
        ])
        let daemon = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: brain, mcp: tools),
            configuration: .init(messageQuietWindow: .zero),
            conversations: ConversationStore(fileURL: directory.appendingPathComponent("conversations.json")),
            pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )

        await daemon.run()

        XCTAssertEqual(tools.callCount, 1)
        XCTAssertTrue(channel.didSabotageRevision)
        XCTAssertTrue(pending.allDeliveries().isEmpty, "the stale pre-revision journal survived ack cleanup")
    }

    func testTextWithoutItsAttachmentRemainsPendingAndReplayRetriesTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-attachment-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let pending = PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json"))
        let notes = NotesToolSource(directory: directory.appendingPathComponent("notes"), exporter: nil)
        let channel = PartialAttachmentChannel()
        let recipient = ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net")
        let message = ChannelMessage(
            kind: .whatsapp, recipient: recipient, id: "file-answer", text: "make the file",
            acknowledgementToken: 50, acknowledgementEpoch: "spool-a"
        )
        let firstBrain = AnsweringBackend(replies: [
            BrainReply(
                model: "stub",
                message: BrainMessage(role: .assistant, content: "", toolCalls: [
                    BrainToolCall(
                        id: "write-1", name: NotesToolSource.writeToolName,
                        arguments: ["title": .string("Result"), "content": .string("done")]
                    )
                ]), stopReason: .toolUse
            ),
            BrainReply(model: "stub", message: .assistant("Here it is."), stopReason: .endTurn),
        ])
        let first = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: firstBrain, mcp: notes), notes: notes,
            conversations: conversations, pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        _ = await first.handle(message)

        XCTAssertTrue(conversations.load().isEmpty, "text-only partial delivery was committed")
        XCTAssertEqual(pending.allDeliveries().count, 1)

        let replayBrain = AnsweringBackend(replies: [])
        let restarted = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: replayBrain, mcp: notes), notes: notes,
            conversations: conversations, pendingDeliveries: pending,
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        _ = await restarted.handle(message)

        XCTAssertEqual(replayBrain.recordedRequests.count, 0)
        XCTAssertEqual(channel.attachmentAttempts, 2, "replay did not retry the missing attachment")
        XCTAssertEqual(conversations.load()[recipient.description]?.map(\.content), ["make the file", "Here it is."])
    }

    func testTextlessMP4AndMOVAreRetiredWithoutBrainSendOrFiling() async throws {
        for kind in [ChannelKind.signal, .whatsapp] {
          for (name, mime) in [("copy.mp4", "video/mp4"), ("copy.mov", nil)] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("passive-video-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let video = directory.appendingPathComponent(name)
            try Data("video".utf8).write(to: video)
            let notesDirectory = directory.appendingPathComponent("notes", isDirectory: true)
            let channel = FailableChannel(kind: kind, failures: 0)
            let brain = AnsweringBackend(replies: [])
            let daemon = VoiceBridgeDaemon(
                channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
                loop: ToolLoop(backend: brain, mcp: NoTools()),
                notes: NotesToolSource(directory: notesDirectory, exporter: nil),
                pendingDeliveries: PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json")),
                pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
            )
            let outcome = await daemon.handle(ChannelMessage(
                kind: kind,
                recipient: ChannelRecipient(kind: kind, address: "60123821767@s.whatsapp.net"),
                id: name,
                attachments: [ChannelAttachment(
                    id: name, contentType: mime, filename: name, localURL: video
                )]
            ))

            XCTAssertEqual(outcome, .ignoredPassiveVideo)
            XCTAssertEqual(brain.recordedRequests.count, 0)
            XCTAssertEqual(channel.sendCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: notesDirectory.path))
          }
        }
    }

    func testCaptionedVideoStillRunsTheOrdinaryTurn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captioned-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("clip.mp4")
        try Data("video".utf8).write(to: video)
        let channel = FailableChannel(failures: 0)
        let brain = AnsweringBackend(["Okay."])
        let daemon = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: brain, mcp: NoTools()),
            notes: NotesToolSource(directory: directory.appendingPathComponent("notes"), exporter: nil),
            pendingDeliveries: PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json")),
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        _ = await daemon.handle(ChannelMessage(
            kind: .whatsapp,
            recipient: ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net"),
            id: "captioned",
            attachments: [ChannelAttachment(
                id: "clip", contentType: "video/mp4", filename: "clip.mp4",
                caption: "keep this clip", localURL: video
            )]
        ))

        XCTAssertEqual(brain.recordedRequests.count, 1)
        XCTAssertEqual(channel.sendCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes").path))
    }

    func testTextlessWebMUsesTheActionableVideoPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webm-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("clip.webm")
        try Data("video".utf8).write(to: video)
        let channel = FailableChannel(failures: 0)
        let brain = AnsweringBackend(["Okay."])
        let daemon = VoiceBridgeDaemon(
            channels: ChannelSet([channel]), transcriber: NoopAudioFileTranscriber(),
            loop: ToolLoop(backend: brain, mcp: NoTools()),
            notes: NotesToolSource(directory: directory.appendingPathComponent("notes"), exporter: nil),
            pendingDeliveries: PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json")),
            pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
        )
        let outcome = await daemon.handle(ChannelMessage(
            kind: .whatsapp,
            recipient: ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net"),
            id: "webm",
            attachments: [ChannelAttachment(
                id: "webm", contentType: "video/webm", filename: "clip.webm", localURL: video
            )]
        ))

        XCTAssertNotEqual(outcome, .ignoredPassiveVideo)
        XCTAssertEqual(brain.recordedRequests.count, 1)
        XCTAssertEqual(channel.sendCount, 1)
    }

    func testPassiveVideoRequiresAnUngroupedMP4OrMOVNotMerelyAnMP4Name() {
        XCTAssertFalse(ChannelAttachment(
            id: "document", contentType: "application/pdf", filename: "misnamed.mp4"
        ).isVideo, "a present non-video MIME type was ignored in favour of the extension")
        XCTAssertTrue(ChannelAttachment(
            id: "video", contentType: " VIDEO/MP4 ; codecs=h264", filename: "misnamed.pdf"
        ).isVideo, "an MP4 MIME type did not remain authoritative")
        XCTAssertTrue(ChannelAttachment(
            id: "extension", filename: "COPY.MOV"
        ).isVideo, "extension fallback stopped being case-insensitive")
        XCTAssertTrue(ChannelAttachment(
            id: "generic", contentType: "application/octet-stream", filename: "COPY.MP4"
        ).isVideo, "a generic MIME type blocked the filename fallback")

        let groupCopy = ChannelMessage(
            kind: .signal,
            recipient: ChannelRecipient(kind: .signal, address: "group-id", isGroup: true),
            id: "group-video",
            attachments: [ChannelAttachment(
                id: "clip", contentType: "video/mp4", filename: "clip.mp4"
            )]
        )
        XCTAssertFalse(
            groupCopy.isPassiveVideoCopy,
            "a textless video from a group was discarded as though it were a self-chat copy"
        )
    }
}

private extension DeliveredConversationHistoryTests {
    final class Fixture {
        let recipient = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )
        let backend: AnsweringBackend
        let channel: FailableChannel
        let store: ConversationStore
        let pending: PendingDeliveryStore
        let daemon: VoiceBridgeDaemon
        private let directory: URL

        init(answers: [String], failures: Int) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("delivered-history-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
            pending = PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json"))
            backend = AnsweringBackend(answers)
            channel = FailableChannel(failures: failures)
            daemon = VoiceBridgeDaemon(
                channels: ChannelSet([channel]),
                transcriber: NoopAudioFileTranscriber(),
                loop: ToolLoop(backend: backend, mcp: NoTools()),
                conversations: store,
                pendingDeliveries: pending,
                pause: PauseState(fileURL: directory.appendingPathComponent("paused"))
            )
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func message(_ text: String, id: String, sequence: Int) -> ChannelMessage {
            ChannelMessage(
                kind: .whatsapp,
                recipient: recipient,
                id: id,
                text: text,
                acknowledgementToken: sequence,
                acknowledgementEpoch: "test-spool"
            )
        }
    }

    final class FailableChannel: MessageChannel, @unchecked Sendable {
        let kind: ChannelKind
        nonisolated let incomingMessages: AsyncStream<ChannelMessage>
        private let lock = NSLock()
        private var failures: Int
        private var sends = 0

        init(kind: ChannelKind = .whatsapp, failures: Int, incoming: [ChannelMessage] = []) {
            self.kind = kind
            self.failures = failures
            incomingMessages = AsyncStream { continuation in
                for message in incoming { continuation.yield(message) }
                continuation.finish()
            }
        }
        var sendCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return sends
        }
        func start() async {}
        func stop() async {}
        var isConnected: Bool { get async { true } }
        func acknowledge(_ message: ChannelMessage) async {}

        struct Refused: Error {}
        func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
            lock.lock()
            defer { lock.unlock() }
            sends += 1
            if failures > 0 {
                failures -= 1
                throw Refused()
            }
        }
    }

    final class RevisionFailingChannel: MessageChannel, @unchecked Sendable {
        let kind = ChannelKind.whatsapp
        nonisolated let incomingMessages: AsyncStream<ChannelMessage>
        private let journalDirectory: URL
        private let lock = NSLock()
        private var sabotaged = false

        init(message: ChannelMessage, journalDirectory: URL) {
            self.journalDirectory = journalDirectory
            incomingMessages = AsyncStream { continuation in
                continuation.yield(message)
                continuation.finish()
            }
        }

        var didSabotageRevision: Bool {
            lock.lock()
            defer { lock.unlock() }
            return sabotaged
        }

        func start() async {}
        func stop() async {}
        var isConnected: Bool { get async { true } }

        func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: journalDirectory.path
            )
            lock.lock()
            sabotaged = true
            lock.unlock()
        }

        func acknowledge(_ message: ChannelMessage) async {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: journalDirectory.path
            )
        }
    }

    final class PartialAttachmentChannel: MessageChannel, @unchecked Sendable {
        let kind = ChannelKind.whatsapp
        nonisolated let incomingMessages = AsyncStream<ChannelMessage> { $0.finish() }
        private let lock = NSLock()
        private var attempts = 0

        var attachmentAttempts: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        func start() async {}
        func stop() async {}
        var isConnected: Bool { get async { true } }
        func acknowledge(_ message: ChannelMessage) async {}

        func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
            guard !reply.attachmentPaths.isEmpty else { return }
            lock.lock()
            attempts += 1
            let shouldFail = attempts == 1
            lock.unlock()
            if shouldFail {
                throw WhatsAppChannel.Failure.attachmentsFailedAfterText("scripted")
            }
        }
    }

    final class AnsweringBackend: BrainBackend, @unchecked Sendable {
        let identifier = "delivered-history-test"
        let modelName = "stub"
        let isLocal = false
        private let lock = NSLock()
        private var replies: [BrainReply]
        private var requests: [BrainRequest] = []

        init(_ answers: [String]) {
            replies = answers.map {
                BrainReply(model: "stub", message: .assistant($0), stopReason: .endTurn)
            }
        }
        init(replies: [BrainReply]) { self.replies = replies }
        var recordedRequests: [BrainRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
        func isAvailable() async -> Bool { true }
        func complete(_ request: BrainRequest) async throws -> BrainReply {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            guard !replies.isEmpty else {
                throw BrainBackendError.requestRejected("test script exhausted")
            }
            return replies.removeFirst()
        }
    }

    final class MutatingTools: ToolProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
        func listTools() async throws -> [MCPTool] {
            [MCPTool(name: "write_note", description: "writes", inputSchema: .object(["type": .string("object")]))]
        }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return "saved"
        }
    }

    struct NoTools: ToolProviding {
        func listTools() async throws -> [MCPTool] {
            [MCPTool(name: "sage_recall", description: "read", inputSchema: .object(["type": .string("object")]))]
        }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String { "" }
    }
}
