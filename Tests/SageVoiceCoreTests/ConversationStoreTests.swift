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

    // MARK: Found by review

    /// `savedAt` was one stamp for the whole file, and the daemon persists every
    /// history on every turn — so one active conversation kept every other one
    /// alive. A three-day-old thread survived the six-hour expiry because a
    /// different thread said hello.
    func testAnIdleThreadIsNotKeptAliveByAnActiveOne() throws {
        let now = Date()
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)

        try store.save(["+A": [.user("shops in Chiang Mai"), .assistant("here they are")]], now: threeDaysAgo)

        var histories = store.load(now: threeDaysAgo.addingTimeInterval(60))
        histories["+B"] = [.user("hello"), .assistant("hi")]
        try store.save(histories, now: now)

        let restored = store.load(now: now)
        XCTAssertNil(restored["+A"], "a three-day-old thread was refreshed by another thread's turn")
        XCTAssertEqual(restored["+B"]?.count, 2, "the active thread should still be there")
    }

    /// Re-saving an unchanged conversation is not the owner speaking, so it must
    /// not restart that conversation's clock.
    func testResavingUnchangedContentDoesNotRestartTheClock() throws {
        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 60 * 60)
        let turns: [BrainMessage] = [.user("shops in Tokyo"), .assistant("Clockface Modular.")]

        try store.save([thread: turns], now: fiveHoursAgo)
        try store.save([thread: turns], now: now)

        XCTAssertNil(
            store.load(now: fiveHoursAgo.addingTimeInterval(ConversationStore.maximumAge + 60))[thread],
            "an unchanged thread had its expiry pushed forward by a routine save"
        )
    }

    /// "Expires after six hours" was a read-time filter only. The owner's
    /// plaintext stayed on disk indefinitely — a 48-hour-old file loaded as empty
    /// while still containing what they had said.
    func testExpiryActuallyRemovesTheWords() throws {
        try store.save(
            [thread: [.user("my landlord's bank details are 1234"), .assistant("noted")]],
            now: Date().addingTimeInterval(-48 * 60 * 60)
        )

        XCTAssertTrue(store.load(now: Date()).isEmpty)

        let file = directory.appendingPathComponent("conversations.json")
        let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("landlord"), "expired plaintext is still on disk")
    }

    /// `conversationOnly` drops tool results, but `SourceLinks` lifts their URLs
    /// onto the assistant turn — and a URL is frequently the secret itself.
    /// Persisting a booking link recalled from SAGE is the leak this file is
    /// documented not to have.
    func testURLsHarvestedFromToolResultsAreNotPersisted() throws {
        let carried = VoiceBridgeDaemon.conversationOnly([
            .user("what did we say about the villa"),
            .toolResult(
                name: "sage_recall",
                content: "villa booking https://private.example.com/booking/SECRET-TOKEN-123",
                id: "1"
            ),
            .assistant("You booked it in March.")
        ])
        // The live conversation still carries them — that is the feature.
        XCTAssertTrue(carried.last?.content.contains("SECRET-TOKEN-123") == true)

        try store.save([thread: carried])
        let raw = try String(contentsOf: directory.appendingPathComponent("conversations.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("SECRET-TOKEN-123"), "a tool-result URL reached the disk")
        XCTAssertTrue(
            store.load()[thread]?.last?.content.contains("You booked it in March") == true,
            "stripping the sources line ate the answer"
        )
    }

    /// A file written by the previous version has no per-thread stamps. It must
    /// still load, and its threads must expire on the file's age rather than be
    /// treated as brand new.
    func testAFileFromThePreviousVersionStillLoadsAndStillExpires() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("conversations.json")

        func writeLegacy(ageInHours: Double) throws {
            let savedAt = Date().addingTimeInterval(-ageInHours * 60 * 60)
            let payload: [String: Any] = [
                "savedAt": savedAt.timeIntervalSinceReferenceDate,
                "threads": [thread: [["role": "user", "content": "legacy turn"]]]
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: file)
        }

        try writeLegacy(ageInHours: 1)
        XCTAssertEqual(store.load()[thread]?.first?.content, "legacy turn", "an upgrade lost the conversation")

        try writeLegacy(ageInHours: 48)
        XCTAssertTrue(store.load().isEmpty, "a legacy file was treated as new rather than expired")
    }
}
