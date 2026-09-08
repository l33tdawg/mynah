import XCTest
@testable import SageVoiceCore

final class GlassesMessageTests: XCTestCase {
    func testSpeechReturnsTextFramesWithoutSynthesis() async throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let live = CallConnection(descriptor: pair[0])
        defer { live.retire(); close(pair[0]); close(pair[1]) }
        let session = ScreenConversation(submitAudio: { _ in "Your appointment is at ten." })
        let reader = CallFrameReader(descriptor: pair[1])
        let sender = CallFrameWriter(descriptor: pair[1])
        let serverReader = CallFrameReader(descriptor: pair[0])
        let running = Task { await session.run(reader: serverReader, writer: CallFrameWriter(live)) }
        defer { try? sender.send(.endCall); running.cancel() }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try sender.send(.utterance(CallCeilingTests.aSecondOfSpeech()))
        var frames: [CallFrame] = []
        while true {
            let frame = try await withoutBlockingTheActor { try reader.next() }
            frames.append(frame)
            if frame == .replyEnd { break }
        }
        XCTAssertTrue(frames.contains(.replyText("Your appointment is at ten.")))
        XCTAssertFalse(frames.contains { if case .replyAudio = $0 { return true }; return false })
        try sender.send(.endCall)
        await running.value
    }

    func testSettingsPairingRoutesWithoutChatCommandAndRevocationBlocksImmediately() async throws {
        for kind in ChannelKind.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = GlassesPairingStore(url: directory.appendingPathComponent("pairing.json"))
            let fixture = try Fixture(kind: kind, pairings: store)
            let running = Task { await fixture.daemon.run() }
            defer { fixture.channel.finish(); running.cancel() }
            try store.save(.init(token: String(repeating: "a", count: 32), recipient: fixture.recipient))
            await fixture.daemon.refreshGlassesPairing()
            let answer = try await fixture.daemon.answerFromGlasses("from settings")
            XCTAssertEqual(answer, "Answer 1")
            try store.remove()
            // No refresh: a revoked token must be refused even before the watcher runs.
            let refused = try await fixture.daemon.answerFromGlasses("must not execute")
            XCTAssertTrue(refused.contains("Pair G2"))
            let count = await fixture.brain.requests.count
            XCTAssertEqual(count, 1)
            await fixture.daemon.refreshGlassesPairing()
            try store.save(.init(token: String(repeating: "b", count: 32), recipient: fixture.recipient))
            await fixture.daemon.refreshGlassesPairing()
            let reconnected = try await fixture.daemon.answerFromGlasses("paired again")
            XCTAssertEqual(reconnected, "Answer 2")
            try Data("invalid".utf8).write(to: store.url)
            let corrupt = try await fixture.daemon.answerFromGlasses("must not execute either")
            XCTAssertTrue(corrupt.contains("Pair G2"))
        }
    }

    func testGlassesUseTheExistingChatHistoryAndAnswerInBothPlaces() async throws {
        for kind in ChannelKind.allCases {
            let fixture = try Fixture(kind: kind)
            let running = Task { await fixture.daemon.run() }
            defer { fixture.channel.finish(); running.cancel() }
            fixture.channel.emit(fixture.message("first", "remember the tomato soup"))
            try await fixture.waitForAnswers(1)
            await fixture.daemon.registerGlassesConnection(from: fixture.recipient)
            let response = try await withDeadline(3, label: "glasses test") {
                try await fixture.daemon.answerFromGlasses("what were we discussing")
            }
            XCTAssertEqual(response, "Answer 2")
            let requests = await fixture.brain.requests
            XCTAssertTrue(requests[1].messages.contains { $0.content == "remember the tomato soup" })
            XCTAssertTrue(requests[1].messages.contains { $0.content == "Answer 1" })
            XCTAssertTrue(requests[1].messages.last?.content.hasSuffix("what were we discussing") == true)
            let sent = fixture.channel.sentTexts
            XCTAssertTrue(sent.contains { $0.contains("From G2: what were we discussing") })
            XCTAssertTrue(sent.contains { $0.contains("Answer 2") })
            fixture.channel.emit(fixture.message("third", "continue that"))
            try await fixture.waitForAnswers(3)
            let later = await fixture.brain.requests
            XCTAssertTrue(later[2].messages.contains { $0.content == "what were we discussing" })
            XCTAssertTrue(later[2].messages.contains { $0.content == "Answer 2" })
        }
    }

    func testLeavingTheGlassesDoesNotCancelASubmittedChatMessage() async throws {
        let fixture = try Fixture(kind: .signal, delay: .milliseconds(200))
        let running = Task { await fixture.daemon.run() }
        defer { fixture.channel.finish(); running.cancel() }
        await fixture.daemon.registerGlassesConnection(from: fixture.recipient)
        let caller = Task { try await fixture.daemon.answerFromGlasses("add the task") }
        try await withDeadline(3, label: "started") {
            while await fixture.brain.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        caller.cancel()
        _ = try? await caller.value
        try await fixture.waitForAnswers(1)
        let status = await fixture.daemon.glassesStatus()
        XCTAssertTrue(status.contains("Answer 1"))
        XCTAssertTrue(status.contains("ready"))
        let requests = await fixture.brain.requests
        XCTAssertEqual(requests.count, 1, "disconnect must not replay a task")
    }

    func testLeavingDuringTranscriptionStillDeliversTheVoiceNoteAnswer() async throws {
        let transcriber = SlowTranscriber()
        let fixture = try Fixture(kind: .signal, transcriber: transcriber)
        let running = Task { await fixture.daemon.run() }
        defer { fixture.channel.finish(); running.cancel() }
        await fixture.daemon.registerGlassesConnection(from: fixture.recipient)
        let caller = Task { try await fixture.daemon.answerFromGlasses(audio: CallCeilingTests.aSecondOfSpeech()) }
        try await withDeadline(3, label: "transcribing") {
            while await !transcriber.started { try await Task.sleep(for: .milliseconds(10)) }
        }
        caller.cancel(); _ = try? await caller.value
        try await fixture.waitForAnswers(1)
        let requests = await fixture.brain.requests
        XCTAssertTrue(requests[0].messages.last?.content.hasSuffix("the spoken question") == true)
        let recordedFile = await transcriber.file
        let file = try XCTUnwrap(recordedFile)
        // Delivery is observable before the daemon finishes cleanup.
        try await withDeadline(3, label: "recording cleanup") {
            while FileManager.default.fileExists(atPath: file.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let status = await fixture.daemon.glassesStatus()
        XCTAssertTrue(status.contains("Answer 1"))
    }

    func testARecordedQuestionCannotMergeWithTypingInTheSameThread() async {
        let recipient = ChannelRecipient(kind: .signal, address: "+15550001111")
        let chat = ChannelMessage(kind: .signal, recipient: recipient, id: "chat", text: "typed")
        let glasses = ChannelMessage(kind: .signal, recipient: recipient, id: "glasses", text: "spoken", isGlassesInput: true)
        let inbox = MessageInbox()
        let later = ChannelMessage(kind: .signal, recipient: recipient, id: "later", text: "typed later")
        await inbox.append(chat); await inbox.append(glasses); await inbox.append(later)
        let first = await inbox.takeBatch(quietWindow: .milliseconds(1))
        let second = await inbox.takeBatch(quietWindow: .milliseconds(1))
        XCTAssertEqual(first, [chat]); XCTAssertEqual(second, [glasses])
        let third = await inbox.takeBatch(quietWindow: .milliseconds(1))
        XCTAssertEqual(third, [later])
        XCTAssertFalse(MessageCoalescer.belongsTogether(batch: [glasses], next: chat))
    }

    func testQueuedAsksStaySeparateAndFollowUpUsesOnlySelectedThread() async throws {
        let fixture = try Fixture(kind: .signal, delay: .milliseconds(100), transcriber: SlowTranscriber())
        let running = Task { await fixture.daemon.run() }
        defer { fixture.channel.finish(); running.cancel() }
        await fixture.daemon.registerGlassesConnection(from: fixture.recipient)
        let first = "g2-" + UUID().uuidString, second = "g2-" + UUID().uuidString
        let wav = CallCeilingTests.aSecondOfSpeech()
        try await fixture.daemon.submitGlassesRequest(audio: wav, metadata: "{\"id\":\"\(first)\"}")
        try await fixture.daemon.submitGlassesRequest(audio: wav, metadata: "{\"id\":\"\(second)\"}")
        try await fixture.daemon.submitGlassesRequest(audio: wav, metadata: "{\"id\":\"\(first)\"}")
        try await fixture.waitForAnswers(2)
        let third = "g2-" + UUID().uuidString
        try await fixture.daemon.submitGlassesRequest(audio: wav, metadata: "{\"id\":\"\(third)\",\"parentId\":\"\(first)\"}")
        try await fixture.waitForAnswers(3)
        let requests = await fixture.brain.requests
        XCTAssertEqual(requests.count, 3, "duplicate IDs must never execute twice")
        XCTAssertFalse(requests[1].messages.contains { $0.content == "Answer 1" }, "new asks have separate context")
        XCTAssertTrue(requests[2].messages.contains { $0.content == "Answer 1" })
        XCTAssertFalse(requests[2].messages.contains { $0.content == "Answer 2" })
        let snapshot = await fixture.daemon.glassesStatus()
        XCTAssertTrue(snapshot.contains(first)); XCTAssertTrue(snapshot.contains(second)); XCTAssertTrue(snapshot.contains(third))
    }

    func testGlassesCommandIsExplicitAndAnchored() {
        XCTAssertTrue(CallInvitation.isGlassesRequest(" //G2\n"))
        XCTAssertFalse(CallInvitation.isGlassesRequest("how do I use //g2"))
        XCTAssertFalse(CallInvitation.isGlassesRequest("//g2oops"))
    }
}

private extension GlassesMessageTests {
    final class Fixture: @unchecked Sendable {
        let channel: Channel
        let brain: Brain
        let daemon: VoiceBridgeDaemon
        let recipient: ChannelRecipient
        let directory: URL
        init(kind: ChannelKind, delay: Duration = .zero, transcriber: any AudioFileTranscribing = NoopAudioFileTranscriber(), pairings: GlassesPairingStore? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("g2-test-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            recipient = ChannelRecipient(kind: kind, address: "+15550001111")
            channel = Channel(kind: kind); brain = Brain(delay: delay)
            daemon = VoiceBridgeDaemon(
                channels: ChannelSet([channel]), transcriber: transcriber,
                loop: ToolLoop(backend: brain, mcp: Tools()),
                configuration: .init(messageQuietWindow: .milliseconds(1)),
                conversations: ConversationStore(fileURL: directory.appendingPathComponent("history.json")),
                promises: PromisedAnswerStore(fileURL: directory.appendingPathComponent("promises.json")),
                pendingDeliveries: PendingDeliveryStore(fileURL: directory.appendingPathComponent("pending.json")),
                glassesPairings: pairings, pause: PauseState(fileURL: directory.appendingPathComponent("paused")), log: { _ in }
            )
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func message(_ id: String, _ text: String) -> ChannelMessage {
            .init(kind: recipient.kind, recipient: recipient, id: id, text: text)
        }
        func waitForAnswers(_ count: Int) async throws {
            try await withDeadline(3, label: "chat delivery") {
                while self.channel.sentTexts.filter({ $0.contains("Answer ") }).count < count {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }
    actor Brain: BrainBackend {
        nonisolated let identifier = "g2-test"
        nonisolated let modelName = "stub"
        nonisolated let isLocal = false
        var requests: [BrainRequest] = []
        let delay: Duration
        init(delay: Duration) { self.delay = delay }
        func isAvailable() async -> Bool { true }
        func complete(_ request: BrainRequest) async throws -> BrainReply {
            requests.append(request)
            let number = requests.count
            try await Task.sleep(for: delay)
            return BrainReply(model: "stub", message: .assistant("Answer \(number)"), stopReason: .endTurn)
        }
    }
    actor SlowTranscriber: AudioFileTranscribing {
        var started = false
        var file: URL?
        func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
            started = true; file = audioFile
            try await Task.sleep(for: .milliseconds(200))
            _ = try Data(contentsOf: audioFile)
            return "the spoken question"
        }
    }
    struct Tools: ToolProviding {
        func listTools() async throws -> [MCPTool] {
            [.init(name: "sage_recall", description: "memory", inputSchema: .object(["type": .string("object")]))]
        }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String { "" }
    }
    final class Channel: MessageChannel, @unchecked Sendable {
        let kind: ChannelKind
        let incomingMessages: AsyncStream<ChannelMessage>
        let feed: AsyncStream<ChannelMessage>.Continuation
        private let lock = NSLock()
        private var sent: [String] = []
        init(kind: ChannelKind) {
            self.kind = kind
            (incomingMessages, feed) = AsyncStream.makeStream()
        }
        var sentTexts: [String] { lock.lock(); defer { lock.unlock() }; return sent }
        func emit(_ message: ChannelMessage) { feed.yield(message) }
        func finish() { feed.finish() }
        func start() async {}
        func stop() async { finish() }
        var isConnected: Bool { get async { true } }
        func acknowledge(_ message: ChannelMessage) async {}
        func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
            lock.withLock { if let text = reply.text { sent.append(text) } }
        }
    }
}
