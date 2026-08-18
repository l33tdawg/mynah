import XCTest
@testable import SageVoiceCore

/// **The refusal was written, was correct, and never reached the owner.**
///
/// `WhisperAudioConversionError.converterMissing` names the file's format, names
/// ffmpeg, carries the install command for three distributions and the override
/// variable, and lists every directory that was searched. The cascade propagates
/// it. `VoiceBridgeDaemon.handle` caught it, wrote it to `bridge.log`, and told
/// the owner *"I couldn't read that voice note."*
///
/// On default Linux — no ffmpeg — that is every WhatsApp Ogg/Opus note and every
/// Signal m4a note, which is to say every spoken message, on the feature the
/// owner named as the must-have of this port. He can play the note back
/// perfectly, so the only sentence he got reads as a lie about his audio.
///
/// These tests are the specification for the reply he gets instead. The
/// end-to-end ones go through `handle` and read the text off the wire, because
/// the whole defect was a reason that existed everywhere except in the thread.
final class TheRefusalReachesTheOwnerTests: XCTestCase {

    // MARK: What the owner is sent

    /// The one the port turns on. Nothing here asserts prose beyond the pieces
    /// the owner has to act on: the program's name and the command that
    /// installs it.
    func testTheReplyNamesFfmpegAndTheCommandThatInstallsIt() {
        let reply = UnreadableVoiceNote.refusal(for: [Self.cascadeFailure(Self.converterMissing)])

        XCTAssertTrue(
            reply.contains("ffmpeg"),
            """
            the owner was not told which program is missing. He has whisper.cpp \
            installed and working and no way to learn that the gap is ffmpeg. \
            Sent: \(reply)
            """
        )
        XCTAssertTrue(
            reply.contains(WhisperAudioConverter.installInstruction),
            """
            the reply named ffmpeg but not how to install it, which is a dead \
            end with a label on it. Sent: \(reply)
            """
        )
        XCTAssertTrue(
            reply.contains("/usr/bin"),
            "the reply dropped the directories that were searched, so an owner "
                + "whose ffmpeg is installed somewhere unusual cannot tell why it was missed. "
                + "Sent: \(reply)"
        )
    }

    /// The familiar sentence still opens it. The owner should read the same
    /// first line every time a note fails; only what follows varies.
    func testTheReplyStillOpensWithThePlainRefusal() {
        let reply = UnreadableVoiceNote.refusal(for: [Self.cascadeFailure(Self.converterMissing)])
        XCTAssertTrue(reply.hasPrefix(UnreadableVoiceNote.generic), "sent: \(reply)")
    }

    /// **The other half of the contract, and the one that keeps the Mac still.**
    ///
    /// whisper.cpp exiting non-zero with a page of stderr is a debugging
    /// artefact. Pasting it into Signal would be a different way of failing to
    /// communicate, and on macOS — where the conversion path is compiled out
    /// entirely, so no `WhisperAudioConversionError` can exist — this is the
    /// only branch reachable at all. Byte-identical, deliberately.
    func testBrokenAudioStillGetsThePlainSentenceAndNothingElse() {
        let whisperFailed = WhisperCommandASRError.processFailed(
            exitCode: 1,
            stdout: "",
            stderr: "error: failed to open the file as WAV\nusage: whisper-cli [options]"
        )

        XCTAssertEqual(
            UnreadableVoiceNote.refusal(for: [Self.cascadeFailure(whisperFailed)]),
            UnreadableVoiceNote.generic,
            """
            a whisper.cpp exit code and its stderr were sent to the owner as if \
            they were an answer.
            """
        )
    }

    /// A failure carrying nothing to say leaves the sentence exactly as it was.
    func testAnUnrecognisedFailureLeavesTheSentenceUnchanged() {
        XCTAssertEqual(
            UnreadableVoiceNote.refusal(for: [NamelessFailure()]),
            UnreadableVoiceNote.generic
        )
        XCTAssertEqual(UnreadableVoiceNote.refusal(for: []), UnreadableVoiceNote.generic)
    }

    // MARK: Surviving the cascade

    /// **The pin under the string match, and the reason it is allowed to be
    /// one.**
    ///
    /// `LocalASRCascade` flattens each backend's error through
    /// `String(describing:)` before throwing `allBackendsFailed`, so the type is
    /// gone by the time the daemon has it. `UnreadableVoiceNote` recognises what
    /// is left by two markers; this builds all five cases of the enum and fails
    /// if any of them ever stops matching — which is what would happen if the
    /// prose were reworded without this test noticing.
    func testEveryConversionRefusalIsStillRecognisedAfterTheCascadeFlattensIt() {
        for error in Self.everyConversionError {
            let flattened = AudioTranscriberError.describe(error)
            XCTAssertTrue(
                UnreadableVoiceNote.namesTheConverter(flattened),
                """
                a named audio refusal stopped being recognised, so the owner is \
                back to the fixed sentence for it. Reworded case: \(flattened)
                """
            )
            XCTAssertEqual(
                UnreadableVoiceNote.refusal(for: [Self.cascadeFailure(error)]),
                UnreadableVoiceNote.generic + " " + error.description
            )
        }
    }

    /// The cascade tries several backends and keeps every reason. The named one
    /// is picked out of the middle of the list rather than only being seen when
    /// it happens to be first.
    func testTheNamedReasonIsFoundAmongOtherBackendsFailures() {
        let mixed = AudioTranscriberError.allBackendsFailed([
            "WhisperKitServerTranscriber: connection refused",
            AudioTranscriberError.describe(Self.converterMissing),
            "some other backend gave up",
        ])
        XCTAssertTrue(UnreadableVoiceNote.refusal(for: [mixed]).contains("ffmpeg"))
    }

    /// Thrown straight through, which is what happens when the transcriber is
    /// the whisper.cpp backend itself rather than the cascade in front of it.
    func testATypedConversionErrorIsSurfacedWithoutTheCascade() {
        XCTAssertEqual(
            UnreadableVoiceNote.refusal(for: [Self.converterMissing]),
            UnreadableVoiceNote.generic + " " + Self.converterMissing.description
        )
    }

    // MARK: End to end, which is where the defect actually was

    /// The owner sends a voice note. There is no ffmpeg. He is told so, in the
    /// thread, by the appliance — not by a log file he will never open.
    func testTheOwnerIsToldAboutFfmpegOnTheWire() async throws {
        let harness = try Harness(throwing: Self.cascadeFailure(Self.converterMissing))

        let outcome = await harness.daemon.handle(harness.voiceNote())

        let sent = await harness.sentText()
        XCTAssertEqual(sent.count, 1, "outcome: \(outcome)")
        let reply = try XCTUnwrap(sent.first)
        XCTAssertTrue(
            reply.contains("ffmpeg"),
            """
            the appliance replied to a voice note it could not read without \
            naming the missing program. This is the whole defect: the reason \
            reached the log and stopped there. Sent: \(reply)
            """
        )
        XCTAssertTrue(
            reply.contains("apt install ffmpeg"),
            "the install command did not survive the reply pipeline. Sent: \(reply)"
        )
    }

    /// And the Mac's only reachable branch, checked through the same wire: a
    /// backend that simply failed still produces the sentence it always did,
    /// with nothing appended.
    func testBrokenAudioReachesTheOwnerAsThePlainSentence() async throws {
        let harness = try Harness(throwing: Self.cascadeFailure(
            WhisperCommandASRError.processFailed(exitCode: 1, stdout: "", stderr: "boom")
        ))

        _ = await harness.daemon.handle(harness.voiceNote())

        // The appliance's own prefix is what marks the message as its rather
        // than the owner's, so the wire text carries it — see
        // `Configuration.replyPrefix`. Everything after it must be the sentence
        // that has always been sent, with nothing appended.
        let sent = await harness.sentText()
        XCTAssertEqual(
            sent,
            [VoiceBridgeDaemon.Configuration.defaultReplyPrefix + UnreadableVoiceNote.generic],
            "the sentence for unreadable audio changed for a failure that has nothing to add"
        )
    }

    // MARK: Fixtures

    /// A failure with nothing to say, standing in for every error type that is
    /// not one of the two `UnreadableVoiceNote.reason(in:)` knows about.
    private struct NamelessFailure: Error {}

    private static let converterMissing = WhisperAudioConversionError.converterMissing(
        input: "Ogg/Opus",
        searched: ["/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg", "/bin/ffmpeg"]
    )

    private static let everyConversionError: [WhisperAudioConversionError] = [
        converterMissing,
        .converterFailed(
            converter: "/usr/bin/ffmpeg",
            input: "Ogg/Opus",
            exitCode: 1,
            stderr: "Decoder (codec opus) not found for input stream #0:0"
        ),
        .converterTimedOut(converter: "/usr/bin/ffmpeg", seconds: 120),
        .converterProducedNoAudio(converter: "/usr/bin/ffmpeg", input: "MPEG-4 audio"),
        .converterProducedUnusableAudio(converter: "/usr/bin/ffmpeg", describedAs: "8000 Hz mono"),
    ]

    /// Exactly what the daemon receives: the cascade's own flattening, not a
    /// hand-written approximation of it.
    private static func cascadeFailure(_ error: Error) -> AudioTranscriberError {
        .allBackendsFailed([AudioTranscriberError.describe(error)])
    }

    private struct Harness {
        let daemon: VoiceBridgeDaemon
        let channel: RecordingChannel
        private let directory: URL
        private let audio: URL

        init(throwing error: Error) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("refusal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            audio = directory.appendingPathComponent("voice-note.ogg")
            try Data("not really an ogg".utf8).write(to: audio)

            channel = RecordingChannel()
            daemon = VoiceBridgeDaemon(
                channels: ChannelSet([channel]),
                transcriber: RefusingTranscriber(error: error),
                loop: ToolLoop(backend: SilentBackend(), mcp: NoToolsAtAll()),
                conversations: ConversationStore(
                    fileURL: directory.appendingPathComponent("conversations.json")
                ),
                pause: PauseState(fileURL: directory.appendingPathComponent("paused")),
                log: { _ in }
            )
        }

        func voiceNote() -> ChannelMessage {
            ChannelMessage(
                kind: .signal,
                recipient: ChannelRecipient(kind: .signal, address: "+60123821767"),
                id: "voice-1",
                attachments: [ChannelAttachment(
                    id: "attachment-1",
                    contentType: "audio/ogg; codecs=opus",
                    localURL: audio
                )]
            )
        }

        func sentText() async -> [String] { await channel.sent }
    }

    /// Records what actually crossed the transport. An actor rather than a lock
    /// because `send` is async and `NSLock` is an error to unlock from one.
    final class RecordingChannel: MessageChannel, @unchecked Sendable {
        let kind: ChannelKind = .signal
        nonisolated let incomingMessages: AsyncStream<ChannelMessage>
        private let recorder = Recorder()

        init() {
            incomingMessages = AsyncStream { $0.finish() }
        }

        var sent: [String] { get async { await recorder.texts } }
        func start() async {}
        func stop() async {}
        var isConnected: Bool { get async { true } }
        func acknowledge(_ message: ChannelMessage) async {}
        func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
            await recorder.record(reply.text)
        }

        private actor Recorder {
            var texts: [String] = []
            func record(_ text: String?) {
                if let text { texts.append(text) }
            }
        }
    }

    private struct RefusingTranscriber: AudioFileTranscribing {
        let error: any Error

        func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
            throw error
        }
    }

    /// Reaching this is a test failure by construction: the refusal is sent
    /// before any turn begins, so the model must never be asked anything.
    private struct SilentBackend: BrainBackend {
        let identifier = "refusal-test"
        let modelName = "stub"
        let isLocal = true
        func isAvailable() async -> Bool { true }
        func complete(_ request: BrainRequest) async throws -> BrainReply {
            XCTFail("the model was asked about a voice note that never transcribed")
            throw BrainBackendError.requestRejected("unreachable")
        }
    }

    private struct NoToolsAtAll: ToolProviding {
        func listTools() async throws -> [MCPTool] { [] }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String { "" }
    }
}
