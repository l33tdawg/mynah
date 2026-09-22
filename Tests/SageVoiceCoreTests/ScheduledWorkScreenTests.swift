import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The Mac's Scheduled screen: the two controls that stop a poll, and the form
/// that starts one.
///
/// **The owner asked for this half in as many words** — *"so that way user can
/// go in and turn off tasks or kill those poll jobs"* — and the two controls are
/// deliberately different things. The switch holds (stop for now, keep the
/// wording, clock restarts when it comes back on); the cross kills (the request
/// and its wording are gone). A screen where both did the same thing would make
/// holding something for a fortnight mean deleting it.
///
/// These drive the model rather than the pixels: the rendering is checked by
/// `ScheduledWorkRenderHarness`, and what matters here is what each control does
/// to the file the daemon reads.
@MainActor
final class ScheduledWorkScreenTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-screen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var file: URL { scratch.appendingPathComponent("scheduled-work.json") }

    private func model(with tasks: [(String, ScheduleCadence)] = []) throws -> ScheduledWorkModel {
        var work = ScheduledWork()
        for (instruction, cadence) in tasks {
            _ = work.add(instruction: instruction, cadence: cadence)
        }
        if !work.tasks.isEmpty { try work.save(to: file) }
        return ScheduledWorkModel(fileURL: file)
    }

    // MARK: What the screen shows

    func testItShowsTheListTheDaemonReads() throws {
        let model = try model(with: [
            ("check my inbox", .daily(hour: 8, minute: 0)),
            ("send me the week ahead", .weekly(weekday: 2, hour: 9, minute: 30))
        ])

        XCTAssertEqual(model.work.numbered().map(\.number), [1, 2])
        XCTAssertEqual(model.work.numbered().map(\.task.instruction), [
            "check my inbox", "send me the week ahead"
        ])
    }

    /// The screen is a reader, not an owner: what the daemon (or the phone)
    /// wrote appears here without a restart.
    func testItPicksUpWhatThePhoneChanged() throws {
        let model = try model()
        XCTAssertTrue(model.work.tasks.isEmpty)

        var elsewhere = ScheduledWork()
        _ = elsewhere.add(instruction: "check my inbox", cadence: .daily(hour: 8, minute: 0))
        try elsewhere.save(to: file)

        model.reload()
        XCTAssertEqual(model.work.tasks.map(\.instruction), ["check my inbox"])
    }

    // MARK: Holding and killing

    func testTheSwitchHoldsItAndKeepsTheWording() throws {
        let model = try model(with: [("check my inbox", .daily(hour: 8, minute: 0))])

        model.setEnabled(false, number: 1)

        let kept = ScheduledWork.load(from: file)
        XCTAssertEqual(kept.tasks.count, 1, "holding it deleted it")
        XCTAssertEqual(kept.tasks.first?.isEnabled, false)
        XCTAssertEqual(model.work.tasks.first?.isEnabled, false)

        model.setEnabled(true, number: 1)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.first?.isEnabled, true)
    }

    /// Coming back on anchors the clock, so a request held for a fortnight does
    /// not come back by firing everything it missed. The store's rule; the
    /// screen must not have its own.
    func testComingBackOnDoesNotFireWhatItMissed() throws {
        let model = try model(with: [("check my inbox", .daily(hour: 8, minute: 0))])
        model.setEnabled(false, number: 1)
        model.setEnabled(true, number: 1)

        let task = try XCTUnwrap(ScheduledWork.load(from: file).tasks.first)
        XCTAssertNotNil(task.lastRunAt, "resuming did not move the clock forward")
    }

    func testTheCrossStopsItForGood() throws {
        let model = try model(with: [
            ("check my inbox", .daily(hour: 8, minute: 0)),
            ("send me the week ahead", .weekly(weekday: 2, hour: 9, minute: 30))
        ])

        model.kill(number: 1)

        let kept = ScheduledWork.load(from: file)
        XCTAssertEqual(kept.tasks.map(\.instruction), ["send me the week ahead"])
        XCTAssertEqual(model.work.tasks.map(\.instruction), ["send me the week ahead"])
    }

    // MARK: Setting one up

    func testAddingOneFromTheScreenWritesWhatTheDaemonWillRun() throws {
        let model = try model()

        XCTAssertTrue(model.add(instruction: "  check my inbox  ", cadence: .every(minutes: 30)))

        let task = try XCTUnwrap(ScheduledWork.load(from: file).tasks.first)
        XCTAssertEqual(task.instruction, "check my inbox", "the trim did not happen")
        XCTAssertEqual(task.cadence, .every(minutes: 30))
        XCTAssertNil(model.trouble)
    }

    func testSomethingWithNothingToDoIsRefusedAndSaysSo() throws {
        let model = try model()

        XCTAssertFalse(model.add(instruction: "   ", cadence: .daily(hour: 8, minute: 0)))
        XCTAssertNotNil(model.trouble)
        XCTAssertTrue(ScheduledWork.load(from: file).tasks.isEmpty)
    }

    func testTheCeilingHoldsThroughTheWindowToo() throws {
        let model = try model(with: (1...ScheduledWork.maximumTasks).map {
            ("check my inbox \($0)", ScheduleCadence.daily(hour: 8, minute: 0))
        })

        XCTAssertFalse(model.add(instruction: "one too many", cadence: .daily(hour: 9, minute: 0)))
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.count, ScheduledWork.maximumTasks)
        XCTAssertNotNil(model.trouble)
    }

    /// **A screen that cannot write has to say so.** The owner pressing a switch
    /// that silently does not take is how a poll he thinks he stopped keeps
    /// running — so a failed write is a sentence, and the list does not pretend
    /// otherwise.
    func testAWriteThatFailsIsSaidOutLoud() throws {
        // A *file* where the directory has to go. `OwnerOnlyFileSecurity.write`
        // creates missing directories on purpose — a store that cannot make its
        // own folder is a store that fails on a fresh Mac — so an absent
        // directory is not a failure and this test would pass against nothing.
        let blocker = scratch.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let unwritable = blocker.appendingPathComponent("scheduled-work.json")
        let model = ScheduledWorkModel(fileURL: unwritable)

        XCTAssertFalse(model.add(instruction: "check my inbox", cadence: .daily(hour: 8, minute: 0)))
        XCTAssertNotNil(model.trouble, "a write that failed said nothing")
    }
}
