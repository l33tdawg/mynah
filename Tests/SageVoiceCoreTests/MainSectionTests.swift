// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
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
    func testThereIsNoAgentDirectorySection() {
        let names = MainSection.allCases.map { $0.rawValue.lowercased() }
        XCTAssertFalse(
            names.contains { $0.contains("agent") },
            "an agent directory section is back in the sidebar: \(names)"
        )
        XCTAssertEqual(names, ["home", "memories", "privacy", "settings"])
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
#endif  // os(macOS)
