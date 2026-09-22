import XCTest
@testable import MynahMac

/// **What the app offers, and what it deliberately does not.**
///
/// The sidebar is the whole product's table of contents, so a section arriving or
/// leaving is a product decision. This asserts the four that exist so the next one
/// has to be chosen rather than added.
final class MainSectionTests: XCTestCase {

    /// **There is no Agents section, and that is the point.**
    ///
    /// Agent viewing, management and permissions are CEREBRUM's job and it already
    /// does them properly. A second, worse copy inside a voice appliance was a
    /// surface with no purpose — the test was "does this control need to be
    /// there", and the answer was no.
    ///
    /// Mynah keeps the capability: it can ask another agent for a status update
    /// and read what other agents have shared, both in conversation and without a
    /// screen. What it does not do is present a directory or an RBAC editor.
    ///
    /// Asserted rather than left to a diff, because re-adding a nav entry is a
    /// one-line change and the reasoning against it is not visible in the code.
    ///
    /// **The exact list is pinned for the same reason, and `scheduled` was added
    /// to it on purpose on 22 September 2026.** A destination is the most
    /// expensive thing this window can grow — one more word in the bar, one more
    /// pane to keep working, one more place for the owner to look — so the list
    /// is a decision somebody has to make out loud rather than a consequence of
    /// adding a screen. `scheduled` earned it: standing work runs whether or not
    /// anyone is at the Mac, and the owner asked for somewhere to go and switch
    /// it off or kill it.
    func testThereIsNoAgentDirectorySection() {
        let names = MainSection.allCases.map { $0.rawValue.lowercased() }
        XCTAssertFalse(
            names.contains { $0.contains("agent") },
            "an agent directory section is back in the sidebar: \(names)"
        )
        XCTAssertEqual(names, ["home", "scheduled", "memories", "privacy", "settings"])
    }

    /// Every section needs a title and a one-line summary, because the sidebar
    /// draws both and an empty one would render as a gap.
    func testEverySectionSaysWhatItIsFor() {
        for section in MainSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section) has no title")
            XCTAssertFalse(section.summary.isEmpty, "\(section) has no summary")
        }
    }
}
