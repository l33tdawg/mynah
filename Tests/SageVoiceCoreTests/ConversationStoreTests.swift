import XCTest
@testable import SageVoiceCore

/// Conversation history across a restart.
///
/// The reported failure, in the owner's words: "restart lost the context". They
/// were mid-conversation about shops near the KL Convention Centre, the daemon
/// was restarted for a deploy, and "can you give me the names of the shops and
/// their google maps link please" came back as "Could you clarify which shops?".
/// Every fact was in the process that had just exited.
final class ConversationStoreTests: XCTestCase {

    private var directory: URL!
    private var store: ConversationStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conversation-store-\(UUID().uuidString)", isDirectory: true)
        store = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let thread = "+60123821767"

    // MARK: The reported failure

    func testTheConversationSurvivesARestart() throws {
        try store.save([
            thread: [
                .user("i am going to the kl convention center later today, see if there's a Hugo Boss shop nearby"),
                .assistant("Your nearest options are Suria KLCC or Bukit Bintang mall.")
            ]
        ])

        // A new instance is what the next process gets.
        let afterRestart = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let restored = afterRestart.load()

        XCTAssertEqual(restored[thread]?.count, 2)
        XCTAssertTrue(
            restored[thread]?.last?.content.contains("Suria KLCC") == true,
            "the answer the owner's follow-up refers to did not come back"
        )
        XCTAssertEqual(restored[thread]?.first?.role, .user)
        XCTAssertEqual(restored[thread]?.last?.role, .assistant)
    }

    // MARK: What must not be written

    /// Tool results are dropped from history for a measured reason — a model
    /// that can see last turn's memory dump stops calling tools and recycles it.
    /// Persisting them would reintroduce that bug *and* put a SAGE memory dump
    /// on disk.
    func testToolResultsAndSystemPromptsAreNeverPersisted() throws {
        try store.save([
            thread: [
                .system("you are SAGE"),
                .user("whats on my backlog"),
                .toolResult(name: "sage_backlog", content: "Task 41: rotate the Gemini key", id: "1"),
                .assistant("Two things.")
            ]
        ])

        let restored = store.load()
        let joined = (restored[thread] ?? []).map(\.content).joined(separator: " ")
        XCTAssertFalse(joined.contains("Task 41"), "a tool result was written to disk")
        XCTAssertFalse(joined.contains("you are SAGE"), "the system prompt was persisted into history")
        XCTAssertEqual(restored[thread]?.count, 2)

        let raw = try String(contentsOf: directory.appendingPathComponent("conversations.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("Task 41"), "the tool result reached the file even if not the reload")
    }

    /// The file holds the owner's own words, so it gets the same treatment as
    /// their provider keys and their notes.
    func testTheFileIsOwnerOnly() throws {
        try store.save([thread: [.user("something private"), .assistant("noted")]])

        let file = directory.appendingPathComponent("conversations.json")
        let filePerms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let dirPerms = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePerms, 0o600)
        XCTAssertEqual(dirPerms, 0o700)
    }

    // MARK: Expiry

    /// SAGE is the long-term memory; this is short-term working context.
    /// Silently resuming yesterday's subject is how the appliance produced its
    /// worst bug — Chiang Mai shops mixed into a question about Tokyo.
    func testYesterdaysConversationIsNotResumed() throws {
        let now = Date()
        try store.save([thread: [.user("shops in Chiang Mai"), .assistant("Siam Modular.")]], now: now)

        let justInside = store.load(now: now.addingTimeInterval(ConversationStore.maximumAge - 60))
        XCTAssertEqual(justInside[thread]?.count, 2, "a deploy an hour ago should still resume")

        let nextMorning = store.load(now: now.addingTimeInterval(ConversationStore.maximumAge + 60))
        XCTAssertTrue(nextMorning.isEmpty, "\"morning mate\" resumed yesterday's subject")
    }

    func testTheWindowCoversADeployButNotTheNight() {
        XCTAssertGreaterThanOrEqual(ConversationStore.maximumAge, 60 * 60)
        XCTAssertLessThanOrEqual(ConversationStore.maximumAge, 12 * 60 * 60)
    }

    // MARK: Robustness

    /// A cache file that will not parse is worth one fresh start, not an outage.
    /// The daemon has to boot.
    func testACorruptFileIsNotFatal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: directory.appendingPathComponent("conversations.json"))
        XCTAssertTrue(store.load().isEmpty)
    }

    func testNoFileAtAllIsNotFatal() {
        XCTAssertTrue(store.load().isEmpty)
    }

    /// Threads stay separate on disk for the same reason they are separate in
    /// memory: one owner's words must not surface in another's turn.
    func testThreadsStaySeparate() throws {
        try store.save([
            "+60123821767": [.user("mine"), .assistant("yours")],
            "+15550000000": [.user("theirs"), .assistant("ok")]
        ])
        let restored = store.load()
        XCTAssertEqual(restored["+60123821767"]?.first?.content, "mine")
        XCTAssertEqual(restored["+15550000000"]?.first?.content, "theirs")
    }

    func testHistoryIsTrimmedOnDiskToo() throws {
        let long = (0..<60).map { BrainMessage.user("turn \($0)") }
        try store.save([thread: long])
        XCTAssertEqual(store.load()[thread]?.count, ConversationStore.maximumTurnsPerThread)
        XCTAssertEqual(
            store.load()[thread]?.last?.content,
            "turn 59",
            "trimming kept the oldest turns instead of the most recent"
        )
    }

    /// An empty history removes the file rather than leaving a stale one that a
    /// later boot would resume.
    func testClearingHistoryRemovesTheFile() throws {
        try store.save([thread: [.user("hello"), .assistant("hi")]])
        try store.save([:])
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversations.json").path)
        )
    }
}
