import XCTest
@testable import SageVoiceCore

final class CallTranscriptTests: XCTestCase {

    func testACallBecomesAReadableRecord() {
        var transcript = CallTranscript(started: Date().addingTimeInterval(-185))
        transcript.said("Morning Dhillon. One thing open: the A100 benchmarks before Friday.")
        transcript.heard("Can you check the Eurorack list?")
        transcript.said("Nothing on it yet. Want me to start one?")

        let message = transcript.message()
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.hasPrefix("Call — 3 minutes"), message!)
        XCTAssertTrue(message!.contains("You: Can you check the Eurorack list?"))
        XCTAssertTrue(message!.contains("Mynah: Nothing on it yet."))
    }

    /// A call nobody spoke on must not post anything.
    ///
    /// A link tapped by accident still produces a greeting, and a thread message
    /// announcing that the appliance said hello to nobody is noise.
    func testACallWhereNobodySpokePostsNothing() {
        var transcript = CallTranscript()
        transcript.said("Hey, I'm here.")
        XCTAssertNil(transcript.message())

        XCTAssertNil(CallTranscript().message())
    }

    func testEmptyAndWhitespaceLinesAreDropped() {
        var transcript = CallTranscript()
        transcript.heard("   ")
        transcript.said("")
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertNil(transcript.message())
    }

    func testLengthReadsTheWaySomeoneWouldSayIt() {
        XCTAssertEqual(CallTranscript.length(20), "under a minute")
        XCTAssertEqual(CallTranscript.length(90), "a minute")
        XCTAssertEqual(CallTranscript.length(600), "10 minutes")
        XCTAssertEqual(CallTranscript.length(3600), "1h")
        XCTAssertEqual(CallTranscript.length(5400), "1h 30m")
    }

    /// Defaults to on: a call that leaves no trace is the surprising behaviour,
    /// not the safe one.
    func testTranscriptsAreOnUnlessTurnedOff() {
        let defaults = UserDefaults(suiteName: "transcript-test-\(UUID().uuidString)")!
        XCTAssertTrue(TranscriptPreference(defaults: defaults).isEnabled)

        defaults.set(false, forKey: TranscriptPreference.key)
        XCTAssertFalse(TranscriptPreference(defaults: defaults).isEnabled)

        defaults.set(true, forKey: TranscriptPreference.key)
        XCTAssertTrue(TranscriptPreference(defaults: defaults).isEnabled)
    }
}
