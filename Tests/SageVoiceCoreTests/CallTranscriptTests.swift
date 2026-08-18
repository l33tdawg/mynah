// **Mac-only, because the live voice call is a Mac feature.**
//
// `Sources/SageVoiceCore/Call` is excluded from the target off Darwin — see
// `coreExclusions` in Package.swift — so none of the types below exist there.
// The exclusion and this guard are two halves of one decision, and the tests
// have to carry their half explicitly: a test file that cannot compile does not
// fail loudly, it takes the whole target down with it and every other test in
// the suite stops running too. That is what happened here.
#if os(macOS)
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
    ///
    /// Against the shared file rather than UserDefaults, because that is the
    /// only store both processes can see. A preference the app writes to its own
    /// defaults domain is one the daemon never reads — the control moves, the
    /// value is saved, and nothing changes.
    func testTranscriptsAreOnUnlessTurnedOff() throws {
        // A directory of its own: writing hardens the containing directory to
        // owner-only, which cannot be done to the shared temp directory.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("call-preferences.json")

        XCTAssertTrue(CallPreferences.load(from: file).transcript, "unset should read as on")

        try CallPreferences(transcript: false).save(to: file)
        XCTAssertFalse(CallPreferences.load(from: file).transcript)

        try CallPreferences(transcript: true).save(to: file)
        XCTAssertTrue(CallPreferences.load(from: file).transcript)
    }

    /// A speaking rate outside the usable range must not survive being read.
    ///
    /// The file is editable by hand, and a voice at 0.2 or 5.0 is one the owner
    /// cannot understand and may not connect to the control that caused it.
    func testTheSpeakingRateIsClamped() {
        XCTAssertEqual(CallPreferences(speed: 9).clampedSpeed, CallPreferences.fastest)
        XCTAssertEqual(CallPreferences(speed: 0.1).clampedSpeed, CallPreferences.slowest)
        XCTAssertEqual(CallPreferences(speed: 1.15).clampedSpeed, 1.15)
    }

    /// The voice and rate must survive a round trip, or the Settings screen is
    /// writing somewhere nothing reads.
    func testChoicesSurviveARoundTrip() throws {
        // A directory of its own: writing hardens the containing directory to
        // owner-only, which cannot be done to the shared temp directory.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("call-preferences.json")

        try CallPreferences(voice: "bm_george", speed: 1.3, transcript: false).save(to: file)
        let loaded = CallPreferences.load(from: file)
        XCTAssertEqual(loaded.voice, "bm_george")
        XCTAssertEqual(loaded.speed, 1.3)
        XCTAssertFalse(loaded.transcript)
    }

}
#endif  // os(macOS)
