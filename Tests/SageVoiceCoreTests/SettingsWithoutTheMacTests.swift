import XCTest
@testable import SageVoiceCore

// `getuid()` is libc, and nothing re-exports it off Darwin.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The settings a Linux owner cannot reach.
///
/// Every writer of `ProactivePreferences` in the shipped product was a Mac
/// settings screen, and the only writer of the pause flag was a Mac toggle. On
/// a machine with no such screen the proactive check could be printed and never
/// switched on, and the appliance could not be stopped — which makes these two
/// files the whole feature, off Darwin.
///
/// Two things have to hold for that to work, and both are pinned here:
/// a headless write that fails has to *say so*, and it has to land in the file
/// the daemon is actually reading.
final class SettingsWithoutTheMacTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("headless-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let home = URL(fileURLWithPath: "/home/owner", isDirectory: true)

    // MARK: - Where the files live

    /// **A Mac must not notice any of this.** 2.3.0 is shipping with these
    /// three files at this exact path; a build that moved them would read as a
    /// factory-fresh appliance with the check switched off and nothing paused.
    func testTheMacLayoutIsExactlyWhereItAlreadyWas() {
        let support = "/home/owner/Library/Application Support/SAGE Voice Bridge"
        XCTAssertEqual(
            PauseState.defaultFileURL(homeDirectory: home, layout: .darwin, environment: [:]).path,
            support + "/paused"
        )
        XCTAssertEqual(
            ProactivePreferences.defaultFileURL(homeDirectory: home, layout: .darwin, environment: [:]).path,
            support + "/proactive-preferences.json"
        )
        XCTAssertEqual(
            ServicePreferences.defaultFileURL(homeDirectory: home, layout: .darwin, environment: [:]).path,
            support + "/service-preferences.json"
        )
    }

    /// `~/Library` is a folder nothing on a Linux box understands, and inventing
    /// one in the owner's home is how a program leaves litter that no
    /// uninstaller knows about. `~/.local/share` is where the appliance lock and
    /// the memory store already are.
    func testOffDarwinItIsTheXDGDataDirectory() {
        let support = "/home/owner/.local/share/SAGE Voice Bridge"
        XCTAssertEqual(
            PauseState.defaultFileURL(homeDirectory: home, layout: .xdg, environment: [:]).path,
            support + "/paused"
        )
        XCTAssertEqual(
            ProactivePreferences.defaultFileURL(homeDirectory: home, layout: .xdg, environment: [:]).path,
            support + "/proactive-preferences.json"
        )
        XCTAssertEqual(
            ServicePreferences.defaultFileURL(homeDirectory: home, layout: .xdg, environment: [:]).path,
            support + "/service-preferences.json"
        )
    }

    /// An owner who has moved their data directory has moved it for everything,
    /// and an appliance that ignored the variable would keep its state in a
    /// place their backup does not cover.
    func testXDGDataHomeIsHonouredWhenItIsSet() {
        XCTAssertEqual(
            PauseState.defaultFileURL(
                homeDirectory: home,
                layout: .xdg,
                environment: ["XDG_DATA_HOME": "/srv/state"]
            ).path,
            "/srv/state/SAGE Voice Bridge/paused"
        )
    }

    /// An empty variable is unset, not the filesystem root. `XDG_DATA_HOME=`
    /// appears in shell profiles by accident, and honouring it literally would
    /// put the owner's settings in `/SAGE Voice Bridge` — which they cannot
    /// write, so the appliance would refuse every write on a machine that looks
    /// fine.
    func testAnEmptyXDGDataHomeFallsBackRatherThanWritingToTheRoot() {
        XCTAssertEqual(
            PauseState.defaultFileURL(
                homeDirectory: home,
                layout: .xdg,
                environment: ["XDG_DATA_HOME": ""]
            ).path,
            "/home/owner/.local/share/SAGE Voice Bridge/paused"
        )
    }

    /// **The disagreement this whole area is guarding against.** The daemon
    /// reads these three through their own defaults; anything that writes them
    /// does too. If the three ever spelled the directory separately, one of
    /// them could drift and the owner would pause an appliance that never looks
    /// at the flag they wrote — which is exactly how pause managed to be a lie
    /// the first time.
    func testTheThreeSettingsFilesShareOneDirectoryOnBothPlatforms() {
        for layout in [ApplianceSupportDirectory.Layout.darwin, .xdg] {
            let expected = ApplianceSupportDirectory.directory(
                layout: layout, homeDirectory: home, environment: [:]
            ).path
            let files = [
                PauseState.defaultFileURL(homeDirectory: home, layout: layout, environment: [:]),
                ProactivePreferences.defaultFileURL(homeDirectory: home, layout: layout, environment: [:]),
                ServicePreferences.defaultFileURL(homeDirectory: home, layout: layout, environment: [:]),
            ]
            for file in files {
                XCTAssertEqual(
                    file.deletingLastPathComponent().path,
                    expected,
                    "\(file.lastPathComponent) is not in the appliance directory under \(layout)"
                )
            }
            XCTAssertEqual(
                Set(files.map(\.lastPathComponent)),
                ["paused", "proactive-preferences.json", "service-preferences.json"]
            )
        }
    }

    /// The one `#if` in the story, checked from the other side.
    func testTheRunningBuildUsesItsOwnPlatformsLayout() {
        #if os(macOS)
        XCTAssertEqual(ApplianceSupportDirectory.current, .darwin)
        #else
        XCTAssertEqual(ApplianceSupportDirectory.current, .xdg)
        #endif

        XCTAssertEqual(
            PauseState.defaultFileURL(homeDirectory: home, environment: [:]).path,
            ApplianceSupportDirectory.url(for: "paused", homeDirectory: home, environment: [:]).path
        )
    }

    // MARK: - Turning the proactive check on with no settings screen

    private func proactiveURL() -> URL {
        root.appendingPathComponent("proactive-preferences.json", isDirectory: false)
    }

    /// The feature, in one test: a caller with no window turns it on, and the
    /// next process to read the file — the daemon — sees it on.
    func testAHeadlessCallerCanTurnTheCheckOnAndTheDaemonSeesIt() throws {
        let url = proactiveURL()
        XCTAssertFalse(ProactivePreferences.load(from: url).isOn)

        let written = try ProactivePreferences.update(at: url) {
            $0.isOn = true
            $0.everyMinutes = 30
        }

        XCTAssertTrue(written.isOn)
        XCTAssertEqual(written.everyMinutes, 30)
        let asTheDaemonSeesIt = ProactivePreferences.load(from: url)
        XCTAssertTrue(asTheDaemonSeesIt.isOn, "the daemon cannot tell the owner turned it on")
        XCTAssertEqual(asTheDaemonSeesIt.clampedMinutes, 30)
    }

    /// **The failure this product is worst at.** `amend` cannot report a write
    /// that did not happen, so a tool built on it would print "proactive checks
    /// on" over an appliance that is still off. `update` throws instead.
    ///
    /// The write is made to fail by putting an ordinary file where the
    /// directory would have to go — a stand-in for the real cases (a read-only
    /// home, a directory owned by root) that needs no special privileges and
    /// behaves the same on both platforms.
    func testAWriteThatCannotHappenIsRefusedRatherThanReportedAsSuccess() throws {
        let blocker = root.appendingPathComponent("blocked", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocker)
        let url = blocker.appendingPathComponent("proactive-preferences.json", isDirectory: false)

        XCTAssertThrowsError(try ProactivePreferences.update(at: url) { $0.isOn = true }) { error in
            XCTAssertNotNil(error.localizedDescription)
        }
        XCTAssertFalse(ProactivePreferences.load(from: url).isOn)

        // And the old writer's behaviour, pinned so nobody mistakes it for a
        // safe one: it swallows the same failure whole.
        ProactivePreferences.amend(at: url) { $0.isOn = true }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "amend now reports failures; this test is describing the wrong writer"
        )
    }

    /// A tool that accepts `1` and runs at `5` has told the owner something
    /// untrue about their own appliance. The floor is named, and nothing is
    /// written.
    func testAnIntervalOutsideTheRangeIsRefusedRatherThanSilentlyClamped() throws {
        let url = proactiveURL()
        try ProactivePreferences.update(at: url) { $0.everyMinutes = 30 }

        for minutes in [1, 4, ProactivePreferences.slowest + 1] {
            XCTAssertThrowsError(
                try ProactivePreferences.update(at: url) { $0.everyMinutes = minutes }
            ) { error in
                XCTAssertEqual(
                    error as? ProactivePreferences.Refusal,
                    .intervalOutOfRange(minutes: minutes, path: url.path)
                )
                XCTAssertTrue(
                    error.localizedDescription.contains("\(ProactivePreferences.fastest)"),
                    "the refusal does not say what range is allowed: \(error.localizedDescription)"
                )
            }
            XCTAssertEqual(
                ProactivePreferences.load(from: url).everyMinutes,
                30,
                "a refused interval was written anyway"
            )
        }

        XCTAssertNoThrow(try ProactivePreferences.update(at: url) {
            $0.everyMinutes = ProactivePreferences.fastest
        })
        XCTAssertNoThrow(try ProactivePreferences.update(at: url) {
            $0.everyMinutes = ProactivePreferences.slowest
        })
    }

    /// **A dead end would be worse than the bad value.** The file is editable by
    /// hand and the floor moved once already, so a `1` from an older version can
    /// be sitting there. Refusing every write until it is fixed would leave the
    /// owner unable to switch the feature *off*.
    func testTurningItOffIsNotBlockedByAnIntervalTheCallerDidNotChoose() throws {
        let url = proactiveURL()
        try Data(#"{"isOn":true,"everyMinutes":1,"quietFrom":0,"quietUntil":0}"#.utf8).write(to: url)

        let written = try ProactivePreferences.update(at: url) { $0.isOn = false }

        XCTAssertFalse(written.isOn)
        XCTAssertEqual(written.everyMinutes, 1, "an interval nobody touched was rewritten")
        XCTAssertEqual(written.clampedMinutes, ProactivePreferences.fastest)
    }

    /// Amending a file that will not parse means amending the defaults, and
    /// saving those replaces the owner's quiet hours and interval with values
    /// nobody chose — while reporting success.
    func testACorruptFileIsRefusedRatherThanSilentlyReplacedWithDefaults() throws {
        let url = proactiveURL()
        let corrupt = Data("{ this was a settings file once".utf8)
        try corrupt.write(to: url)

        XCTAssertThrowsError(try ProactivePreferences.update(at: url) { $0.isOn = true }) { error in
            XCTAssertEqual(error as? ProactivePreferences.Refusal, .unreadable(path: url.path))
            XCTAssertTrue(
                error.localizedDescription.contains(url.path),
                "the refusal does not name the file: \(error.localizedDescription)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt, "the unreadable file was overwritten")
    }

    /// The daemon's read stays as forgiving as it was: a corrupt file costs the
    /// owner a setting, not their appliance. Only the *writer* is strict.
    func testTheDaemonsReadIsStillForgiving() throws {
        let url = proactiveURL()
        try Data("{ not json".utf8).write(to: url)

        XCTAssertFalse(ProactivePreferences.load(from: url).isOn)
        XCTAssertEqual(ProactivePreferences.load(from: url).everyMinutes, 60)
    }

    /// A file that is simply not there is the ordinary state of a fresh
    /// install, and must not be an error for either reader.
    func testAnAbsentFileIsNotARefusal() throws {
        let url = root.appendingPathComponent("nothing-here.json", isDirectory: false)
        XCTAssertEqual(try ProactivePreferences.loadOrRefuse(from: url), ProactivePreferences())
        XCTAssertNil(try ServicePreferences(fileURL: url).currentOrRefuse())
    }

    // MARK: - Pause, from a shell

    func testAHeadlessCallerCanPauseAndResume() throws {
        let pause = PauseState(fileURL: root.appendingPathComponent("paused", isDirectory: false))

        try pause.setPaused(true)
        XCTAssertTrue(PauseState(fileURL: pause.fileURL).isPaused())

        try pause.setPaused(false)
        XCTAssertFalse(PauseState(fileURL: pause.fileURL).isPaused())
    }

    /// **`resume` used to be a `try?`.** The removal could fail and the caller
    /// was told nothing, so a tool would print "answering again" while the
    /// daemon went on reading a flag that was still there and staying silent.
    ///
    /// The removal is made to fail by taking write permission off the directory
    /// the flag sits in — a stand-in for the real case, a state directory the
    /// owner cannot write. Two other tricks were tried and do not work:
    /// `removeItem` deletes a non-empty directory recursively rather than
    /// refusing, and a symlink is removed as itself.
    func testAResumeThatCannotClearTheFlagSaysSoRatherThanClaimingSuccess() throws {
        try XCTSkipIf(
            getuid() == 0,
            "root ignores the directory mode this uses to make the removal fail"
        )
        let holder = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        let marker = holder.appendingPathComponent("paused", isDirectory: false)
        try Data().write(to: marker)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: holder.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: holder.path
            )
        }
        let pause = PauseState(fileURL: marker)

        XCTAssertTrue(pause.isPaused())
        XCTAssertThrowsError(try pause.setPaused(false), "a failed resume was reported as success")
        XCTAssertTrue(pause.isPaused(), "still paused, which is what the caller must be told")
    }

    /// Reconciling a preference on launch calls this on a flag that was never
    /// written, and that is not a failure.
    func testResumingSomethingNeverPausedIsStillNotAnError() {
        let pause = PauseState(fileURL: root.appendingPathComponent("paused", isDirectory: false))
        XCTAssertNoThrow(try pause.setPaused(false))
        XCTAssertFalse(pause.isPaused())
    }

    // MARK: - Service configuration

    /// "Not configured" over a file that exists sends the owner to run a setup
    /// they have already run. The daemon still starts either way — `current()`
    /// is unchanged — but anything that prints gets the difference.
    func testACorruptServiceFileIsNotReportedAsSimplyAbsent() throws {
        let url = root.appendingPathComponent("service-preferences.json", isDirectory: false)
        try Data("half a file".utf8).write(to: url)
        let preferences = ServicePreferences(fileURL: url)

        XCTAssertNil(preferences.current())
        XCTAssertThrowsError(try preferences.currentOrRefuse()) { error in
            XCTAssertEqual(error as? ServicePreferences.Refusal, .unreadable(path: url.path))
        }
    }
}
