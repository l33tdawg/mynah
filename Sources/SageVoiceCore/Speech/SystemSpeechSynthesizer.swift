import Foundation

/// macOS's own speech, via `/usr/bin/say`.
///
/// The floor, not the ceiling. `KokoroHTTPSynthesizer` sounds dramatically more
/// human and should be preferred whenever its service is reachable — but it
/// needs a service, and an appliance that only speaks when an optional daemon
/// happens to be running is an appliance that does not speak.
///
/// This one has no dependencies at all: `say` and `afconvert` ship with macOS,
/// everything happens on the machine, and nothing is uploaded. That matters more
/// than it sounds, because the product's argument is that the owner's words stay
/// put — a cloud TTS with a nicer voice would quietly undo it by shipping every
/// answer to a third party.
///
/// ## On voice quality
///
/// The voices installed by default are the *compact* set, and they sound like
/// it. The good ones — Siri, and the "Premium"/"Enhanced" variants of the named
/// voices — are free but downloaded on demand through System Settings →
/// Accessibility → Spoken Content → System Voice → Manage Voices. There is no
/// supported way to fetch them headlessly, which is why `preferredVoices`
/// *prefers* them and falls back rather than requiring them: the appliance
/// speaks today, and sounds much better the moment the owner downloads one.
/// `@unchecked` for the injected `FileManager`, which is not `Sendable`; it is
/// only ever read, and `.default` is documented thread-safe. Same trade as
/// `NotesToolSource` and `ConversationStore`.
public struct SystemSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {

    public let identifier = "macos-say"

    /// Best first. Every name here is a real macOS voice; the resolver picks the
    /// first one actually installed, so a machine with the premium set gets it
    /// and a bare one still works.
    ///
    /// Ordered by how close to human they sound, not by fame: the Siri voices
    /// are in a different class, then the modern named voices, then Alex — which
    /// is ancient and still the most intelligible of the compact set.
    public static let preferredVoices = [
        "Zoe (Premium)", "Evan (Premium)", "Nathan (Premium)", "Ava (Premium)",
        "Zoe (Enhanced)", "Evan (Enhanced)", "Ava (Enhanced)", "Samantha (Enhanced)",
        "Samantha", "Alex", "Daniel", "Karen"
    ]

    public var defaultVoice: String { "Samantha" }

    private let runner: ProbeCommandRunning
    private let voice: String?
    private let fileManager: FileManager

    /// - Parameter voice: an exact `say -v` name, or `nil` to resolve the best
    ///   installed one from `preferredVoices`.
    /// The rate synthesis is delivered at.
    ///
    /// 22.05 kHz is plenty for a voice note, which is played as a file. A call
    /// is different: Opus runs at 48 kHz, and anything else has to be resampled
    /// before it can be encoded. Asking afconvert for the rate we need costs
    /// nothing and avoids a hand-written resampler in the audio path — the one
    /// place a subtle error is inaudible in testing and awful on a real call.
    public var sampleRate: Int = 22050

    public init(
        voice: String? = nil,
        runner: ProbeCommandRunning = ProbeCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.voice = voice
        self.runner = runner
        self.fileManager = fileManager
    }

    public func isAvailable() async -> Bool {
        fileManager.isExecutableFile(atPath: "/usr/bin/say")
            && fileManager.isExecutableFile(atPath: "/usr/bin/afconvert")
    }

    /// Voices `say` reports as installed, in its own order.
    public func installedVoices() async -> [String] {
        let result = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/say"),
            arguments: ["-v", "?"],
            timeout: 10
        )
        guard let result, result.exitCode == 0 else { return [] }
        return Self.parseVoiceList(result.standardOutput)
    }

    /// `say -v ?` prints `Name          en_US    # Sample sentence`, and the name
    /// itself can contain spaces and parentheses — "Zoe (Premium)". Splitting on
    /// whitespace loses exactly the voices worth having, so the locale column is
    /// the anchor.
    public static func parseVoiceList(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let localeRange = line.range(
                of: "\\s{2,}[a-z]{2}(_[A-Z]{2})?\\s",
                options: .regularExpression
            ) else { return nil }
            let name = line[line.startIndex..<localeRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    /// The best installed voice, or `nil` to let `say` use the system default.
    public func resolveVoice() async -> String? {
        if let voice { return voice }
        let installed = Set(await installedVoices())
        return Self.preferredVoices.first { installed.contains($0) }
    }

    public func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechSynthesisError.emptyText }

        let started = Date()
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("mynah-tts-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let aiff = scratch.appendingPathComponent("speech.aiff")
        let wav = scratch.appendingPathComponent("speech.wav")

        var arguments = ["-o", aiff.path]
        if let voice = await resolveVoice() {
            arguments += ["-v", voice]
        }
        // `say`'s rate is words per minute, not a multiplier. 175 is close to its
        // natural pace, so a 1.0 request lands where the backend would anyway.
        if request.speed != 1.0 {
            arguments += ["-r", String(Int((175 * request.speed).rounded()))]
        }
        // Last, and never interpolated into a shell string — the text is a model
        // reply and may contain anything.
        arguments.append(text)

        // Generous, and bounded. A long reply legitimately takes a few seconds,
        // and a wedged `say` must not hold a Signal turn open forever.
        let spoken = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/say"),
            arguments: arguments,
            timeout: 60
        )
        guard let spoken, spoken.exitCode == 0, fileManager.fileExists(atPath: aiff.path) else {
            throw SpeechSynthesisError.requestFailed(
                "say failed: \(spoken?.standardError ?? "could not launch")"
            )
        }

        // The protocol promises 16-bit PCM in a RIFF/WAVE container, and `say`
        // emits AIFF. `afconvert` is the supported converter and ships with the
        // OS, so nothing has to parse an audio format by hand.
        let converted = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: ["-f", "WAVE", "-d", "LEI16@\(sampleRate)", "-c", "1", aiff.path, wav.path],
            timeout: 30
        )
        guard let converted, converted.exitCode == 0, fileManager.fileExists(atPath: wav.path) else {
            throw SpeechSynthesisError.requestFailed(
                "afconvert failed: \(converted?.standardError ?? "could not launch")"
            )
        }
        let data = try Data(contentsOf: wav)
        let format = try? WAVAudio.format(of: data)

        return SynthesizedSpeech(
            wav: data,
            sampleRate: format?.sampleRate ?? 22_050,
            channelCount: format?.channelCount ?? 1,
            duration: format?.duration ?? 0,
            timeToFirstAudio: Date().timeIntervalSince(started),
            generationDuration: Date().timeIntervalSince(started)
        )
    }
}
