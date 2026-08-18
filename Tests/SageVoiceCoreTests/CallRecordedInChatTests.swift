// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **That a call ends up in the conversation, not just in Signal.**
///
/// The owner: *"chat is not syncing - like we dont get the summary after a voice
/// call in the app"*. His phone showed two calls at 20:23; the Mac window went
/// straight from 19:11 to 22:10 as though they had not happened.
///
/// The cause was a missing half. A text turn appends to `histories[key]` and
/// calls `persistConversations()`; a call transcript called `reply` and nothing
/// else, so it reached Signal and never reached `conversations.json` — which is
/// the file the window mirrors. It could not appear because it was never
/// written.
///
/// The louder symptom was the window. The quieter one mattered more: **the model
/// never saw the call either**, so a written follow-up to something discussed
/// aloud met an appliance with no memory of the conversation it had just had.
final class CallRecordedInChatTests: XCTestCase {

    private let limit = 16

    // MARK: What gets recorded

    func testAFinishedCallIsAppendedToTheThread() {
        let summary = "Call — under a minute\n\nYou: What's on the task list?\n\nMynah: Nothing."

        let history = VoiceBridgeDaemon.history(
            includingCall: summary,
            appendedTo: [BrainMessage(role: .user, content: "earlier question")],
            keepingLastTurns: limit
        )

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.last?.role, .assistant)
        XCTAssertEqual(history.last?.content, summary)
    }

    /// One assistant turn, not reconstructed user/assistant pairs. Splitting the
    /// transcript back into roles would file words as the owner's that the
    /// *recogniser* chose — and a misheard sentence attributed to him is worse
    /// than an accurate record of a conversation.
    func testTheCallIsOneTurnRatherThanReconstructedRoles() {
        let summary = "Call — under a minute\n\nYou: Do you see any agents?\n\nMynah: No."

        let history = VoiceBridgeDaemon.history(
            includingCall: summary, appendedTo: [], keepingLastTurns: limit
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.role, .assistant)
        XCTAssertFalse(
            history.contains { $0.role == .user },
            "the recogniser's words were filed as the owner's"
        )
    }

    /// Two calls in a row both land. The owner's screenshot had exactly this —
    /// two "Call — under a minute" blocks back to back — and a record keyed on
    /// anything but arrival order would have kept one.
    func testTwoCallsInARowAreBothKept() {
        var history: [BrainMessage] = []
        for text in ["Call — under a minute\n\nYou: One", "Call — under a minute\n\nYou: Two"] {
            history = VoiceBridgeDaemon.history(
                includingCall: text, appendedTo: history, keepingLastTurns: limit
            )
        }

        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history[0].content.contains("One"))
        XCTAssertTrue(history[1].content.contains("Two"))
    }

    /// A call nobody spoke on produces no message, and no message leaves no
    /// trace — matching `CallTranscript.message` returning nil for the same
    /// case. An empty assistant turn would be a blank bubble in the window.
    func testACallWithNothingSaidLeavesNoTrace() {
        let before = [BrainMessage(role: .user, content: "something")]

        XCTAssertEqual(
            VoiceBridgeDaemon.history(includingCall: "", appendedTo: before, keepingLastTurns: limit),
            before
        )
        XCTAssertEqual(
            VoiceBridgeDaemon.history(
                includingCall: "   \n  ", appendedTo: before, keepingLastTurns: limit
            ),
            before
        )
    }

    /// Trimmed like every other turn, so a long call cannot push the thread past
    /// the limit the rest of the daemon maintains.
    func testALongCallIsTrimmedLikeAnyOtherTurn() {
        var history: [BrainMessage] = []
        for index in 0..<20 {
            history.append(BrainMessage(role: .user, content: "question \(index)"))
            history.append(BrainMessage(role: .assistant, content: "answer \(index)"))
        }

        let after = VoiceBridgeDaemon.history(
            includingCall: "Call — 3 minutes\n\nYou: Hello", appendedTo: history, keepingLastTurns: 4
        )

        XCTAssertLessThan(after.count, history.count)
        XCTAssertEqual(after.last?.content, "Call — 3 minutes\n\nYou: Hello")
    }

    // MARK: What the window then shows

    /// The other half of the round trip: once the call is in the store, the
    /// window draws it. Mirrors the store rather than mocking it, because the
    /// bug was precisely that these two halves were not connected.
    @MainActor
    func testARecordedCallIsDrawnInTheWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("call-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let summary = "Call — under a minute\n\nYou: What's on the task list?\n\nMynah: Nothing."

        try store.save([
            "+60123821767": VoiceBridgeDaemon.history(
                includingCall: summary,
                appendedTo: [
                    BrainMessage(role: .user, content: "are you online?"),
                    BrainMessage(role: .assistant, content: "Yes.")
                ],
                keepingLastTurns: limit
            )
        ])

        let reloaded = store.load()["+60123821767"] ?? []
        XCTAssertEqual(reloaded.count, 3, "the call did not survive the round trip to disk")
        XCTAssertEqual(reloaded.last?.content, summary)
        XCTAssertEqual(reloaded.last?.role, .assistant)
    }
}
#endif  // os(macOS)
