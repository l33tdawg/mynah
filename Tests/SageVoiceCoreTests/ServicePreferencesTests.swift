import XCTest
@testable import SageVoiceCore

/// The file that lets the LaunchAgent plists become static.
///
/// `SMAppService` needs a plist bundled inside the app, identical on every Mac,
/// which means the per-owner values — phone number, provider, model, socket,
/// node — cannot live in `ProgramArguments` any more. They live here instead.
final class ServicePreferencesTests: XCTestCase {

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-prefs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(model: String? = "qwen3.5:4b") -> ServicePreferences.Stored {
        ServicePreferences.Stored(
            account: "+60123456789",
            provider: "ollama",
            model: model,
            socketPath: "/Users/owner/.local/share/signal-cli/daemon.socket",
            sagePath: "/Applications/SAGE.app/Contents/MacOS/sage-gui"
        )
    }

    func testWhatIsWrittenIsWhatIsRead() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = ServicePreferences(
            fileURL: root.appendingPathComponent("service-preferences.json")
        )

        try preferences.save(fixture())

        XCTAssertEqual(preferences.current(), fixture())
    }

    /// **A missing file is boring, not fatal.** It is the ordinary state of a
    /// Mac where setup has not finished, and an appliance that refused to start
    /// over an absent preferences file would be a worse failure than the one it
    /// was guarding against.
    func testAnAbsentFileIsNotAnError() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = ServicePreferences(
            fileURL: root.appendingPathComponent("nothing-here.json")
        )

        XCTAssertNil(preferences.current())
    }

    /// A corrupt preference costs the owner their preference, not their
    /// appliance — the `ReplyPreferences` rule, kept deliberately identical so
    /// there is one behaviour to learn rather than four.
    func testAFileThatWillNotParseReadsAsAbsent() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("service-preferences.json")
        try Data("{ this is not json".utf8).write(to: url)

        XCTAssertNil(ServicePreferences(fileURL: url).current())
    }

    /// No model is a real answer, not a missing one: an API provider serves
    /// whatever it serves unless the owner pins something, and inventing a name
    /// here would put a model nobody chose into a launch flag.
    func testNoPinnedModelSurvivesTheRoundTrip() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = ServicePreferences(
            fileURL: root.appendingPathComponent("service-preferences.json")
        )

        try preferences.save(fixture(model: nil))

        XCTAssertEqual(preferences.current()?.model, nil)
        XCTAssertEqual(preferences.current()?.provider, "ollama")
    }

    /// Rewriting an identical file moves its modification date, and a
    /// modification date is a fact somebody reads later as "this changed at
    /// 11:40" — which is exactly how today's regression was pinned down. It
    /// also keeps this off the path that restarts the appliance: a no-op
    /// reconcile has to stay a no-op all the way down.
    func testWritingTheSameValuesTwiceDoesNotTouchTheFile() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("service-preferences.json")
        let preferences = ServicePreferences(fileURL: url)

        XCTAssertTrue(try preferences.save(fixture()), "the first write did not happen")
        XCTAssertFalse(
            try preferences.save(fixture()),
            "an unchanged configuration rewrote the file and moved its date"
        )

        let changed = ServicePreferences.Stored(
            account: "+60123456789", provider: "anthropic", model: "claude-sonnet-4-5",
            socketPath: "/Users/owner/.local/share/signal-cli/daemon.socket",
            sagePath: "/Applications/SAGE.app/Contents/MacOS/sage-gui"
        )
        XCTAssertTrue(try preferences.save(changed), "a real change was skipped")
        XCTAssertEqual(preferences.current(), changed)
    }

    /// A phone number and a node path are the owner's, and this file sits in a
    /// directory alongside their Signal identity. It gets the same treatment as
    /// everything else there rather than whatever the umask happens to be.
    func testItIsWrittenForTheOwnerAlone() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("service-preferences.json")

        try ServicePreferences(fileURL: url).save(fixture())

        let permissions = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    /// Removing the appliance removes this too, so an account the owner
    /// unlinked months ago cannot be picked up by a service they re-enable.
    func testClearingLeavesNothingBehind() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("service-preferences.json")
        let preferences = ServicePreferences(fileURL: url)
        try preferences.save(fixture())

        preferences.clear()

        XCTAssertNil(preferences.current())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// It lands beside the other three rather than somewhere of its own. The
    /// directory survives a reinstall, which is the property the pause marker
    /// is chosen for and the reason this is not in `UserDefaults`.
    ///
    /// **Deliberately unguarded, on every platform.** "Beside" is not a Mac
    /// fact, it is the whole invariant: `ApplianceSupportDirectory` exists
    /// because two processes disagreeing about this path is a pause that stops
    /// nothing, and that disagreement is exactly what shows up off Darwin when
    /// one producer routes through that type and its neighbour spells
    /// `~/Library/Application Support` by hand. A platform guard here would
    /// hide the one arrangement that can actually break, so this compares the
    /// two producers against each other rather than against a literal path —
    /// which keeps it true under both layouts without knowing either.
    func testItLivesBesideTheOtherPreferences() {
        let home = URL(fileURLWithPath: "/Users/owner", isDirectory: true)
        let service = ServicePreferences.defaultFileURL(homeDirectory: home)
        let reply = ReplyPreferences.defaultFileURL(homeDirectory: home)

        XCTAssertEqual(
            service.deletingLastPathComponent(),
            reply.deletingLastPathComponent(),
            """
            Two of the appliance's settings files landed in two different \
            directories. Whichever of these does not go through \
            ApplianceSupportDirectory is the one to fix: off Darwin that type \
            answers $XDG_DATA_HOME/SAGE Voice Bridge (~/.local/share/… when \
            unset), so a producer that spells ~/Library/Application Support by \
            hand both misses its neighbour and leaves a stray Library in a \
            Linux owner's home. Route it through ApplianceSupportDirectory \
            rather than guarding this assertion.
            """
        )
        XCTAssertEqual(service.lastPathComponent, "service-preferences.json")
    }
}
