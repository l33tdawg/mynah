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
