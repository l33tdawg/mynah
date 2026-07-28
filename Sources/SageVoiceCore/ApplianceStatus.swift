import Foundation

/// What the appliance is actually running, written by the appliance itself.
///
/// Settings answers "where your words go" from `BrainSelectionStore`, which
/// records what the owner chose *in the app*. Nothing outside `MynahMac` reads
/// it: the daemon builds its backend from `flags["provider"] ?? "ollama"`, so
/// after an afternoon of switching the appliance to DeepSeek by hand, Settings
/// still said "Fully on this Mac", the pill still said "This Mac", and the
/// privacy section still said nothing leaves the machine — while every voice
/// note went to a third party.
///
/// On a product whose entire pitch is where-your-words-go, that is the one
/// question that must never be wrong. So the process that answers the phone
/// reports what it resolved, and the screen reads that instead of guessing.
public struct ApplianceStatus: Sendable, Codable, Equatable {

    /// Backend identifier as the daemon resolved it: `ollama`, `deepseek`, …
    public var provider: String
    /// Concrete model, e.g. `deepseek-v4-flash`.
    public var model: String
    /// Whether the words stay on this machine. Taken from the backend rather
    /// than inferred from the name, so a new local backend cannot be quietly
    /// misreported as cloud or the reverse.
    public var keepsWordsOnDevice: Bool
    /// When the daemon last started. Lets a reader say "as of 14:32" rather
    /// than implying this is live.
    public var startedAt: Date
    /// The reply style in force, so Settings can stop claiming voice notes on
    /// an appliance running in written mode.
    public var speaksReplies: Bool

    public init(
        provider: String,
        model: String,
        keepsWordsOnDevice: Bool,
        startedAt: Date = Date(),
        speaksReplies: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.keepsWordsOnDevice = keepsWordsOnDevice
        self.startedAt = startedAt
        self.speaksReplies = speaksReplies
    }

    /// The company the words reach, or `nil` when they stay put.
    ///
    /// Deliberately not a lookup table of every provider: an unrecognised one
    /// returns its own identifier rather than "A company", because a name the
    /// owner half-recognises is more use than a shrug, and inventing a friendly
    /// label for a backend nobody has mapped is how this went wrong in the
    /// first place.
    public var destination: String {
        keepsWordsOnDevice ? "This Mac" : provider
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("appliance-status.json", isDirectory: false)
    }

    /// Written by the daemon at start-up.
    ///
    /// Never throws into the caller's face: failing to publish status is worth a
    /// log line, not a daemon that will not start. That lesson cost an outage
    /// this afternoon.
    public static func publish(
        _ status: ApplianceStatus,
        to fileURL: URL = ApplianceStatus.defaultFileURL()
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? OwnerOnlyFileSecurity.write(data, to: fileURL)
    }

    /// What the appliance last reported, or `nil` when it has never run.
    ///
    /// `nil` is meaningful and must not be papered over: it means nobody has
    /// answered a phone on this machine, which is a different sentence from any
    /// provider name.
    public static func current(
        from fileURL: URL = ApplianceStatus.defaultFileURL()
    ) -> ApplianceStatus? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ApplianceStatus.self, from: data)
    }

    /// Clears the record when the appliance stops for good.
    public static func withdraw(from fileURL: URL = ApplianceStatus.defaultFileURL()) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
