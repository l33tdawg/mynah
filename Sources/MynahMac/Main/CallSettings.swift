import AVFoundation
import Foundation
import SageVoiceCore

// MARK: - What the owner chose about calls

/// The two call preferences, and the only place their defaults keys are spelled.
///
/// Its own file rather than another type inside `SettingsView`: this is a network
/// call, an audio player and a store, none of which is view code, and the tests
/// that pin the keys should not have to build a screen to reach them.
///
/// The keys carry no `mynah.` prefix, unlike everything else this app persists.
/// That is deliberate and it is a contract. The change that passes `--call-voice`
/// to the daemon and the change that posts a finished transcript back into Signal
/// read these exact strings; a prefix invented here would leave the owner setting
/// a control that nothing on the other side is listening to.
/// The three call preferences, stored where the daemon can read them.
///
/// A file, not UserDefaults, and that distinction is the entire point. The app
/// and the daemon are separate processes with separate defaults domains, so a
/// value written to this app's domain is a value the daemon never sees — the
/// control moves, the preference is saved, and nothing changes. That is worse
/// than having no control at all, because the owner has been told otherwise.
///
/// `CallPreferences` lives in the shared module for exactly this reason, and
/// `ReplyPreferences` already solved the same problem the same way for the
/// voice-notes switch.
struct CallSettingsStore {

    private let fileURL: URL

    init(fileURL: URL = CallPreferences.defaultFileURL()) {
        self.fileURL = fileURL
    }

    private var current: CallPreferences { CallPreferences.load(from: fileURL) }

    private func update(_ change: (inout CallPreferences) -> Void) {
        var preferences = current
        change(&preferences)
        // A preference that cannot be saved should not take the app down. The
        // owner will notice the control springing back, which is a better
        // failure than a crash.
        try? preferences.save(to: fileURL)
    }

    /// The Kokoro voice calls speak in.
    ///
    /// Falls back to the same name the daemon falls back to, so an owner who has
    /// never opened this screen sees what they would actually hear rather than a
    /// second default invented here.
    var voice: String {
        get { current.voice ?? KokoroHTTPSynthesizer.defaultKokoroVoice }
        nonmutating set { update { $0.voice = newValue } }
    }

    /// How fast it speaks.
    ///
    /// Clamped on read as well as write, because the file is editable by hand
    /// and a rate outside the usable range produces a voice the owner cannot
    /// understand and may not connect to this control.
    var speed: Double {
        get { current.clampedSpeed }
        nonmutating set { update { $0.speed = newValue } }
    }

    /// Whether a finished call gets posted back into the Signal thread.
    ///
    /// Absent means "never asked", and a call that leaves no record anywhere is
    /// the thing being fixed, so the unasked answer is yes.
    var sendsTranscript: Bool {
        get { current.transcript }
        nonmutating set { update { $0.transcript = newValue } }
    }
}

// MARK: - The voices Kokoro is serving

/// What the local speech bridge has to offer, or the honest absence of it.
enum CallVoiceCatalogue: Equatable {
    /// Still asking. A separate case from `.missing` so the screen does not
    /// accuse the owner of a missing install during the moment it takes to
    /// find out.
    case checking
    case installed([String])
    /// Nothing answered on the bridge. Calls fall back to macOS `say`.
    case missing
}

/// The voices the appliance can actually speak in.
///
/// **Read out of the voices file, not off a server.** This used to `GET /voices`
/// on the Python bridge, which meant the Settings picker was empty whenever that
/// service was not running — and the service is now gone entirely. The names live
/// in `voices-v1.0.bin`, the same file the synthesizer reads its style rows from,
/// so the picker and the voice are guaranteed to be talking about the same set.
///
/// Named `CallVoiceLibrary` rather than `KokoroVoices` because that name is now
/// taken by the type in `SageVoiceCore` that does the reading. Two `KokoroVoices`
/// in one app, one shadowing the other inside this module, is a resolution
/// somebody would eventually get wrong.
enum CallVoiceLibrary {

    /// Never throws and never reports a reason.
    ///
    /// Every way this can fail — the model not downloaded yet, a truncated
    /// file — lands the owner in the same place: there is no natural voice to
    /// pick from, and calls will sound robotic until the download finishes. One
    /// sentence covers all of them, and the alternative is a settings row
    /// quoting a file-format error.
    static func load(from url: URL? = nil) async -> CallVoiceCatalogue {
        let location = url ?? KokoroAssets.location(of: KokoroAssets.voices)
        guard FileManager.default.fileExists(atPath: location.path) else { return .missing }
        do {
            let names = try SageVoiceCore.KokoroVoices(contentsOf: location)
                .names
                .filter { !$0.isEmpty }
                .sorted()
            // A file with no voices in it cannot be picked from, and an empty
            // picker is exactly the broken control this is here to avoid.
            return names.isEmpty ? .missing : .installed(names)
        } catch {
            return .missing
        }
    }

    /// Kokoro's own naming scheme: first letter the accent, second the gender.
    ///
    /// Fifty-four rows of `af_alloy` is a list of file names, not a choice
    /// anybody can make, so the scheme gets decoded into the words it stands for.
    /// Anything with a prefix not listed here keeps its raw identifier — a
    /// confidently wrong friendly label would be worse than an unfriendly true
    /// one.
    static func displayName(_ identifier: String) -> String {
        let parts = identifier.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2, !parts[1].isEmpty else { return identifier }
        let prefix = Array(parts[0])
        guard let accent = accents[prefix[0]], let gender = genders[prefix[1]] else {
            return identifier
        }
        let name = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        return "\(name) (\(accent), \(gender))"
    }

    private static let accents: [Character: String] = [
        "a": "American",
        "b": "British",
        "e": "Spanish",
        "f": "French",
        "h": "Hindi",
        "i": "Italian",
        "j": "Japanese",
        "p": "Portuguese",
        "z": "Mandarin",
    ]

    private static let genders: [Character: String] = [
        "f": "female",
        "m": "male",
    ]
}

// MARK: - Hearing a voice before choosing it

/// Speaks one sentence in a candidate voice.
///
/// A name on a menu is not a voice. Fifty-four of them are indistinguishable
/// until you hear one, and the owner should not have to place a real call to
/// find out that the one they picked grates.
@MainActor
final class CallVoicePreview {

    /// Short, ordinary, and about the thing being demonstrated. A long sample
    /// wastes the owner's time on every voice they audition, and a sentence with
    /// nothing to do with calling makes them work out what they are listening to.
    static let sample = "This is how I'll sound when you call."

    /// Held for the length of the clip. An `AVAudioPlayer` that goes out of
    /// scope stops immediately, which is a Listen button that makes no sound.
    private var player: AVAudioPlayer?

    /// Returns when the clip has finished, so the caller can keep the button
    /// showing "playing" for exactly as long as something is playing.
    /// Plays the sample at the voice AND rate the owner has chosen.
    ///
    /// Both, because a preview at a different speed than the call is a preview
    /// of something else — and speaking rate is exactly the setting nobody can
    /// judge from a number.
    func play(voice: String, speed: Double) async throws {
        let synthesizer = KokoroHTTPSynthesizer(voice: voice)
        let speech = try await synthesizer.synthesize(
            SpeechRequest(text: Self.sample, voice: voice, speed: speed)
        )
        stop()
        let player = try AVAudioPlayer(data: speech.wav)
        self.player = player
        player.play()
        // The WAV header already told us how long this is, so waiting it out
        // needs no delegate and no polling.
        try? await Task.sleep(for: .seconds(max(speech.duration, 0.1)))
        stop()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
