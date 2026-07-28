import Foundation

/// What was said on a call, so it does not vanish when the line closes.
///
/// Everything else the appliance does leaves a record the owner can scroll
/// back to. A call left nothing at all: the most natural way to talk to it was
/// the only one where afterwards there was no way to check what it had said, or
/// what they had asked it to do.
///
/// Posted back into the same Signal thread when the call ends, so a spoken
/// exchange ends up in the same place as a written one.
public struct CallTranscript: Sendable {

    public struct Line: Sendable, Equatable {
        public enum Speaker: Sendable, Equatable {
            case owner
            case appliance
        }
        public let speaker: Speaker
        public let text: String

        public init(speaker: Speaker, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    public private(set) var lines: [Line] = []
    public private(set) var started: Date

    public init(started: Date = Date()) {
        self.started = started
    }

    public mutating func heard(_ text: String) {
        append(Line(speaker: .owner, text: text))
    }

    public mutating func said(_ text: String) {
        append(Line(speaker: .appliance, text: text))
    }

    private mutating func append(_ line: Line) {
        let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(Line(speaker: line.speaker, text: trimmed))
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// The message posted to the thread when the call ends.
    ///
    /// Returns nothing for a call where nothing was said. A link tapped by
    /// accident, or a call that failed before anyone spoke, should not leave a
    /// message announcing that nothing happened.
    ///
    /// The appliance's own name is used rather than a generic label, because the
    /// owner reads this in a thread where they also talk to it by name.
    public func message(ended: Date = Date(), name: String = "Mynah") -> String? {
        // The greeting alone is not a conversation. A call the owner joined and
        // left without speaking has exactly one line in it, and a transcript of
        // the appliance saying hello to nobody is noise in the thread.
        guard lines.contains(where: { $0.speaker == .owner }) else { return nil }

        let spoken = lines.map { line in
            switch line.speaker {
            case .owner: return "You: \(line.text)"
            case .appliance: return "\(name): \(line.text)"
            }
        }.joined(separator: "\n\n")

        return "Call — \(CallTranscript.length(ended.timeIntervalSince(started)))\n\n\(spoken)"
    }

    /// "3 minutes", "under a minute" — how someone would describe it.
    static func length(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "under a minute"
        case ..<120: return "a minute"
        case ..<3600: return "\(Int(seconds / 60)) minutes"
        default:
            let hours = Int(seconds / 3600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
    }
}

/// What the last call was about, kept so the next one does not have to remember.
///
/// The appliance asked the model what they had last been working on, and the
/// model answered from memory — which is retrieved by relevance, not by time.
/// Live, that produced "last we talked, you were heading to bed" on an evening
/// whose actual last exchange had been about tonkatsu shops. Both were in
/// memory; "goodnight" is simply a more distinctive thing to recall than a
/// restaurant search, and nothing in the question said which was more recent.
///
/// So this is a fact the appliance carries rather than a question it asks. It
/// held the transcript already; it just threw it away.
///
/// On disk because a daemon restart is routine — an update, a crash, a Mac that
/// slept — and "what did we just talk about" surviving only until the next
/// restart is the same bug wearing a different hat.
public struct LastCall: Sendable, Codable, Equatable {
    public var ended: Date
    /// The tail of the conversation, not the whole thing. What matters to the
    /// next call is where the last one got to, and a full transcript would push
    /// the rest of the briefing out of a small model's attention.
    public var closing: String

    public init(ended: Date, closing: String) {
        self.ended = ended
        self.closing = closing
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("last-call.json", isDirectory: false)
    }

    public static func load(from url: URL = LastCall.defaultFileURL()) -> LastCall? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LastCall.self, from: data)
    }

    public func save(to url: URL = LastCall.defaultFileURL()) throws {
        try OwnerOnlyFileSecurity.write(try JSONEncoder().encode(self), to: url)
    }

    /// Builds a record from a finished call.
    ///
    /// Returns nothing when the owner never spoke: a call they joined and left
    /// is not something the next one should open by referring to.
    public static func from(_ transcript: CallTranscript, characters: Int = 700) -> LastCall? {
        guard transcript.lines.contains(where: { $0.speaker == .owner }) else { return nil }

        var closing = ""
        for line in transcript.lines.reversed() {
            let speaker = line.speaker == .owner ? "They said" : "I said"
            let piece = "\(speaker): \(line.text)\n"
            if closing.count + piece.count > characters { break }
            closing = piece + closing
        }
        return LastCall(ended: Date(), closing: closing.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
