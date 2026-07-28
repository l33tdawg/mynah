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
struct CallSettingsStore {

    private enum Key {
        /// No shared constant to point at: the daemon takes the voice as a
        /// `--call-voice` launch flag, not by reading defaults, so this string
        /// is the seam and the test that pins it is the only thing holding it.
        static let voice = "callVoice"
        /// Borrowed from the reader rather than spelled again. `TranscriptPreference`
        /// is what consults this during a call, and one constant shared across
        /// the two processes cannot drift the way two matching literals can.
        static let transcript = TranscriptPreference.key
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The Kokoro voice calls speak in.
    ///
    /// Falls back to the same name the daemon falls back to, so an owner who has
    /// never opened this screen sees what they would actually hear rather than a
    /// second default invented here.
    var voice: String {
        get { defaults.string(forKey: Key.voice) ?? KokoroHTTPSynthesizer.defaultKokoroVoice }
        nonmutating set { defaults.set(newValue, forKey: Key.voice) }
    }

    /// Whether a finished call gets posted back into the Signal thread.
    ///
    /// Absent means "never asked", and a call that leaves no record anywhere is
    /// the thing being fixed, so the unasked answer is yes.
    var sendsTranscript: Bool {
        get { defaults.object(forKey: Key.transcript) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.transcript) }
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

/// Reading the voice list off the local speech bridge.
enum KokoroVoices {

    /// Three seconds. The row is on screen before this answers, so the cost of
    /// waiting longer is the owner staring at "looking for the natural voice"
    /// with no way to tell whether it is stuck.
    private static let timeout: TimeInterval = 3

    /// `/voices` on whichever bridge serves `/api/speech`.
    ///
    /// Derived from the synthesizer's own endpoint rather than typed out again,
    /// so a bridge moved to another port cannot leave this picker listing the
    /// voices of a server the calls are not using.
    static func endpoint(bridge: URL = KokoroHTTPSynthesizer.defaultEndpoint) -> URL {
        var components = URLComponents(url: bridge, resolvingAgainstBaseURL: false)
        components?.path = "/voices"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? bridge
    }

    private struct Payload: Decodable {
        let voices: [String]
    }

    /// Never throws and never reports a reason.
    ///
    /// Every way this can fail — bridge down, wrong port, a body that is not the
    /// JSON we expect — lands the owner in the same place: there is no natural
    /// voice to pick from, and calls will sound robotic. One sentence covers all
    /// of them, and the alternative is a settings row quoting a connection error.
    static func load(
        from url: URL? = nil,
        session: URLSession? = nil
    ) async -> CallVoiceCatalogue {
        let endpoint = url ?? Self.endpoint()
        // The same refusal the synthesizer makes. A "local" speech bridge that
        // resolves off-box is not one this app will talk to.
        guard LoopbackSecurity.isLoopback(endpoint) else { return .missing }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let session = session ?? LoopbackSecurity.makeSession(timeout: timeout)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return .missing }
            let names = try JSONDecoder().decode(Payload.self, from: data)
                .voices
                .filter { !$0.isEmpty }
                .sorted()
            // A bridge answering with no voices cannot be picked from, and an
            // empty picker is exactly the broken control this is here to avoid.
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
    func play(voice: String) async throws {
        let synthesizer = KokoroHTTPSynthesizer(voice: voice)
        let speech = try await synthesizer.synthesize(
            SpeechRequest(text: Self.sample, voice: voice)
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
