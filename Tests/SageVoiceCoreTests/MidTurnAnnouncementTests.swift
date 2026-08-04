import XCTest
@testable import SageVoiceCore

/// What lands while a turn is suspended must survive the turn finishing.
///
/// ## The bug
///
/// `histories[key]` was **assigned** from a value derived only from the snapshot
/// the turn started with:
///
///     let priorTurns = histories[key] ?? []          // before the await
///     …six minutes of suspension…
///     histories[key] = trimmed(conversationOnly(result.messages), …)
///     persistConversations()
///
/// `VoiceBridgeDaemon` is an actor, so it accepts other work across that await,
/// and two things take it: `announce`, driven by the proactive watch every sixty
/// seconds, and `recordFromCall`. Both append to the same key. Anything either
/// added was overwritten, and then written to disk.
///
/// From the owner's side: Mynah tells him on Signal that a task came off the
/// list, he says "yes, do that", and it has no idea what "that" was — because
/// the message it sent him is no longer in the history it answers from. The
/// window shows the same gap.
///
/// The six-minute turn ceiling added in 1.5.4 made this window six times wider
/// than it had been. The `run` loop already closes the identical hazard between
/// message turns, and its comment names it — so it was seen once and closed for
/// one path only.
final class MidTurnAnnouncementTests: XCTestCase {

    private func user(_ text: String) -> BrainMessage { .user(text) }
    private func assistant(_ text: String) -> BrainMessage { BrainMessage(role: .assistant, content: text) }

    /// What the loop hands back: the prior turns it was given, then its own.
    private func loopMessages(prior: [BrainMessage], asked: String, answered: String) -> [BrainMessage] {
        [.system("you are SAGE")] + prior + [user(asked), assistant(answered)]
    }

    // MARK: The bug

    /// **The regression test.** An announcement lands while the turn is
    /// suspended; when the turn finishes, the announcement is still there.
    func testAnAnnouncementThatLandsMidTurnSurvivesTheTurn() {
        let priorTurns = [user("what's on my list"), assistant("Four things.")]

        // While the turn is suspended, the proactive watch says something.
        let announcement = assistant("“Call with TII IT” came off the list.")
        let current = priorTurns + [announcement]

        let merged = VoiceBridgeDaemon.history(
            current,
            after: loopMessages(prior: priorTurns, asked: "make me a pdf", answered: "On its way."),
            startingFrom: priorTurns,
            keepingLastTurns: 16
        )

        XCTAssertTrue(
            merged.contains(where: { $0.content.contains("came off the list") }),
            "the appliance forgot something it had already said to him: \(merged.map(\.content))"
        )
    }

    /// And the turn's own work is still there — a merge that kept the
    /// announcement by dropping the answer would be the same bug wearing a
    /// different hat.
    func testTheTurnsOwnQuestionAndAnswerAreKept() {
        let priorTurns = [user("what's on my list"), assistant("Four things.")]
        let current = priorTurns + [assistant("Something came off the list.")]

        let merged = VoiceBridgeDaemon.history(
            current,
            after: loopMessages(prior: priorTurns, asked: "make me a pdf", answered: "On its way."),
            startingFrom: priorTurns,
            keepingLastTurns: 16
        )

        XCTAssertTrue(merged.contains { $0.content == "make me a pdf" }, "\(merged.map(\.content))")
        XCTAssertTrue(merged.contains { $0.content == "On its way." }, "\(merged.map(\.content))")
    }

    /// The ordinary case — nothing landed — must be unchanged. This is every
    /// turn the appliance has ever run, and a merge that duplicated the prior
    /// turns would double the transcript on each one.
    func testAQuietTurnProducesExactlyWhatItAlwaysDid() {
        let priorTurns = [user("what's on my list"), assistant("Four things.")]
        let result = loopMessages(prior: priorTurns, asked: "make me a pdf", answered: "On its way.")

        let merged = VoiceBridgeDaemon.history(
            priorTurns,
            after: result,
            startingFrom: priorTurns,
            keepingLastTurns: 16
        )

        XCTAssertEqual(
            merged.map(\.content),
            VoiceBridgeDaemon.trimmed(
                VoiceBridgeDaemon.conversationOnly(result),
                keepingLastTurns: 16
            ).map(\.content),
            "a quiet turn must produce the same history the old assignment did"
        )
    }

    /// Two announcements in one window, which is reachable: the watch ticks
    /// every sixty seconds and the ceiling is three hundred and sixty.
    func testEverythingThatLandedSurvivesNotJustTheLastOne() {
        let priorTurns = [user("morning")]
        let current = priorTurns + [
            assistant("Dentist at 1pm."),
            assistant("Credence call at 11.")
        ]

        let merged = VoiceBridgeDaemon.history(
            current,
            after: loopMessages(prior: priorTurns, asked: "and the pdf?", answered: "Sending."),
            startingFrom: priorTurns,
            keepingLastTurns: 16
        )

        XCTAssertTrue(merged.contains { $0.content == "Dentist at 1pm." }, "\(merged.map(\.content))")
        XCTAssertTrue(merged.contains { $0.content == "Credence call at 11." }, "\(merged.map(\.content))")
    }

    // MARK: Shapes that must not crash or lose the answer

    /// The prefix is intact in practice — the loop replays history verbatim and
    /// `priorTurns` is already conversation-only. If that ever stops being true,
    /// the honest failure is a duplicated turn, not a lost answer.
    func testAShorterResultThanTheSnapshotStillKeepsTheAnswer() {
        let priorTurns = [user("a"), assistant("b"), user("c"), assistant("d")]

        let merged = VoiceBridgeDaemon.history(
            priorTurns,
            after: [.system("s"), user("only this"), assistant("and this")],
            startingFrom: priorTurns,
            keepingLastTurns: 16
        )

        XCTAssertTrue(merged.contains { $0.content == "and this" }, "the answer was dropped")
    }

    /// An empty thread is the first message anybody ever sends.
    func testAFirstEverTurnWorks() {
        let merged = VoiceBridgeDaemon.history(
            [],
            after: loopMessages(prior: [], asked: "hello", answered: "Hey, I'm here."),
            startingFrom: [],
            keepingLastTurns: 16
        )

        XCTAssertEqual(merged.map(\.content), ["hello", "Hey, I'm here."])
    }

    /// The limit still applies to the merged whole, or a thread that took an
    /// announcement every minute would grow without bound.
    ///
    /// Counted in *questions*, because that is what `trimmed` counts: it keeps
    /// everything from the Nth-from-last user message onward. An announcement is
    /// an assistant message with no question in front of it, so it rides along
    /// inside whichever turn it landed in rather than costing one — which is
    /// right. "A task came off the list" is not a turn the owner took.
    func testTheTrimStillAppliesAfterMerging() {
        let priorTurns = (0..<10).flatMap { [user("q\($0)"), assistant("a\($0)")] }
        let current = priorTurns + (0..<6).map { assistant("landed \($0)") }

        let merged = VoiceBridgeDaemon.history(
            current,
            after: loopMessages(prior: priorTurns, asked: "one more", answered: "done"),
            startingFrom: priorTurns,
            keepingLastTurns: 4
        )

        XCTAssertEqual(
            merged.filter { $0.role == .user }.count, 4,
            "the merge must be trimmed by the same rule as the assignment it replaced"
        )
        XCTAssertEqual(merged.last?.content, "done", "the newest thing must always survive")
    }
}
