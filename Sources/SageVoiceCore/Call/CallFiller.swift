import Foundation

/// What to say into the gap while the model works, and when.
///
/// **The silence is the problem, and one sentence at eight seconds was not
/// enough of an answer to it.** The owner: *"there are long silences instead of
/// more natural umhs and ahs like how chatgpt voice full duplex does it."*
///
/// On a call there is nothing else to look at. A Signal thread at least shows
/// the message was delivered; a silent line is indistinguishable from a dropped
/// one, and the caller starts saying "hello?" into it. The appliance had an
/// opener at zero seconds and one line at eight, and then nothing for however
/// long a tool call takes — which on a local model with a web search is often
/// thirty seconds.
///
/// ## Why these are sounds rather than sentences
///
/// A person filling a gap does not say "I am still working on it" three times.
/// They say "mm", "right", "bear with me" — short, low-content, and *different
/// each time*. Length is what makes filler grating: a sentence claims a turn
/// and asks to be listened to, where "mm" costs the listener nothing. So the
/// first two are near-wordless and only the later ones say anything, by which
/// point the caller genuinely does deserve to be told this is slow.
///
/// ## Why it escalates and then stops
///
/// Four is the cap. Past that the appliance is not reassuring anybody, it is
/// performing, and a caller who has heard five "nearly there"s knows precisely
/// as much as one who heard two — while the fifth is what makes them hang up.
/// After the cap it goes quiet and lets the answer arrive.
struct CallFiller {

    /// How long after the opener before the first filler.
    ///
    /// Six seconds, because the opener itself buys a few and a gap under about
    /// five reads as the appliance interrupting its own sentence. Measured
    /// against nothing — this is taste, and the owner is the one who hears it.
    static let firstAfter: TimeInterval = 6

    /// Roughly the gap between fillers after the first.
    ///
    /// Not exact: a sound arriving on a metronome is the one thing that would
    /// make this read as a machine rather than as somebody thinking. The jitter
    /// is deterministic per position rather than random, so a turn sounds the
    /// same each time it is replayed in a test.
    static let thenEvery: TimeInterval = 7

    static let mostInOneTurn = 4

    /// The pools, in the order they are used.
    ///
    /// Escalating: two that say nothing, then two that admit it is slow. Each
    /// pool has alternatives so two turns in a row do not sound identical, and
    /// nothing in a later pool appears in an earlier one — hearing "nearly
    /// there" as the *first* thing after a question would be a claim the
    /// appliance cannot make yet.
    ///
    /// **And nothing here may appear in `WaitingPhrases` either.** Rung one used
    /// to hold "Bear with me." and "One moment.", both of which are openers —
    /// and `bridge.log` shows the call opener really did say "One moment." on
    /// this Mac, four times. A caller could hear the same three words as the
    /// greeting and again six seconds later, which is a stutter that reads as a
    /// stuck machine: the impression this whole ladder exists to prevent.
    ///
    /// The register is the tell. An opener says *I am beginning*; a line at six
    /// seconds has to say *I am still here*, and the two are not interchangeable
    /// even when the words could be. Guarded by
    /// `FillerAndOpenerPoolsAreDisjointTests`, which matters for a second reason
    /// — pool membership is the only way the suite can tell a filler from an
    /// opener, so a collision lets an opener satisfy the check that exists to
    /// prove the ladder ran.
    static let pools: [[String]] = [
        ["Mm.", "Right.", "Okay…"],
        ["Hmm…", "Let me think.", "Just a moment more."],
        ["Still going.", "Nearly there.", "Almost."],
        ["Sorry — this one's slow.", "Still on it, nearly done."]
    ]

    /// How long to wait before the filler at `position` (0-based).
    static func delay(before position: Int) -> TimeInterval {
        guard position > 0 else { return firstAfter }
        // A second either side, alternating, so the cadence breathes.
        return thenEvery + (position.isMultiple(of: 2) ? 1 : -1)
    }

    /// The line for a position, avoiding whatever was said last.
    ///
    /// Returns `nil` past the cap, which is the signal to stop the loop rather
    /// than to say something duller.
    static func line(
        at position: Int,
        previous: String?,
        chooser: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> String? {
        guard position >= 0, position < mostInOneTurn, position < pools.count else { return nil }
        let pool = pools[position]
        let fresh = pool.filter { $0 != previous }
        let options = fresh.isEmpty ? pool : fresh
        return options[min(max(chooser(options.count), 0), options.count - 1)]
    }
}
