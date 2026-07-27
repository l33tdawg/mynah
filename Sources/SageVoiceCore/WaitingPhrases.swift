import Foundation

/// What the appliance says while it is thinking.
///
/// A turn takes ~23 seconds warm and can reach a minute on a cold cache. In a
/// messaging thread that silence reads as "it's broken", so something has to
/// land immediately — but the same three dots every time reads as a canned
/// robot, which is worse than nothing once you have seen it twice.
///
/// So: a hundred of them, and an honest estimate of how long this will take
/// based on what recent turns actually took, not a number someone made up.
public enum WaitingPhrases {

    /// Deliberately plain. This is an appliance the owner talks to daily, and
    /// jokes that are funny once are irritating by the fortieth time — so these
    /// aim for varied and warm rather than clever.
    public static let all: [String] = [
        "On it.",
        "Working on that now.",
        "Let me look.",
        "Checking.",
        "Give me a moment.",
        "Looking into it.",
        "Right, let me find out.",
        "One moment.",
        "Having a look now.",
        "Let me check that for you.",
        "Sure — checking.",
        "Getting that now.",
        "Let me dig into it.",
        "Pulling that up.",
        "Just a sec.",
        "Looking that up.",
        "Let me see what I've got.",
        "Checking the network.",
        "Asking around.",
        "Let me go and look.",
        "On the case.",
        "Getting you an answer.",
        "Let me work that out.",
        "Checking now.",
        "Give me a second.",
        "Looking.",
        "Let me find that.",
        "I'll go and check.",
        "Fetching that.",
        "Just checking something.",
        "Let me have a look at that.",
        "Working it out.",
        "Let me go through it.",
        "Coming right up.",
        "Getting into it.",
        "Let me take a look.",
        "Checking on that.",
        "I'm on it.",
        "Hang tight.",
        "Bear with me.",
        "Give me a tick.",
        "Let me sort that out.",
        "Looking through it now.",
        "Let me pull that together.",
        "Checking what I know.",
        "Going through it.",
        "Let me get that for you.",
        "Right — looking.",
        "Let me run that down.",
        "Just a moment.",
        "Searching.",
        "Let me go find it.",
        "Getting there.",
        "Let me check with the others.",
        "Reaching out.",
        "Let me query that.",
        "Digging in.",
        "Let me chase that up.",
        "Having a look.",
        "Let me confirm.",
        "Checking my memory.",
        "Let me go get it.",
        "Working through it.",
        "Give me a moment on that.",
        "Let me look that over.",
        "Getting the details.",
        "Let me review that.",
        "Checking the details.",
        "Let me find out for you.",
        "Just looking.",
        "Let me piece that together.",
        "On my way.",
        "Let me get into it.",
        "Checking things.",
        "Let me handle that.",
        "Sorting it now.",
        "Let me see.",
        "Taking a look.",
        "Let me trace that.",
        "Following that up.",
        "Let me look through my notes.",
        "Checking my notes.",
        "Let me go through the list.",
        "Pulling the details.",
        "Let me have a dig.",
        "Getting an answer for you.",
        "Let me look at what's there.",
        "Checking that out.",
        "Let me get to the bottom of it.",
        "Right, on it.",
        "Let me sort through it.",
        "Working that through.",
        "Let me go and find out.",
        "Checking in on that.",
        "Let me gather that.",
        "Just pulling it up.",
        "Let me get the picture.",
        "Looking into that now.",
        "Let me work through it.",
        "Getting that sorted.",
        "Let me go take a look."
    ]

    /// A phrase, plus an honest estimate when we have one.
    ///
    /// - Parameter estimatedSeconds: typical recent turn time. `nil` before any
    ///   turn has completed, in which case no estimate is offered rather than a
    ///   guess — being wrong about this is worse than being silent about it.
    public static func acknowledgement(estimatedSeconds: TimeInterval?) -> String {
        let phrase = all.randomElement() ?? "On it."
        guard let estimatedSeconds, let hint = durationHint(estimatedSeconds) else {
            return phrase
        }
        return "\(phrase) \(hint)"
    }

    /// Rounds to something a person would say.
    ///
    /// Deliberately coarse: "about 20 seconds" is useful, "23.4 seconds" is a
    /// machine talking, and a precise number invites the owner to notice it was
    /// wrong. Anything under ten seconds gets no hint at all — by the time they
    /// have read it, the answer has arrived.
    static func durationHint(_ seconds: TimeInterval) -> String? {
        switch seconds {
        case ..<10:
            return nil
        case ..<30:
            return "Should be about half a minute."
        case ..<75:
            return "This one takes about a minute."
        case ..<150:
            return "This'll take a couple of minutes."
        default:
            return "This one's slow — a few minutes."
        }
    }
}

/// Rolling estimate of how long a turn takes on this machine.
///
/// Measured rather than configured. The appliance's speed depends on the model,
/// the hardware and whether the prompt cache is warm — all of which change — so
/// a hardcoded number would be wrong on somebody else's Mac within a day.
struct TurnDurationEstimator {
    /// Small window on purpose: it should track a cold cache going warm within
    /// a couple of turns, not average it away over an hour.
    static let sampleLimit = 8

    private var samples: [TimeInterval] = []

    mutating func record(_ seconds: TimeInterval) {
        samples.append(seconds)
        if samples.count > Self.sampleLimit {
            samples.removeFirst(samples.count - Self.sampleLimit)
        }
    }

    /// Median, not mean: one 90-second outlier on a big recall should not make
    /// the appliance start promising minutes for every trivial question.
    var typicalSeconds: TimeInterval? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
