import Foundation

/// Turning synthesized speech into something Signal renders as a voice note.
///
/// `SynthesizedSpeech` is WAV, because that is what every backend can produce
/// and what the protocol promises. Signal will happily *attach* a WAV, but it
/// shows up as a file the owner has to tap and open. An AAC track in an MPEG-4
/// container gets the inline player with a waveform and a duration, which is the
/// difference between "an answer" and "a file about an answer".
///
/// It is also eight times smaller — 160 KB of WAV for one sentence became 20 KB
/// of m4a, measured — and that matters on a phone that may be on cellular.
public enum VoiceNote {

    /// Where voice notes are staged before sending.
    ///
    /// Owner-only, like everything else that holds the owner's words: this is
    /// the appliance saying something private out loud, and the file exists on
    /// disk for as long as the send takes.
    public static func directory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("VoiceNotes", isDirectory: true)
    }

    /// Writes `speech` as an m4a and returns the file.
    ///
    /// - Parameter runner: `afconvert`, which ships with macOS. No third-party
    ///   encoder, and nothing leaves the machine.
    public static func write(
        _ speech: SynthesizedSpeech,
        runner: ProbeCommandRunning = ProbeCommandRunner(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> URL {
        let directory = directory(homeDirectory: homeDirectory)
        try OwnerOnlyFileSecurity.prepareDirectory(directory, fileManager: fileManager)

        let stem = UUID().uuidString
        let wav = directory.appendingPathComponent("\(stem).wav")
        let m4a = directory.appendingPathComponent("\(stem).m4a")
        try OwnerOnlyFileSecurity.write(speech.wav, to: wav, fileManager: fileManager)
        defer { try? fileManager.removeItem(at: wav) }

        let converted = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: ["-f", "m4af", "-d", "aac", "-q", "127", wav.path, m4a.path],
            timeout: 60
        )
        guard let converted, converted.exitCode == 0, fileManager.fileExists(atPath: m4a.path) else {
            throw SpeechSynthesisError.requestFailed(
                "afconvert could not make a voice note: \(converted?.standardError ?? "could not launch")"
            )
        }
        try OwnerOnlyFileSecurity.protectFile(m4a, fileManager: fileManager)
        return m4a
    }

    /// Deletes voice notes left behind by turns that failed after writing one.
    ///
    /// Called at boot rather than tracked per-file: a crash between writing and
    /// sending is exactly when the tracking would not have run, and the files
    /// are the owner's own answers sitting in plaintext audio.
    public static func discardStale(
        olderThan age: TimeInterval = 3600,
        now: Date = Date(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Int {
        let directory = directory(homeDirectory: homeDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

/// Which voice the appliance speaks in.
///
/// A separate file from `ReplyPreferences` because they answer different
/// questions and change at different times: one is *whether* to speak, the other
/// is *how*. Same directory and the same owner-only permissions as the rest.
public struct VoicePreferences: Sendable {

    private let fileURL: URL

    public init(fileURL: URL = VoicePreferences.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("voice-preferences.json", isDirectory: false)
    }

    private struct Stored: Codable {
        var voice: String?
        var speed: Double?
    }

    /// The chosen voice, or `nil` to let the synthesizer pick the best installed
    /// one. Never throws — a preferences file that will not parse should cost
    /// the owner their preference, not their appliance.
    public func voice() -> String? {
        stored()?.voice
    }

    /// Speaking rate multiplier, clamped to something a person can follow.
    ///
    /// The bounds are not decoration: `say` takes words per minute, and a
    /// mistyped value produces either a chipmunk or something slower than the
    /// silence it replaced.
    public func speed() -> Double {
        min(1.5, max(0.6, stored()?.speed ?? 1.0))
    }

    private func stored() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    public func save(voice: String?, speed: Double = 1.0) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = Stored(voice: voice, speed: min(1.5, max(0.6, speed)))
        try OwnerOnlyFileSecurity.write(encoder.encode(payload), to: fileURL)
    }
}
