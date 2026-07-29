import AVFoundation
import Foundation
import OSLog
import SageVoiceCore

// MARK: - Recording from this Mac's microphone

/// The missing half of hold-to-talk.
///
/// Everything else was already here: the `VoiceCapture` seam, the composer
/// control, the level meter, the cancel path, and the whole recognition stack
/// the phone has always used. What had never existed anywhere in this app was
/// *capture* — no `AVAudioEngine`, no tap, no recorder. Every WAV Mynah had
/// ever transcribed arrived from Signal or from the call endpoint.
///
/// So this is deliberately thin: record, resample, write a WAV, hand it to the
/// transcriber that already exists, return the words. It decides nothing about
/// what happens to them — `finish()` returns text and the model puts it in the
/// composer, because a mishearing has to be something the owner sees before
/// Mynah acts on it. Measured mishearings from this very stack: VANTARAQ became
/// "Vantirac", QuietType became "Quiet Type". A voice note that sent before the
/// owner could fix a name would be worse than typing.
@MainActor
final class MicrophoneVoiceCapture: VoiceCapture {

    /// What the recogniser wants. Whisper is trained at 16 kHz mono and the
    /// call endpoint already decodes to the same rate, so this is the one place
    /// the hardware's own format has to be converted from rather than passed
    /// through.
    static let sampleRate = 16_000

    /// Below this, `finish()` reports nothing was heard rather than handing the
    /// recogniser silence. Whisper confabulates on silence — a quiet moment on
    /// a call came back as Japanese and the appliance answered it — so the
    /// cheapest defence is not to ask it about audio this short.
    static let shortestUsefulSeconds = 0.35

    enum Trouble: LocalizedError, Equatable {
        case microphoneRefused
        case noRecogniser(String)
        case heardNothing

        var errorDescription: String? {
            switch self {
            case .microphoneRefused:
                return "Mynah needs permission to use this Mac's microphone. "
                    + "macOS only asks once, so this has to be turned on in System Settings."
            case .noRecogniser(let why):
                return "Mynah can't turn speech into words on this Mac right now. \(why)"
            case .heardNothing:
                return "Nothing was recorded — try holding the button a little longer."
            }
        }

        /// Whether this failure has somewhere for the owner to be sent.
        ///
        /// Only the refusal does, and it is the one that most needs it: macOS
        /// never shows the prompt twice, so after a refusal a *sentence*
        /// describing where the switch lives is the owner's entire route, and
        /// it asks them to go navigating System Settings to find a pane they
        /// have never opened.
        public var opensPrivacySettings: Bool {
            self == .microphoneRefused
        }
    }

    private let access: MicrophoneAccess
    private let prepareTranscriber: @Sendable () async throws -> any AudioFileTranscribing
    private var transcriber: (any AudioFileTranscribing)?

    private var engine: AVAudioEngine?
    private var recording: SampleSink?
    private var meter: Task<Void, Never>?

    private(set) var level: Double = 0

    private static let log = Logger(subsystem: "local.sage.voicebridge", category: "voice-capture")

    /// - Parameters:
    ///   - access: nil builds the real one. Not a default argument, because a
    ///     default is evaluated in the *caller's* isolation and
    ///     `MicrophoneAccess` is main-actor — naming it there is an isolation
    ///     error rather than a convenience.
    ///   - prepareTranscriber: the same runtime the daemon uses, so the window
    ///     and the phone hear with one recogniser rather than two.
    init(
        access: MicrophoneAccess? = nil,
        prepareTranscriber: @escaping @Sendable () async throws -> any AudioFileTranscribing = {
            try await LocalASRRuntime.shared.prepare()
        }
    ) {
        self.access = access ?? MicrophoneAccess()
        self.prepareTranscriber = prepareTranscriber
    }

    /// The capture object, or nil when this Mac cannot transcribe.
    ///
    /// `ConversationModel.canHoldToTalk` is `voice != nil`, so returning nil
    /// here is what makes the control *absent* rather than present-and-failing.
    /// That is the rule the composer already follows for every other dead
    /// affordance in this app: a control that cannot lead anywhere does not
    /// ship, and the composer says where voice comes from instead.
    ///
    /// The check is deliberately the cheap synchronous one — are the recogniser
    /// and a model actually on disk — because the only place this can be asked
    /// is `ConversationModel.shared`, which is a synchronous initialiser.
    /// Preparing the recogniser for real is async and happens on first use.
    ///
    /// Microphone *permission* is not part of this test. An owner who has never
    /// been asked has not refused, and hiding the control from them would mean
    /// they could never be asked. Permission is resolved when they first press.
    static func ifAvailable(
        discovery: LocalASRDiscovery = LocalASRDiscovery()
    ) -> MicrophoneVoiceCapture? {
        guard discovery.firstExecutable() != nil, discovery.firstModel() != nil else {
            log.info("no local recogniser on this Mac — hold-to-talk stays hidden")
            return nil
        }
        return MicrophoneVoiceCapture()
    }

    // MARK: Recording

    func begin() async throws {
        guard await allowedToListen() else { throw Trouble.microphoneRefused }

        // Prepared once and kept. The first press pays for loading the model;
        // every press after it does not.
        if transcriber == nil {
            do {
                transcriber = try await prepareTranscriber()
            } catch {
                throw Trouble.noRecogniser("\(error)")
            }
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)

        // The hardware picks its own rate — 44.1 or 48 kHz on every Mac I have
        // seen — and the recogniser wants 16 kHz mono. Converting in the tap
        // rather than after the fact keeps memory flat for a long recording:
        // a minute at 48 kHz stereo is 11 MB of Float, and at 16 kHz mono it is
        // under 4 MB.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: hardware, to: target) else {
            throw Trouble.noRecogniser("this Mac's microphone format could not be converted.")
        }

        let sink = SampleSink()
        recording = sink

        input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { buffer, _ in
            // Runs on a real-time audio thread. Nothing here may allocate
            // unboundedly, block, or touch the main actor — hence the lock-
            // guarded sink rather than an `await`.
            sink.absorb(buffer, through: converter, as: target)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            recording = nil
            throw Trouble.noRecogniser("the microphone could not be started: \(error)")
        }
        self.engine = engine
        startMetering()
    }

    /// Stops, transcribes, and returns the words.
    func finish() async throws -> String {
        guard let sink = stopEngine() else { throw Trouble.heardNothing }
        let samples = sink.drain()
        guard Double(samples.count) / Double(Self.sampleRate) >= Self.shortestUsefulSeconds else {
            throw Trouble.heardNothing
        }
        guard let transcriber else { throw Trouble.noRecogniser("the recogniser went away.") }

        let wav = WAVAudio.encode(samples: samples, sampleRate: Self.sampleRate)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-voice-\(UUID().uuidString).wav")
        try wav.write(to: file, options: .atomic)
        // Removed whatever happens next. The owner's speech is not something to
        // leave in /tmp because a transcription threw.
        defer { try? FileManager.default.removeItem(at: file) }

        let text = try await transcriber.transcribe(audioFile: file)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Trouble.heardNothing }
        // The owner's own words, repaired from what Mynah remembers — the same
        // profile the daemon uses, so a coinage comes out the same whether it
        // was spoken here or into a phone. With no memories this is the
        // identity function, which is the state on this machine today.
        return await DictationProfileStore.shared.repair(trimmed)
    }

    /// Starts building the dictation profile, off the critical path.
    ///
    /// Called when the owner focuses the composer rather than when they press
    /// record: by the time a sentence has been spoken the profile is usually
    /// there, and if it is not, `repair` returns the transcript unchanged and
    /// uses it next time.
    func warmUpProfile() {
        Task { await DictationProfileStore.shared.warmUp() }
    }

    /// Abandons the recording. Safe to call when nothing is running.
    func cancel() {
        _ = stopEngine()
    }

    /// Opens the exact System Settings pane the owner needs.
    ///
    /// A button beats the sentence it replaces, and by more than convenience:
    /// macOS never re-prompts after a refusal, so this is the only route left,
    /// and the deep link lands on Privacy & Security → Microphone rather than
    /// on the front page of a Settings app with thirty panes in it.
    ///
    /// The URL survived a near-miss. It lived only in a setup screen that was
    /// deleted as unused, and it would have gone with it — `chrome` rescued the
    /// type and flagged the link, which is the only reason it is here.
    ///
    /// Whatever renders `Trouble.microphoneRefused` should offer this; the
    /// error says so via `opensPrivacySettings`.
    func openPrivacySettings() {
        access.openPrivacySettings()
    }

    // MARK: Machinery

    /// Whether macOS will hand over the microphone, asking once if it can.
    ///
    /// All the hard rules live in `MicrophoneAccess` and are honoured by
    /// deferring to it rather than re-deriving them here: the system prompt
    /// appears **once ever**, so a refusal cannot be re-asked; asking without a
    /// usage string terminates the process rather than erroring; and a grant
    /// made in System Settings does not reach a running app. This is why
    /// `request()` is only called from `.notAsked` — every other state is
    /// already its final answer for this launch.
    private func allowedToListen() async -> Bool {
        access.refresh()
        if access.status == .notAsked {
            await access.request()
        }
        return access.status == .granted
    }

    private func stopEngine() -> SampleSink? {
        meter?.cancel()
        meter = nil
        level = 0
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        defer { recording = nil }
        return recording
    }

    /// Publishes the level for the meter.
    ///
    /// Polled rather than pushed: the tap runs on an audio thread and hopping
    /// to the main actor per buffer would be ~90 hops a second to move one
    /// `Double`. Twenty a second is smoother than the eye needs and costs
    /// nothing.
    private func startMetering() {
        meter?.cancel()
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let recording else { return }
                self.level = recording.level()
            }
        }
    }
}

// MARK: - The buffer the audio thread writes into

/// Accumulated samples, at the recogniser's rate.
///
/// `@unchecked Sendable` with an explicit lock because the producer is a
/// real-time audio callback and the consumer is the main actor. An actor would
/// be the tidier spelling and the wrong tool: `absorb` must not suspend, and
/// hopping off the audio thread per buffer is exactly what makes recordings
/// glitch.
private final class SampleSink: @unchecked Sendable {

    private let lock = NSLock()
    private var samples: [Float] = []
    private var recentPeak: Float = 0

    /// Converts one hardware buffer to the target format and keeps it.
    func absorb(_ buffer: AVAudioPCMBuffer, through converter: AVAudioConverter, as target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            // The converter asks repeatedly; handing it the same buffer twice
            // would duplicate audio, so the second ask reports the end of the
            // stream instead.
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }

        let frames = Int(out.frameLength)
        var peak: Float = 0
        for index in 0..<frames {
            peak = max(peak, abs(channel[index]))
        }

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        recentPeak = peak
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// 0…1 for the meter, from the most recent buffer's peak.
    ///
    /// Peak rather than RMS on purpose: this drives a "you are being heard"
    /// indicator, not a mastering meter, and RMS on speech sits so low that the
    /// bar barely moves and the owner cannot tell it is working.
    func level() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(min(1, recentPeak * 1.8))
    }
}
