import Foundation

/// Decides whether "still working" should be said at all.
///
/// **The appliance stays quiet for the first couple of seconds of every turn.**
/// Against a cloud brain a whole turn is often over inside three, and "On it."
/// followed a second later by the answer is two notifications where one would
/// do — *"the time to reply is quite fast, so don't send back the 'on it' /
/// internal messages esp on text"*. Against a local model, or on any turn that
/// reaches for a tool, the wait is long enough that silence reads as broken and
/// the line earns its place.
///
/// So this is a race against the answer rather than a judgement about the
/// brain. Whichever gets there first wins, which means there is nothing to
/// configure and nothing to get wrong on a machine whose speed changes between
/// turns — and every machine's does, since a cold prompt cache and a warm one
/// differ by an order of magnitude.
///
/// A value type with no clock and no socket in it, because the alternative is a
/// rule that only exists inside an actor that needs a Signal connection to
/// build. `VoiceBridgeDaemon` owns the timer and does the sending; everything
/// that can be got wrong is here, where a test can reach it.
struct WorkingLineGate {

    enum Decision: Equatable {
        /// Send it now.
        case say
        /// Keep it. It goes out only if the turn is still running when the
        /// quiet period ends.
        case hold
        /// Say nothing — the owner has already been answered, or this is the
        /// same news as the last line.
        case drop
    }

    private struct Held {
        let text: String
        let isArrivalOpener: Bool
    }

    private var held: Held?
    private var isQuiet = true

    /// True between the answer going out and the next turn starting.
    private(set) var isAnswered = true

    /// Whether a *specific* opener has actually been said this turn.
    ///
    /// Said, not decided, and the distinction is new. It used to be set the
    /// moment an opener was chosen, which was the same thing until lines
    /// started being held — now an opener can be decided and never leave the
    /// Mac, and suppressing the tool-decision line behind one nobody heard
    /// would leave a slow turn completely silent.
    private(set) var saidArrivalOpener = false

    mutating func beginTurn() {
        held = nil
        isQuiet = true
        isAnswered = false
        saidArrivalOpener = false
    }

    /// Offers a line.
    ///
    /// - Parameter previous: the last thing said on this thread, so two ways of
    ///   phrasing one piece of news do not both go out.
    mutating func offer(
        _ line: String,
        isArrivalOpener: Bool = false,
        previous: String?
    ) -> Decision {
        guard !isAnswered else { return .drop }
        // Against whatever would otherwise be said next: a line still waiting
        // its turn counts as much as one already sent, or the opener and the
        // tool line both go out saying the same thing two seconds apart.
        guard !WorkingReply.saysTheSameThing(line, as: held?.text ?? previous) else {
            return .drop
        }
        guard !isQuiet else {
            // The newest wins. If the tool decision arrives while the opener is
            // still held, "Looking that up online" is better news than "On it"
            // and there is no reason to say both.
            held = Held(text: line, isArrivalOpener: isArrivalOpener)
            return .hold
        }
        if isArrivalOpener { saidArrivalOpener = true }
        return .say
    }

    /// The turn is taking a while after all.
    ///
    /// - Returns: the line to say now, or `nil` if nothing was held or the
    ///   answer got there first.
    mutating func quietPeriodEnded() -> String? {
        isQuiet = false
        guard !isAnswered, let held else { return nil }
        self.held = nil
        if held.isArrivalOpener { saidArrivalOpener = true }
        return held.text
    }

    /// The owner has been answered. Anything a tool loop is still trying to say
    /// after this is not news, it is an echo.
    mutating func answered() {
        isAnswered = true
        held = nil
    }
}
