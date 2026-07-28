import XCTest
@testable import MynahMac

/// The attribution panel.
///
/// This is the one screen in the app with a legal job rather than a usability
/// one, and the failure mode is silent: a missing licence, a dead link or a
/// credit for something that is not actually shipped all render perfectly. So
/// the shape of the list is asserted here rather than trusted to review.
final class AboutTests: XCTestCase {

    // MARK: The list itself

    /// A blank licence renders as a blank column and reads as "no licence",
    /// which is the opposite of what an attribution list is for.
    func testEveryCreditNamesSomethingAndALicence() {
        XCTAssertFalse(MynahAbout.components.isEmpty)
        for item in MynahAbout.components {
            XCTAssertFalse(item.name.isEmpty, "a credit has no name")
            XCTAssertFalse(item.licence.isEmpty, "\(item.name) is credited with no licence")
            XCTAssertFalse(item.role.isEmpty, "\(item.name) does not say what it does")
        }
    }

    /// Two rows for the same project is how a list stops being read.
    func testNothingIsCreditedTwice() {
        let names = MynahAbout.components.map(\.id)
        XCTAssertEqual(Set(names).count, names.count, "the same project is credited more than once")
    }

    /// Every "View" button opens a browser, so every URL has to be one a browser
    /// can actually reach. A `mailto:` or a relative path here is a dead button.
    func testEveryCreditLinksSomewhereABrowserCanGo() {
        for item in MynahAbout.components {
            XCTAssertTrue(
                ["http", "https"].contains(item.url.scheme),
                "\(item.name) links to \(item.url), which a browser will not open"
            )
            XCTAssertNotNil(item.url.host, "\(item.name) links to \(item.url), which has no host")
        }
    }

    // MARK: What it says

    /// The licences that were read off each project's own LICENSE at the version
    /// shipped. Pinned so that a well-meaning tidy-up cannot quietly restate one.
    ///
    /// signal-cli is the row that matters most: it is GPL, it is copied into
    /// `Contents/MacOS` by `package-app.sh`, and it is the only copyleft
    /// component in the appliance. A change that softened this string would
    /// misstate the one licence with obligations attached.
    /// whisper.cpp is deliberately absent.
    ///
    /// Its 480 MB model was half the disk image, insuring against a WhisperKit
    /// startup failure that has never been observed. Packaging can ship it again
    /// behind SAGE_VOICE_BUNDLE_WHISPER_CPP — and if it does, it belongs back in
    /// this list, because an attribution panel that credits software the app does
    /// not contain is as wrong as one that omits software it does.
    func testTheVerifiedLicencesAreTheOnesOnScreen() {
        let expected = [
            "signal-cli": "GPL 3.0",
            "WhisperKit": "MIT",
            "Whisper": "Apache 2.0",
            "Kokoro": "Apache 2.0",
            "kokoro-onnx": "MIT",
            "Pion": "MIT",
            "Opus": "BSD 3-Clause",
            "swift-transformers": "Apache 2.0",
            "google/uuid": "BSD 3-Clause",
        ]
        let byName = Dictionary(uniqueKeysWithValues: MynahAbout.components.map { ($0.name, $0.licence) })
        for (name, licence) in expected {
            XCTAssertEqual(byName[name], licence, "\(name) is no longer credited as \(licence)")
        }
    }

    /// The project's own repository is private. A row that looks like a link and
    /// returns a 404 for everyone the owner hands this to is worse than no row,
    /// so the only repository linked from About is the public one.
    func testNoLinkPointsAtAPrivateRepository() {
        XCTAssertEqual(MynahAbout.sageURL.absoluteString, "https://github.com/l33tdawg/sage")
        let everyLink = MynahAbout.components.map(\.url.absoluteString) + [MynahAbout.sageURL.absoluteString]
        for link in everyLink {
            XCTAssertFalse(
                link.contains("sage-voice-bridge"),
                "About links to the private repository: \(link)"
            )
        }
    }

    func testSupportGoesSomewhereAPersonReads() {
        XCTAssertTrue(MynahAbout.supportEmail.contains("@"))
        XCTAssertNotNil(
            URL(string: "mailto:\(MynahAbout.supportEmail)"),
            "the support address does not survive being turned into a mailto: link"
        )
    }

    // MARK: The version

    /// Read from the bundle rather than written down, so a release cannot ship a
    /// stale number. Under `swift test` there is no app bundle, and the em dash
    /// placeholder is the honest answer — the point of this test is that it is
    /// derived at all rather than a literal somebody has to remember to bump.
    @MainActor
    func testTheVersionComesFromTheBundle() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        XCTAssertEqual(SettingsModel.appVersion, "\(short) (\(build))")
    }

    /// A copyleft component must carry an offer of source, not just a credit.
    ///
    /// signal-cli is GPL 3.0 and ships inside the app. Mynah runs it as a
    /// separate process over a socket, so nothing of Mynah's own becomes
    /// copyleft — but distributing the binary still entitles the recipient to
    /// its source, and naming the project does not discharge that.
    ///
    /// Asserted against the licence rather than the name, so a future GPL
    /// dependency cannot be added without someone noticing this.
    func testEveryCopyleftComponentOffersItsSource() {
        let copyleft = MynahAbout.components.filter {
            $0.licence.uppercased().contains("GPL")
        }
        XCTAssertFalse(copyleft.isEmpty, "no copyleft component found; has the list changed?")

        for component in copyleft {
            XCTAssertNotNil(
                component.sourceOffer,
                "\(component.name) is \(component.licence) and ships in the app, but "
                    + "offers the recipient no way to get its source"
            )
        }
    }
}
