import XCTest
@testable import SageVoiceCore

/// **Voice-notes-to-text was broken on Linux by a single forwarding call.**
///
/// `WhisperCommandASRBackend.transcribe(audioFile:)` passed the file straight to
/// `transcribe(wavFile:)`, and the parameter name was the whole of the contract
/// that was being violated: whisper.cpp reads 16 kHz 16-bit PCM WAV and nothing
/// else, while a WhatsApp voice note is Ogg/Opus and a Signal one is MPEG-4
/// audio. On a machine with whisper.cpp and a model both installed perfectly,
/// every voice note reached a program that could not open it.
///
/// The Mac never showed it because the Mac never gets that far: the first rung
/// of its cascade is the WhisperKit helper, which decodes the container itself
/// through Apple's audio stack. **Nothing in this repository has ever converted
/// audio for whisper.cpp** — there is no `afconvert` call and no `AVAudioFile`
/// anywhere near this path — so off Darwin, where that first rung does not
/// exist, there was nothing between the messenger's file and a program that
/// only reads WAV.
///
/// These tests are the specification for the fix, and the thing most of them
/// are really guarding is the *shape of the failure*. A missing converter has
/// to refuse by name with an install command. It must never come back as an
/// empty transcript, which is the silent-success failure this project treats as
/// its worst defect class.
final class AVoiceNoteIsNotAWavTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicenote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - What whisper.cpp can and cannot read

    /// The WhatsApp case, which is the common one.
    func testAWhatsAppOggIsNotSomethingWhisperCanRead() throws {
        let note = try write(name: "note.ogg", bytes: oggOpusHeader())

        guard case let .needsConversion(described) = WhisperAudioProbe.inspect(fileAt: note) else {
            return XCTFail("an Ogg/Opus voice note was declared ready for whisper.cpp")
        }
        XCTAssertTrue(
            described.contains("Ogg"),
            "the refusal has to name what the file actually is, got: \(described)"
        )
    }

    /// The Signal case.
    func testASignalM4AIsNotSomethingWhisperCanRead() throws {
        let note = try write(name: "note.m4a", bytes: mpeg4Header())

        guard case let .needsConversion(described) = WhisperAudioProbe.inspect(fileAt: note) else {
            return XCTFail("an m4a voice note was declared ready for whisper.cpp")
        }
        XCTAssertTrue(
            described.contains("MPEG-4"),
            "the refusal has to name what the file actually is, got: \(described)"
        )
    }

    /// And the file that genuinely needs nothing doing to it goes through
    /// untouched — otherwise every machine would need ffmpeg to transcribe a
    /// recording Mynah made itself.
    func testA16kHzMonoWavIsHandedOverUntouched() throws {
        let note = try write(name: "recorded.wav", bytes: wav(sampleRate: 16_000, channels: 1))
        XCTAssertEqual(WhisperAudioProbe.inspect(fileAt: note), .whisperReady)
    }

    /// **A `.wav` is not automatically a WAV whisper.cpp will accept.** It
    /// refuses anything that is not 16 kHz just as firmly as it refuses Ogg, so
    /// deciding from the file extension would have left this one broken.
    func testA44kHzStereoWavIsRefusedByWhisperAndSoIsConverted() throws {
        let note = try write(name: "note.wav", bytes: wav(sampleRate: 44_100, channels: 2))

        guard case let .needsConversion(described) = WhisperAudioProbe.inspect(fileAt: note) else {
            return XCTFail("a 44.1 kHz stereo WAV was declared ready for whisper.cpp")
        }
        XCTAssertTrue(described.contains("44100"), "got: \(described)")
        XCTAssertTrue(described.contains("16000"), "the sentence must say what is wanted: \(described)")
    }

    /// The chunk walk, which is what keeps a perfectly good recording from being
    /// converted for no reason. Plenty of writers put a `JUNK` chunk in front of
    /// `fmt `, and reading a fixed offset would call that file compressed.
    func testAWavWithAJunkChunkBeforeTheFormatChunkIsStillRecognised() throws {
        var bytes = wav(sampleRate: 16_000, channels: 1)
        let junk: [UInt8] = Array("JUNK".utf8) + [4, 0, 0, 0] + [0, 0, 0, 0]
        bytes.insert(contentsOf: junk, at: 12)
        // The RIFF size field is now wrong, which no reader of ours cares about.
        let note = try write(name: "junked.wav", bytes: bytes)

        XCTAssertEqual(WhisperAudioProbe.inspect(fileAt: note), .whisperReady)
    }

    // MARK: - The refusal, when there is no converter

    /// **The heart of it.** No ffmpeg, an Ogg voice note, and the answer has to
    /// be a sentence naming the program and the command to install it — not an
    /// empty string, and not whisper.cpp's own confusion about a file it cannot
    /// open.
    func testAMissingConverterRefusesByNameRatherThanReturningNothing() async throws {
        let note = try write(name: "note.ogg", bytes: oggOpusHeader())

        do {
            let prepared = try await PreparedWhisperAudio.prepare(
                audioFile: note,
                converter: nil,
                searchedConverterPaths: ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            )
            XCTFail("an unconvertible voice note was accepted as \(prepared.url.path)")
        } catch let error as WhisperAudioConversionError {
            guard case .converterMissing = error else {
                return XCTFail("expected converterMissing, got \(error)")
            }
            let sentence = error.description
            XCTAssertTrue(sentence.contains("ffmpeg"), "the refusal must name the program: \(sentence)")
            XCTAssertTrue(
                sentence.contains("apt install ffmpeg"),
                "the refusal must carry the next action: \(sentence)"
            )
            XCTAssertTrue(
                sentence.contains("SAGE_VOICE_FFMPEG"),
                "the refusal must offer the override for a program installed elsewhere: \(sentence)"
            )
            XCTAssertTrue(
                sentence.contains("/usr/bin/ffmpeg"),
                "the refusal must say where it looked: \(sentence)"
            )
            XCTAssertTrue(
                sentence.contains("Ogg"),
                "the refusal must say what the note was: \(sentence)"
            )
        }
    }

    /// A note that does not exist is a *missing file*, and blaming ffmpeg for it
    /// would send the owner to install something that would not have helped.
    func testAMissingFileIsNotBlamedOnTheConverter() async throws {
        let absent = root.appendingPathComponent("never-downloaded.ogg")

        let prepared = try await PreparedWhisperAudio.prepare(
            audioFile: absent,
            converter: nil,
            searchedConverterPaths: []
        )
        XCTAssertEqual(prepared.url, absent, "the missing file must reach whisper.cpp's own check")
        XCTAssertFalse(prepared.wasConverted)
    }

    // MARK: - The conversion itself

    /// A non-WAV note becomes the WAV whisper.cpp wants, and the scratch copy is
    /// cleaned up afterwards.
    func testANonWavNoteIsConvertedIntoSomethingWhisperCanRead() async throws {
        let note = try write(name: "note.ogg", bytes: oggOpusHeader())
        let good = try write(name: "converted-fixture.wav", bytes: wav(sampleRate: 16_000, channels: 1))
        let converter = try fakeConverter(copying: good)

        let prepared = try await PreparedWhisperAudio.prepare(
            audioFile: note,
            converter: converter,
            searchedConverterPaths: []
        )

        XCTAssertTrue(prepared.wasConverted)
        XCTAssertNotEqual(prepared.url, note)
        XCTAssertEqual(prepared.url.pathExtension, "wav")
        XCTAssertEqual(
            WhisperAudioProbe.inspect(fileAt: prepared.url),
            .whisperReady,
            "the converted file is still not something whisper.cpp can read"
        )

        prepared.discard()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: prepared.url.path),
            "a scratch copy per voice note, never deleted, fills the disk of a long-lived daemon"
        )
    }

    /// ffmpeg's own command line, checked because it is the whole of the
    /// contract with whisper.cpp: mono, 16 kHz, signed 16-bit PCM.
    func testTheConverterIsAskedFor16kHzMonoPCM() {
        let arguments = WhisperAudioConverter.arguments(
            input: URL(fileURLWithPath: "/tmp/in.ogg"),
            output: URL(fileURLWithPath: "/tmp/out.wav")
        )
        XCTAssertEqual(argument(after: "-ar", in: arguments), "16000")
        XCTAssertEqual(argument(after: "-ac", in: arguments), "1")
        XCTAssertEqual(argument(after: "-acodec", in: arguments), "pcm_s16le")
        XCTAssertEqual(argument(after: "-i", in: arguments), "/tmp/in.ogg")
        XCTAssertEqual(arguments.last, "/tmp/out.wav")
        XCTAssertTrue(
            arguments.contains("-nostdin"),
            "an ffmpeg that stops to read stdin would hang the daemon on a voice note"
        )
    }

    /// **Exit zero is not proof of audio.** ffmpeg writes a bare 44-byte header
    /// and exits 0 when the input has no audio track, and that WAV transcribes
    /// to the empty string. That is the silent failure, dressed as a success.
    func testAConverterThatWritesAnEmptyWavIsAFailureNotAnEmptyTranscript() async throws {
        let note = try write(name: "note.ogg", bytes: oggOpusHeader())
        let headerOnly = try write(name: "silent.wav", bytes: wav(sampleRate: 16_000, channels: 1, frames: 0))
        let converter = try fakeConverter(copying: headerOnly)

        do {
            _ = try await PreparedWhisperAudio.prepare(
                audioFile: note,
                converter: converter,
                searchedConverterPaths: []
            )
            XCTFail("a conversion that produced no audio was accepted")
        } catch let error as WhisperAudioConversionError {
            guard case .converterProducedNoAudio = error else {
                return XCTFail("expected converterProducedNoAudio, got \(error)")
            }
            XCTAssertTrue(error.description.contains("ask for the note again"), error.description)
        }
    }

    /// And a converter that writes the wrong shape is caught here rather than
    /// three seconds later as whisper.cpp's "WAV file must be 16 kHz".
    func testAConverterThatWritesTheWrongFormatIsAFailure() async throws {
        let note = try write(name: "note.ogg", bytes: oggOpusHeader())
        let wrong = try write(name: "wrong.wav", bytes: wav(sampleRate: 44_100, channels: 2))
        let converter = try fakeConverter(copying: wrong)

        do {
            _ = try await PreparedWhisperAudio.prepare(
                audioFile: note,
                converter: converter,
                searchedConverterPaths: []
            )
            XCTFail("a conversion to a format whisper.cpp cannot read was accepted")
        } catch let error as WhisperAudioConversionError {
            guard case .converterProducedUnusableAudio = error else {
                return XCTFail("expected converterProducedUnusableAudio, got \(error)")
            }
        }
    }

    /// A converter that fails says why, in its own words, and leaves nothing
    /// behind.
    func testAConverterThatFailsIsReportedWithItsOwnMessage() async throws {
        let note = try write(name: "note.ogg", bytes: oggOpusHeader())
        let before = try scratchDirectories()
        let converter = try fakeConverter(script: """
            #!/bin/sh
            echo "Invalid data found when processing input" >&2
            exit 1
            """)

        do {
            _ = try await PreparedWhisperAudio.prepare(
                audioFile: note,
                converter: converter,
                searchedConverterPaths: []
            )
            XCTFail("a failed conversion was accepted")
        } catch let error as WhisperAudioConversionError {
            guard case .converterFailed = error else {
                return XCTFail("expected converterFailed, got \(error)")
            }
            XCTAssertTrue(
                error.description.contains("Invalid data found"),
                "ffmpeg's own diagnosis is the useful half: \(error.description)"
            )
        }

        XCTAssertEqual(
            try scratchDirectories().subtracting(before),
            [],
            "a failed conversion left its scratch directory behind, and a daemon does this per note"
        )
    }

    // MARK: - Finding ffmpeg

    func testTheOverrideIsHonouredAndComesFirst() throws {
        let program = try fakeConverter(script: "#!/bin/sh\nexit 0\n").executableURL

        let found = WhisperAudioConverter.discover(
            environment: ["SAGE_VOICE_FFMPEG": program.path, "PATH": "/usr/bin"],
            homeDirectory: root
        )
        XCTAssertEqual(found?.executableURL.path, program.path)
    }

    /// Pointed at the directory rather than the program, which is what half the
    /// people who set it will do.
    func testTheOverrideAlsoAcceptsTheDirectoryHoldingFfmpeg() throws {
        let directory = root.appendingPathComponent("ffmpeg-build", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeExecutable(at: directory.appendingPathComponent("ffmpeg"), script: "#!/bin/sh\nexit 0\n")

        let found = WhisperAudioConverter.discover(
            environment: ["SAGE_VOICE_FFMPEG": directory.path, "PATH": ""],
            homeDirectory: root
        )
        XCTAssertEqual(found?.executableURL.lastPathComponent, "ffmpeg")
    }

    func testFfmpegIsFoundOnThePath() throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try makeExecutable(at: bin.appendingPathComponent("ffmpeg"), script: "#!/bin/sh\nexit 0\n")

        let found = WhisperAudioConverter.discover(
            environment: ["PATH": "/nowhere:\(bin.path)"],
            homeDirectory: root
        )
        XCTAssertEqual(found?.executableURL.path, bin.appendingPathComponent("ffmpeg").path)
    }

    /// The list the refusal quotes has to be the list the search walked.
    func testTheSearchedPathsAreTheOnesActuallyWalked() {
        let searched = WhisperAudioConverter.searchedPaths(
            environment: ["PATH": "/opt/bin"],
            homeDirectory: URL(fileURLWithPath: "/home/owner")
        )
        XCTAssertTrue(searched.contains("/opt/bin/ffmpeg"))
        XCTAssertTrue(searched.contains("/usr/bin/ffmpeg"))
        XCTAssertTrue(searched.contains("/home/owner/.local/bin/ffmpeg"))
        XCTAssertEqual(searched.count, Set(searched).count, "the same path listed twice reads as a bug")
    }

    // MARK: - The wiring, per platform

    /// **The regression guard in both directions.**
    ///
    /// Off Darwin the Ogg must reach whisper.cpp as a converted WAV. On a Mac
    /// the file must reach it exactly as it did in 2.3.0 — untouched, with
    /// ffmpeg never invoked — because the Mac's cascade decodes containers in
    /// its WhisperKit rung and changing the fallback would be changing shipping
    /// behaviour to fix somebody else's platform.
    func testTheNoteReachesWhisperConvertedOffDarwinAndUntouchedOnAMac() async throws {
        let note = try write(name: "note.ogg", bytes: oggOpusHeader())
        let good = try write(name: "converted-fixture.wav", bytes: wav(sampleRate: 16_000, channels: 1))
        let converterCalls = root.appendingPathComponent("ffmpeg-was-called")
        let converter = try fakeConverter(copying: good, recordingTo: converterCalls)
        setenv("SAGE_VOICE_FFMPEG", converter.executableURL.path, 1)
        defer { unsetenv("SAGE_VOICE_FFMPEG") }

        let whisperArguments = root.appendingPathComponent("whisper-arguments")
        let backend = try fakeWhisper(
            recordingArgumentsTo: whisperArguments,
            printing: "[00:00:00.000 --> 00:00:02.000]   Buy milk on the way home."
        )

        let heard = try await backend.transcribe(audioFile: note, options: .none)
        XCTAssertEqual(heard, "Buy milk on the way home.")

        let given = try String(contentsOf: whisperArguments, encoding: .utf8)
            .components(separatedBy: .newlines)
        let file = argument(after: "-f", in: given)

        #if os(macOS)
        XCTAssertEqual(
            file,
            note.path,
            "the Mac's fallback was handed a different file than it was in 2.3.0"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: converterCalls.path),
            "ffmpeg ran on a Mac, which is a change to shipping behaviour"
        )
        #else
        XCTAssertNotEqual(file, note.path, "whisper.cpp was handed the Ogg it cannot read")
        XCTAssertEqual(URL(fileURLWithPath: file ?? "").pathExtension, "wav")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: converterCalls.path),
            "nothing converted the voice note"
        )
        #endif
    }

    /// And where there is no converter at all, the refusal reaches the caller
    /// rather than an empty transcript reaching the owner.
    ///
    /// Mac-excluded because the Mac deliberately does not convert: there the
    /// same Ogg goes to whisper.cpp untouched, which is what 2.3.0 does.
    #if !os(macOS)
    func testWithoutFfmpegTheCascadeReportsTheRefusalInsteadOfSayingNothing() async throws {
        // The fixed candidate list is absolute and cannot be injected through
        // the daemon's own call path, so on a machine that really has ffmpeg
        // this can only be skipped — saying so out loud rather than passing
        // vacuously.
        let installed = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/snap/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(
            installed != nil,
            "this machine has ffmpeg at \(installed ?? "") — the no-converter path cannot be observed here"
        )

        let note = try write(name: "note.ogg", bytes: oggOpusHeader())
        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("SAGE_VOICE_FFMPEG", root.appendingPathComponent("no-ffmpeg-here").path, 1)
        setenv("PATH", root.appendingPathComponent("empty").path, 1)
        defer {
            unsetenv("SAGE_VOICE_FFMPEG")
            // Restored rather than unset: the fake converters later in this
            // suite are shell scripts that call `cp`, and a process with no
            // PATH cannot find it.
            setenv("PATH", previousPath ?? "/usr/bin:/bin", 1)
        }

        let backend = try fakeWhisper(
            recordingArgumentsTo: root.appendingPathComponent("unused"),
            printing: "this must never be reached"
        )

        do {
            let heard = try await backend.transcribe(audioFile: note, options: .none)
            XCTFail("a voice note nothing could read came back as \"\(heard)\"")
        } catch let error as WhisperAudioConversionError {
            guard case .converterMissing = error else {
                return XCTFail("expected converterMissing, got \(error)")
            }
        }
    }
    #endif

    // MARK: - Selecting the backend

    /// Off Darwin the whisper.cpp rung is the only rung, so if discovery does
    /// not select it there is no speech at all. Run on the Mac too, where it
    /// proves the same search still resolves a development checkout.
    func testDiscoveryFindsAndSelectsAnOwnerInstalledWhisper() throws {
        try stageWhisperInstallation()
        let discovery = LocalASRDiscovery(rootDirectory: root, homeDirectory: root)

        XCTAssertTrue(
            discovery.availability().isReady,
            "a whisper.cpp and a model both present were reported as missing: "
                + discovery.availability().explanation
        )
        XCTAssertNotNil(discovery.commandBackend(), "the command backend was not selected")
    }

    /// The whole cascade, from discovery to a transcript, through
    /// `LocalASRRuntime.prepare` — which is the code path the daemon runs.
    ///
    /// Skipped, out loud, on a machine that already has whisper.cpp installed
    /// at one of the absolute paths the search prefers: it would run the
    /// owner's real program against this test's one-byte model, which measures
    /// nothing. It runs for real in the Linux container, which is the platform
    /// this rung is the *only* rung on.
    func testPreparingTheRuntimeSelectsTheCommandBackendAndItTranscribes() async throws {
        try XCTSkipIf(
            installedWhisper() != nil,
            "this machine has whisper.cpp at \(installedWhisper() ?? "") and the search prefers it"
        )
        try stageWhisperInstallation(
            printing: "[00:00:00.000 --> 00:00:01.000]   It works."
        )
        let wavNote = try write(name: "note.wav", bytes: wav(sampleRate: 16_000, channels: 1))

        let cascade = try await LocalASRRuntime().prepare(
            discovery: LocalASRDiscovery(rootDirectory: root, homeDirectory: root)
        )
        let heard = try await cascade.transcribe(audioFile: wavNote, options: .none)
        XCTAssertEqual(heard, "It works.")
    }

    /// **macOS ordering is untouched.** WhisperKit is appended first and only on
    /// a Mac; the whisper.cpp rung follows it. Read from the source because the
    /// bundled helper cannot exist in a test process, and an ordering that only
    /// holds when both rungs are constructible is not an ordering anybody can
    /// check at runtime here.
    func testWhisperKitStaysTheFirstRungOnAMac() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/SageVoiceCore/LocalASRDiscovery.swift"),
            encoding: .utf8
        )
        guard let body = source.range(of: "public func prepare(") else {
            return XCTFail("LocalASRRuntime.prepare has been renamed")
        }
        let text = String(source[body.lowerBound...])
        guard let whisperKit = text.range(of: "ManagedWhisperKitTranscriber(") else {
            return XCTFail("the WhisperKit rung is gone from prepare()")
        }
        guard let command = text.range(of: "discovery.commandBackend(") else {
            return XCTFail("the whisper.cpp rung is gone from prepare()")
        }
        XCTAssertTrue(
            whisperKit.lowerBound < command.lowerBound,
            "whisper.cpp was put in front of WhisperKit, which changes what every Mac transcribes with"
        )
        // Written order is only the order the cascade runs in while every rung
        // is appended. `insert(at:)` would reverse it while leaving the source
        // reading exactly as it does now.
        XCTAssertFalse(
            text.prefix(4000).contains("backends.insert("),
            "a rung is being inserted rather than appended, so written order no longer means run order"
        )
        guard let guardStart = text.range(of: "#if os(macOS)"),
              let guardEnd = text.range(of: "#endif", range: guardStart.upperBound..<text.endIndex) else {
            return XCTFail("the WhisperKit rung is no longer inside a platform guard")
        }
        XCTAssertTrue(
            guardStart.upperBound < whisperKit.lowerBound && whisperKit.upperBound < guardEnd.lowerBound,
            "the WhisperKit rung escaped its #if os(macOS), so Linux would report a missing Apple helper"
        )
    }

    /// The conversion is compiled in off Darwin only. Asserted on the source
    /// because a Mac cannot observe the absence of a branch it never runs.
    func testTheConversionIsGuardedSoTheMacPathIsUnchanged() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/SageVoiceCore/LocalASRDiscovery.swift"),
            encoding: .utf8
        )
        guard let conformance = source.range(of: "extension WhisperCommandASRBackend: AudioFileTranscribing {") else {
            return XCTFail("the AudioFileTranscribing conformance has moved")
        }
        let body = String(source[conformance.lowerBound...])
        guard let convert = body.range(of: "PreparedWhisperAudio.prepare(") else {
            return XCTFail("nothing converts the voice note any more")
        }
        guard let macBranch = body.range(of: "#if os(macOS)"),
              let elseBranch = body.range(of: "#else", range: macBranch.upperBound..<body.endIndex),
              let endBranch = body.range(of: "#endif", range: elseBranch.upperBound..<body.endIndex) else {
            return XCTFail("the conversion is not behind a platform guard")
        }
        XCTAssertTrue(
            elseBranch.upperBound < convert.lowerBound && convert.upperBound < endBranch.lowerBound,
            "the conversion is on the Mac's side of the guard, which changes shipping macOS behaviour"
        )
    }

    // MARK: - Fixtures

    private func write(name: String, bytes: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// A real RIFF/WAVE header with `frames` samples of silence behind it.
    private func wav(sampleRate: Int, channels: Int, frames: Int = 1600) -> [UInt8] {
        [UInt8](WAVAudio.encode(
            pcm: [Int16](repeating: 0, count: frames * channels),
            sampleRate: sampleRate,
            channelCount: channels
        ))
    }

    /// The first page of an Ogg stream carrying Opus, which is byte-for-byte
    /// how a WhatsApp voice note starts.
    private func oggOpusHeader() -> [UInt8] {
        var bytes = Array("OggS".utf8)
        bytes += [0, 2]                                     // version, header type
        bytes += [UInt8](repeating: 0, count: 20)           // granule, serial, sequence, CRC
        bytes += [1, 19]                                    // one segment, 19 bytes
        bytes += Array("OpusHead".utf8)
        bytes += [1, 1, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]
        return bytes
    }

    /// An MPEG-4 container, which is how Signal's voice notes start.
    private func mpeg4Header() -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, 0x20]
        bytes += Array("ftypM4A ".utf8)
        bytes += [0, 0, 0, 0]
        bytes += Array("M4A mp42isom".utf8)
        return bytes
    }

    private func makeExecutable(at url: URL, script: String) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// An ffmpeg that copies a prepared fixture to whatever output path it was
    /// given. A real ffmpeg is not available on every build machine, and the
    /// thing under test is the plumbing around it rather than its resampler.
    private func fakeConverter(copying fixture: URL, recordingTo calls: URL? = nil) throws -> WhisperAudioConverter {
        let record = calls.map { "printf '%s\\n' \"$@\" > \"\($0.path)\"\n" } ?? ""
        return try fakeConverter(script: """
            #!/bin/sh
            \(record)for last in "$@"; do :; done
            cp "\(fixture.path)" "$last"
            """)
    }

    private func fakeConverter(script: String) throws -> WhisperAudioConverter {
        let url = root.appendingPathComponent("ffmpeg-\(UUID().uuidString)")
        try makeExecutable(at: url, script: script)
        return WhisperAudioConverter(executableURL: url, timeoutSeconds: 30)
    }

    /// A whisper.cpp that writes down which file it was given and prints a
    /// transcript. Which file it was given is the entire question this fix is
    /// about.
    private func fakeWhisper(recordingArgumentsTo arguments: URL, printing transcript: String) throws -> WhisperCommandASRBackend {
        let program = root.appendingPathComponent("whisper-cli-\(UUID().uuidString)")
        try makeExecutable(at: program, script: """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(arguments.path)"
            echo "\(transcript)"
            """)
        let model = root.appendingPathComponent("ggml-fake.bin")
        try Data([0]).write(to: model)
        return WhisperCommandASRBackend(executablePath: program.path, modelPath: model.path)
    }

    /// A whisper.cpp installation in the shape `LocalASRDiscovery` searches for
    /// on every platform: the program under `build/bin`, the model under
    /// `models/`.
    @discardableResult
    private func stageWhisperInstallation(
        printing transcript: String = "[00:00:00.000 --> 00:00:01.000]   Hello."
    ) throws -> URL {
        let bin = root.appendingPathComponent("build/bin", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        let program = bin.appendingPathComponent("whisper-cli")
        try makeExecutable(at: program, script: """
            #!/bin/sh
            echo "\(transcript)"
            """)
        try Data([0]).write(to: models.appendingPathComponent("ggml-small.en.bin"))
        return program
    }

    /// The absolute candidates `LocalASRDiscovery` prefers over a staged
    /// checkout, so a test can say when it is about to measure the wrong
    /// program.
    private func installedWhisper() -> String? {
        [
            "/opt/homebrew/bin/whisper-cli",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper-cli",
            "/usr/local/bin/whisper"
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func scratchDirectories() throws -> Set<String> {
        Set(
            try FileManager.default
                .contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("mynah-asr-") }
        )
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
