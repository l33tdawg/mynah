import Foundation

/// What the owner chose about calls, where both processes can see it.
///
/// A file, not UserDefaults, and the distinction is the whole point. The app and
/// the daemon are separate processes with separate defaults domains: a value the
/// Settings screen writes to its own domain is a value the daemon never reads.
/// The control moves, the preference is stored, and nothing changes — which is
/// worse than having no control, because the owner has been told otherwise.
///
/// `ReplyPreferences` already solved this the same way for the voice-notes
/// switch. This follows it rather than inventing a second mechanism.
public struct CallPreferences: Sendable, Equatable, Codable {

    /// Which Kokoro voice calls speak in. `nil` means the synthesiser's default.
    public var voice: String?

    /// Speaking rate, as a multiplier on the voice's natural pace.
    ///
    /// Slightly quick by default. A synthesiser at 1.0 reads at the pace of an
    /// audiobook, which suits a chapter and not an exchange where the caller
    /// already knows what they asked.
    public var speed: Double

    /// Whether a finished call is posted back into the Signal thread.
    public var transcript: Bool

    public init(voice: String? = nil, speed: Double = 1.15, transcript: Bool = true) {
        self.voice = voice
        self.speed = speed
        self.transcript = transcript
    }

    /// The bounds a speaking rate is clamped to.
    ///
    /// Below 0.7 the voice sounds drugged; past about 1.4 the words run together
    /// on a phone speaker. A preference file is editable by hand and a slider
    /// can be given a wider range by a later change, so this is enforced where
    /// it is read rather than only where it is set.
    public static let slowest = 0.7
    public static let fastest = 1.4

    public var clampedSpeed: Double {
        min(max(speed, CallPreferences.slowest), CallPreferences.fastest)
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("call-preferences.json", isDirectory: false)
    }

    /// Reads the owner's choices, or the defaults.
    ///
    /// Never throws. A preferences file that will not parse should cost the
    /// owner their preference, not their ability to take a call.
    public static func load(from url: URL = CallPreferences.defaultFileURL()) -> CallPreferences {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(CallPreferences.self, from: data) else {
            return CallPreferences()
        }
        return stored
    }

    public func save(to url: URL = CallPreferences.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }
}
