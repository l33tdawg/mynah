import XCTest
import EventKit
@testable import SageVoiceCore

/// **The calendar mirror could not work in any shipped build, and nothing said so.**
///
/// `sage-voiced` was signed with the hardened runtime and no entitlements at
/// all. Under the hardened runtime a process without
/// `com.apple.security.personal-information.calendars` is refused EventKit
/// before macOS shows the owner anything: `requestFullAccessToEvents` returns
/// `false`, throws nothing, and leaves the authorization status at
/// `notDetermined`. So `wasRefused` stayed false, every tick asked again, and
/// `bridge.log` on the owner's Mac carried 177 consecutive "calendar access was
/// declined" lines between 4 and 6 August 2026 with not one successful write.
///
/// Measured nine ways on 6 August 2026, macOS 26 (Darwin 25.3.0): changing the
/// embedded Info.plist, the bundle identifier, the codesign `--identifier`, and
/// whether the binary sat inside a signed `.app` changed nothing. Adding this
/// one key, everything else held constant, turned `granted=false /
/// notDetermined` into `granted=true / fullAccess` — including for a helper
/// launched by launchd under a bundle identifier that had never been granted
/// anything.
///
/// These tests exist because none of that is visible from Swift. The defect
/// lives in a shell script and a plist, it produces a build that runs perfectly
/// and simply never writes an event, and the entire test suite was green for
/// every release it shipped in.
final class CalendarEntitlementTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// **A file that does not parse grants nothing, and says so late.**
    ///
    /// Caught writing this change: `--` is illegal inside an XML comment, and
    /// the first draft explained the fix using the words "codesign --identifier".
    /// `codesign` refused the whole file — *"Failed to parse entitlements:
    /// AMFIUnserializeXML: syntax error near line 38"* — and had that reached a
    /// release it would have died partway through a signing run, after the build
    /// and before notarization.
    ///
    /// AMFI's parser is stricter than `PropertyListSerialization`, so parsing
    /// alone is not enough to prove it will be accepted. Both checks, on every
    /// entitlements file rather than only the new one.
    func testEveryEntitlementsFileParsesAndAvoidsTheCommentTrap() throws {
        for name in ["SageVoiced", "SageVoiceBridge", "SignalCLI"] {
            let path = "resources/\(name).entitlements"
            let raw = try text(path)

            XCTAssertNoThrow(
                try PropertyListSerialization.propertyList(
                    from: Data(raw.utf8), options: [], format: nil
                ),
                "\(path) is not a readable property list"
            )

            // Every `--` in the file must be one of the two comment delimiters.
            // Anything else is inside a comment body, which XML forbids and
            // AMFI rejects outright.
            let hyphenRuns = raw.components(separatedBy: "--").count - 1
            let delimiters = raw.components(separatedBy: "<!--").count - 1
                + raw.components(separatedBy: "-->").count - 1
            XCTAssertEqual(
                hyphenRuns, delimiters,
                "\(path) has a '--' inside a comment body, which makes codesign reject the whole "
                    + "file with a syntax error partway through a release"
            )
        }
    }

    /// The entitlement itself. Without this key the feature is dead on arrival.
    func testTheDaemonEntitlementsGrantCalendarAccess() throws {
        let entitlements = try text("resources/SageVoiced.entitlements")
        XCTAssertTrue(
            entitlements.contains("com.apple.security.personal-information.calendars"),
            "sage-voiced's entitlements do not grant calendar access, so the hardened runtime "
                + "will refuse EventKit silently and the mirror can never run"
        )
    }

    /// **The entitlement file is worthless unless the daemon is signed with it.**
    ///
    /// This is the half that was actually missing: the packaging script signed
    /// the daemon with no `--entitlements` at all, reasoning — in a comment —
    /// that "it never opens an audio device". True, and the wrong question.
    func testPackagingSignsTheDaemonWithThem() throws {
        let script = try text("scripts/package-app.sh")
        XCTAssertTrue(
            script.contains(#"sign "$APP/Contents/MacOS/$CLI_PRODUCT" --entitlements "$CLI_ENTITLEMENTS""#),
            "package-app.sh does not sign sage-voiced with its entitlements, so the shipped "
                + "daemon carries the hardened runtime and nothing else"
        )
        XCTAssertTrue(
            script.contains("CLI_ENTITLEMENTS=") && script.contains("resources/SageVoiced.entitlements"),
            "package-app.sh has no CLI_ENTITLEMENTS pointing at the daemon's entitlements file"
        )
    }

    /// A signature can drop an entitlement without failing, so the build checks
    /// the finished binary rather than trusting the flag it passed.
    func testPackagingVerifiesTheEntitlementSurvivedSigning() throws {
        let script = try text("scripts/package-app.sh")
        XCTAssertTrue(
            script.contains("CLI_GRANTED=")
                && script.contains(#"$CLI_GRANTED" == *"com.apple.security.personal-information.calendars"*"#),
            "package-app.sh never reads the calendar entitlement back off the signed daemon, so a "
                + "signature that quietly dropped it would ship exactly as before"
        )
    }

    /// The entitlement lets the process ask; this is the sentence the owner
    /// reads when it does. macOS takes it from the bundle the executable lives
    /// in, which is why the daemon stays inside Mynah.app.
    func testTheOwnerIsToldWhyBeforeBeingAsked() throws {
        let plist = try text("resources/Info.plist")
        for key in ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"] {
            XCTAssertTrue(
                plist.contains(key),
                "Info.plist has no \(key); macOS refuses the request outright without one"
            )
        }
    }

    /// **The two failures that read identically in a log.**
    ///
    /// `.denied` is the owner's decision and System Settings can undo it.
    /// `.notDetermined` after a refused request is a build that cannot ask and
    /// never will — it does not even appear in System Settings. Calling both
    /// "declined" is what made 177 log lines look like a preference.
    func testAnUnaskedRefusalIsNotARefusal() {
        XCTAssertTrue(
            EventKitCalendar.wasNeverAsked(.notDetermined),
            "a refusal that leaves the status at notDetermined means nobody was ever asked"
        )
        for answered: EKAuthorizationStatus in [.denied, .restricted, .fullAccess, .writeOnly] {
            XCTAssertFalse(
                EventKitCalendar.wasNeverAsked(answered),
                "\(answered.rawValue) is an answer, and reporting it as 'never asked' would send "
                    + "the reader to rebuild a signature when the owner simply said no"
            )
        }
    }

    /// The dead end has a door. Both messages name what to do next, and they
    /// name *different* things, because the two states need opposite responses.
    func testBothRefusalsNameTheirOwnNextStep() throws {
        let source = try text("Sources/SageVoiceCore/Calendar/EventKitCalendar.swift")
        XCTAssertTrue(
            source.contains("System Settings → Privacy & Security → Calendars"),
            "a genuine refusal must tell the owner where to change it"
        )
        XCTAssertTrue(
            source.contains("resources/SageVoiced.entitlements"),
            "an unasked refusal must point at the build, not at System Settings, because the "
                + "process cannot appear there to be switched on"
        )
    }
}
