import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The appliance must be able to tell that an update did not finish.
///
/// **This is the defect the owner found on 5 August 2026**, in his own words:
/// *"then 1.7.3 is not cleanly updating if the daemon is not restarted bro -
/// cause main app was 1.7.3"*. He was right, and the mechanism was a latch.
///
/// 1.7.3 installed at 19:49:46. The window relaunched onto it at 19:52:07 and
/// ran `enable`, which found the plists stale — the build stamp had changed —
/// wrote new ones, logged *"restarting the phone bridge to apply a changed
/// configuration"*, and restarted nothing. The daemon carried on serving Signal
/// out of the 1.7.2 bundle until it crashed at 20:07:07 on the very WebKit trap
/// 1.7.3 had shipped to fix, and only then did launchd's `KeepAlive` exec the
/// new binary.
///
/// `isAlreadyReconciled` asked two questions: does the plist on disk match what
/// I would write, and does launchd hold both jobs. After a failed restart both
/// answers are yes — the old processes are still loaded, and the file matches
/// because we are the ones who just wrote it. **So the write that exists to
/// trigger the restart is what convinced every later attempt there was nothing
/// to do.** Measured on his Mac at 20:30, four and a half hours after the
/// update, signal-cli was still executing out of
/// `Backups/Mynah-20260805-194946.app` and nothing was ever going to restart it.
///
/// The third question — is launchd running the build that is installed — is the
/// only one a failed restart cannot answer falsely, and it is what these tests
/// pin.
final class InstalledBuildActuallyRunningTests: XCTestCase {

    /// The bytes launchd actually printed, not a fixture written from memory.
    ///
    /// Captured with `launchctl print gui/501/local.sage.voicebridge` on the
    /// owner's Mac while the appliance was in exactly the broken state, with
    /// only his home directory and phone number replaced. The stamp in it,
    /// `6321952-1785915227-608061383`, is the 1.7.2 build; the installed
    /// executable at that moment was `6415200-1785928828-608598496`. That
    /// disagreement is the bug, preserved.
    ///
    /// Captured rather than invented deliberately. The 1.7.4 sweep found ~30
    /// tests across 8 files asserting over SAGE shapes the node had stopped
    /// producing, every one of them a literal somebody wrote by hand, every one
    /// of them green. Of the three files in `Tests/Fixtures`, the only one that
    /// has never rotted is the only one captured from the thing it stands for.
    private func capturedLaunchctlPrint() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SageVoiceCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/launchctl-print-stale-bridge.txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheStampIsReadFromWhatLaunchdReallyPrinted() throws {
        let printed = try capturedLaunchctlPrint()

        XCTAssertEqual(
            SignalBackgroundServiceManager.stamp(inLaunchctlPrint: printed),
            "6321952-1785915227-608061383",
            "this is the 1.7.2 build launchd was still holding; reading it is what proves the restart never happened"
        )
    }

    /// **The parser must not take the first match, and this is why.**
    ///
    /// `launchctl print` emits three environment blocks in a fixed order —
    /// `inherited environment`, `default environment`, then `environment` — and
    /// only the last was loaded from our plist. The first is whatever launched
    /// Mynah. A parser scanning for the first `MYNAH_BUILD_STAMP` would read an
    /// inherited value, and if that value happened to be current it would report
    /// a stale job as reconciled: the exact false "yes" this whole change exists
    /// to remove, reintroduced one layer down.
    func testAnInheritedStampIsNotMistakenForTheLoadedOne() throws {
        let printed = try capturedLaunchctlPrint()
        let poisoned = printed.replacingOccurrences(
            of: "\tinherited environment = {\n",
            with: "\tinherited environment = {\n\t\tMYNAH_BUILD_STAMP => 6415200-1785928828-608598496\n"
        )
        XCTAssertNotEqual(poisoned, printed, "the fixture must still contain the block this test poisons")

        XCTAssertEqual(
            SignalBackgroundServiceManager.stamp(inLaunchctlPrint: poisoned),
            "6321952-1785915227-608061383",
            "the job's own environment is the only one that says what launchd loaded"
        )
    }

    /// A job with no stamp at all reads as "not the installed build".
    ///
    /// Fails closed on purpose, and in the opposite direction to `isLoaded`'s
    /// unanswered question. There the safe reading is "do not destroy"; here it
    /// is "do not declare yourself finished". Being wrong costs one restart.
    /// Being wrong the other way costs an appliance stuck on an old build, which
    /// is what happened.
    func testAJobWithNoStampIsNeverReportedAsCurrent() throws {
        let printed = try capturedLaunchctlPrint()
        let stripped = printed.split(separator: "\n")
            .filter { !$0.contains("MYNAH_BUILD_STAMP") }
            .joined(separator: "\n")

        XCTAssertNil(SignalBackgroundServiceManager.stamp(inLaunchctlPrint: stripped))
        XCTAssertNil(SignalBackgroundServiceManager.stamp(inLaunchctlPrint: ""))
        XCTAssertNil(
            SignalBackgroundServiceManager.stamp(inLaunchctlPrint: "Could not find service \"local.sage.voicebridge\""),
            "launchctl's not-found reply must not parse as a stamp"
        )
    }

    /// The stamp has to distinguish two builds at the same path.
    ///
    /// Which is the whole reason it is size-mtime-inode rather than a version
    /// string: an update replaces `/Applications/Mynah.app/Contents/MacOS/
    /// sage-voiced` in place, so the path is identical either side and only the
    /// inode moves. A stamp that compared paths, or versions Mynah believes it
    /// installed, would have reported 19:52 as a success.
    func testTheStampChangesWhenTheFileAtAPathIsReplaced() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("sage-voiced")
        try Data("one".utf8).write(to: executable)
        let before = SignalBackgroundServiceManager.executableStamp(executable)

        // Replaced the way an installer replaces it: a different file moved on
        // top of the same path, rather than the same file edited.
        let replacement = directory.appendingPathComponent("staged")
        try Data("two".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(executable, withItemAt: replacement)

        XCTAssertNotEqual(
            before,
            SignalBackgroundServiceManager.executableStamp(executable),
            "same path, different file — if this compares equal an update can never be detected"
        )
    }

    /// **The latch itself: matching plists are no longer enough.**
    ///
    /// This is the state the owner's Mac was actually in — the plists on disk
    /// exactly what `enable` would write, both jobs loaded, and launchd holding
    /// the previous build. The old `isAlreadyReconciled` returned true here and
    /// returned early, forever. It must now go on and restart.
    ///
    /// Asserted through `enable` rather than by reaching for the private
    /// predicate, because what matters is not what the predicate returns but
    /// whether launchctl is asked to do anything — a test on the predicate would
    /// still have passed if the restart were wired up wrongly underneath it.
    func testAStalelyLoadedJobIsRestartedEvenWhenThePlistsAlreadyMatch() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configuration = try installedFixture(under: home)

        // First reconcile: nothing is loaded, so it installs and starts both.
        let launchd = FakeLaunchd()
        let manager = SignalBackgroundServiceManager(
            runner: launchd, homeDirectory: home, userID: 501
        )
        try await manager.enable(configuration)
        let afterInstall = await launchd.bootstraps
        XCTAssertEqual(afterInstall, 2, "a first install must start both jobs")

        // Second reconcile with everything current: correctly does nothing.
        await launchd.forgetCalls()
        try await manager.enable(configuration)
        let afterNoChange = await launchd.bootstraps
        XCTAssertEqual(afterNoChange, 0, "nothing to do is still a real answer")

        // Now the state that was permanent: launchd is holding an older build,
        // and the plists on disk are already exactly what we would write.
        await launchd.forgetCalls()
        await launchd.loadAPreviousBuild()
        try await manager.enable(configuration)
        let afterStale = await launchd.bootstraps
        XCTAssertEqual(
            afterStale, 2,
            "launchd was running the previous build; before this fix nothing was ever asked again"
        )
    }

    /// A restart that fails is not retried by every caller, but is not forgotten.
    ///
    /// The reconcile check exists because going straight to bootout on every
    /// call took the owner's Signal down repeatedly — `signal.log` on 29 July
    /// has twelve shutdown/restart pairs in one afternoon. Repairing the latch
    /// must not bring that back, so a build that has already refused to start is
    /// dropped for the rest of the process. The next launch tries again, which
    /// is the difference between this and the latch it replaces.
    func testAFailedRestartIsNotHammeredButIsNotLatchedEither() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configuration = try installedFixture(under: home)

        let launchd = FakeLaunchd()
        await launchd.refuseToStart()
        let manager = SignalBackgroundServiceManager(
            runner: launchd, homeDirectory: home, userID: 501
        )

        do {
            try await manager.enable(configuration)
            XCTFail("a restart that did not take must be reported, not swallowed")
        } catch {}
        let firstAttempt = await launchd.bootstraps
        XCTAssertEqual(firstAttempt, 2)

        // Same manager, same build: it must not keep tearing the socket down.
        await launchd.forgetCalls()
        try await manager.enable(configuration)
        let secondAttempt = await launchd.bootstraps
        XCTAssertEqual(secondAttempt, 0, "one failure per build per process, not one per caller")

        // A fresh process — the next launch — is entitled to try again.
        await launchd.forgetCalls()
        let relaunched = SignalBackgroundServiceManager(
            runner: launchd, homeDirectory: home, userID: 501
        )
        do { try await relaunched.enable(configuration) } catch {}
        let afterRelaunch = await launchd.bootstraps
        XCTAssertEqual(
            afterRelaunch, 2,
            "the 5 August failure was permanent only because nothing ever asked a second time"
        )
    }

    // MARK: - Scaffolding

    private func scratchHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Real files on disk, because `enable` refuses to install a configuration
    /// whose executables are not executable — and because the stamp it compares
    /// is `size-mtime-inode` of those files.
    private func installedFixture(under home: URL) throws -> SignalServiceConfiguration {
        let bundle = home.appendingPathComponent("Mynah.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var made: [URL] = []
        for name in ["signal-cli", "sage-voiced", "sage-gui"] {
            let url = bundle.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            made.append(url)
        }
        return SignalServiceConfiguration(
            account: "+60123456789",
            signalCLI: made[0],
            bridge: made[1],
            sage: made[2],
            provider: "ollama",
            model: "qwen3.5:4b",
            socketPath: home.appendingPathComponent("daemon.socket").path
        )
    }
}
