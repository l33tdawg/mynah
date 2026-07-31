import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The attribution panel.
///
/// This is the one screen in the app with a legal job rather than a usability
/// one, and the failure mode is silent: a missing licence, a dead link or a
/// credit for something that is not actually shipped all render perfectly. So
/// the shape of the list is asserted here rather than trusted to review.
final class AboutTests: XCTestCase {

    // MARK: Whose product this is

    /// It was nowhere in the interface. The author's name appeared in the whole
    /// tree exactly twice — as a support address and inside a GitHub URL — and
    /// he had to ask for it.
    func testTheAuthorIsNamed() {
        XCTAssertEqual(MynahAbout.author, "Dhillon Andrew Kannabhiran")
    }

    /// Read off the repository's own `LICENSE`, which says `Copyright 2026
    /// Dhillon Andrew Kannabhiran` and is Apache 2.0. No company, no tagline,
    /// and one year rather than a range — the file says one year.
    func testTheCopyrightLineMatchesTheLicenceFile() throws {
        let licence = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // SageVoiceCoreTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("LICENSE"),
            encoding: .utf8
        )

        XCTAssertTrue(
            licence.contains("Copyright 2026 \(MynahAbout.author)"),
            "the About panel names an author or year the LICENSE does not"
        )
        XCTAssertTrue(licence.contains("Apache License"))
        XCTAssertTrue(MynahAbout.copyright.contains("2026"))
        XCTAssertTrue(MynahAbout.copyright.contains("Apache 2.0"))
    }

    /// The bundle tells the owner to "see the LICENSE file included with this
    /// app", and for the whole life of the product no build contained one —
    /// `package-app.sh` copied the icon and the models and never the licences.
    ///
    /// It is not only a broken cross-reference: **signal-cli is GPL 3.0 and
    /// ships inside the bundle**, and GPL-3.0 section 4 requires a copy of the
    /// licence to be conveyed with the program. `resources/licences` exists for
    /// exactly that. This asserts the packaging step that now stages them is
    /// still there, because it is one line and its absence is invisible until
    /// somebody asks for source.
    func testThePackagingStepStagesTheLicencesItIsObligedTo() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("LICENSE").path),
            "the repository has no LICENSE to ship"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("resources/licences/GPL-3.0.txt").path
            ),
            "the GPL text signal-cli obliges us to convey is not in the repository"
        )

        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            script.contains("Contents/Resources/LICENSE"),
            "package-app.sh no longer stages LICENSE, so Info.plist points at a file that is absent"
        )
        XCTAssertTrue(
            script.contains("Contents/Resources/licences"),
            "package-app.sh no longer stages the licences a GPL component obliges us to ship"
        )
    }

    /// Every copyleft credit already carries a source offer; this checks the
    /// component that creates the obligation is still the one we think it is.
    func testTheGPLComponentIsStillTheOneWeShipLicenceTextFor() {
        let copyleft = MynahAbout.components.filter { $0.licence.contains("GPL") }
        XCTAssertFalse(copyleft.isEmpty, "no GPL component — the staged GPL text may now be unnecessary")
        for item in copyleft {
            XCTAssertNotNil(item.sourceOffer, "\(item.name) is copyleft and makes no source offer")
        }
    }

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

    /// **About and the sidebar read the same string.**
    ///
    /// The sidebar now carries the version, because the owner asked to see
    /// which build he is running without opening Settings — after an afternoon
    /// where the DMG in his Dock, the app in `/Applications` and the daemon
    /// answering his phone were repeatedly three different builds.
    ///
    /// Two places computing it separately is how a version string starts
    /// lying, which defeats the only thing it is for. One accessor, asserted
    /// here rather than hoped for.
    @MainActor
    func testTheSidebarAndAboutCannotDisagreeAboutTheBuild() {
        XCTAssertEqual(SettingsModel.appVersion, MynahReleaseVersion.currentBuildLabel())
    }

    /// The build number is the half that earns its place. The marketing version
    /// cannot tell two builds of one release apart, and this project ships
    /// several of those in an afternoon.
    func testTheLabelCarriesTheBuildAndNotOnlyTheRelease() {
        let label = MynahReleaseVersion.currentBuildLabel()
        XCTAssertTrue(label.contains("("), "\"\(label)\" has no build number in it")
        XCTAssertTrue(label.hasSuffix(")"), "\"\(label)\" is missing the build number")
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
