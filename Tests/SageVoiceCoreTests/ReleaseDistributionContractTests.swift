import JavaScriptCore
import XCTest

/// Release publishing has two consumers: GitHub Releases and the Pages download
/// button. Both must agree that a distributable release is the same four files.
final class ReleaseDistributionContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testReleaseWorkflowPublishesAndRetainsAllFourArtifacts() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        let publishStart = try XCTUnwrap(workflow.range(of: "- name: Publish")).lowerBound
        let retainStart = try XCTUnwrap(
            workflow.range(
                of: "- name: Keep the artifact even when publishing is skipped",
                range: publishStart..<workflow.endIndex
            )
        ).lowerBound
        let publish = String(workflow[publishStart..<retainStart])
        let retained = String(workflow[retainStart...])
        let retainedLines = Set(retained.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        })

        for token in ["\"$DMG\"", "\"$DMG.sha256\"", "\"$ZIP\"", "\"$ZIP.sha256\""] {
            XCTAssertTrue(publish.contains(token), "GitHub Release omits \(token)")
        }
        for pattern in [
            "dist/Mynah-*.dmg", "dist/Mynah-*.dmg.sha256",
            "dist/Mynah-*.zip", "dist/Mynah-*.zip.sha256"
        ] {
            XCTAssertTrue(
                retainedLines.contains(pattern),
                "retained Actions artifact omits \(pattern)"
            )
        }
    }

    func testDMGVerificationDetachesTheExactDeviceBeforeRemovingItsDirectory() throws {
        let verifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-dmg.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(verifier.contains("DEVICE=\"$(awk"))
        XCTAssertTrue(verifier.contains("hdiutil detach \"$DEVICE\""))
        XCTAssertTrue(verifier.contains("hdiutil detach \"$DEVICE\" -force"))
        XCTAssertFalse(
            verifier.contains("hdiutil detach \"$MOUNT\""),
            "a mount path replaced the exact attached device again"
        )

        let mountedGuard = try XCTUnwrap(
            verifier.range(of: "/sbin/mount | grep -F \" on $MOUNT (\"")
        ).lowerBound
        let removal = try XCTUnwrap(verifier.range(of: "rm -rf \"$MOUNT\"")).lowerBound
        XCTAssertLessThan(
            mountedGuard, removal,
            "cleanup can recurse into the mounted read-only image before checking it detached"
        )
    }

    /// The download button's release selection, executed rather than pattern-matched.
    ///
    /// This proved the same property about the BETA row's selector until 2.0.0
    /// became the stable download and that row was retired. The care went out
    /// with it: what was left choosing the only button on the page was a plain
    /// `find` in array order, and GitHub does not promise newest-first — the API
    /// returned v11.17.5 ahead of v11.18.11 for l33tdawg/sage on 15 Aug 2026. So
    /// the test moved to the surface that still exists rather than being deleted
    /// alongside the one that did not.
    ///
    /// Every filter below is mutation-killable by construction: revert the sort
    /// to `find` and 1.9.0 wins, drop the completeness check and the
    /// still-uploading 2.0.1 wins, drop the draft check and 2.0.2 wins, drop the
    /// prerelease check and a 2.1 beta wins.
    func testPagesChoosesNewestCompleteReleaseFromScrambledResults() throws {
        let page = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/index.html"),
            encoding: .utf8
        )
        let regexStart = try XCTUnwrap(page.range(of: "const DISK_IMAGE =")).lowerBound
        let regexEnd = try XCTUnwrap(page.range(of: ";", range: regexStart..<page.endIndex)).upperBound
        let functionStart = try XCTUnwrap(
            page.range(of: "function newestCompleteRelease", range: regexEnd..<page.endIndex)
        ).lowerBound
        let marker = try XCTUnwrap(
            page.range(of: "// END newestCompleteRelease", range: functionStart..<page.endIndex)
        ).lowerBound

        let script = String(page[regexStart..<regexEnd]) + "\n" + String(page[functionStart..<marker])
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("Pages selector JavaScript failed: \(exception?.toString() ?? "unknown error")")
        }
        context.evaluateScript(script)

        func assets(_ version: String, complete: Bool = true) -> [[String: String]] {
            let stem = "Mynah-\(version)-macOS-arm64"
            var names = ["\(stem).dmg", "\(stem).dmg.sha256"]
            if complete { names += ["\(stem).zip", "\(stem).zip.sha256"] }
            return names.map { ["name": $0] }
        }
        let releases: [[String: Any]] = [
            // Deliberately scrambled, and the first element is an OLDER stable
            // release: exactly the shape that made a plain `find` hand a visitor
            // 1.9.0 from the 2.0 download button.
            ["tag_name": "v1.9.0", "prerelease": false, "draft": false,
             "published_at": "2026-08-07T00:00:00Z", "assets": assets("1.9.0")],
            // Newer, but its ZIP pair has not landed, so it is not installable yet.
            ["tag_name": "v2.0.1", "prerelease": false, "draft": false,
             "published_at": "2026-08-16T00:00:00Z", "assets": assets("2.0.1", complete: false)],
            // Newest complete object is a draft and must remain invisible.
            ["tag_name": "v2.0.2", "prerelease": false, "draft": true,
             "published_at": "2026-08-17T00:00:00Z", "assets": assets("2.0.2")],
            // A newer prerelease must never win the stable button.
            ["tag_name": "v2.1.0-beta.1", "prerelease": true, "draft": false,
             "published_at": "2026-08-18T00:00:00Z", "assets": assets("2.1.0-beta.1")],
            // Carries created_at only, proving the published_at fallback.
            ["tag_name": "v2.0.0", "prerelease": false, "draft": false,
             "created_at": "2026-08-15T00:00:00Z", "assets": assets("2.0.0")]
        ]
        let data = try JSONSerialization.data(withJSONObject: releases)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let selected = context.evaluateScript(
            "newestCompleteRelease(\(json)).tag_name"
        )?.toString()

        XCTAssertEqual(selected, "v2.0.0")
    }

    /// The beta row is gone and has to stay gone. A page offering "the 2.0 beta"
    /// beside a 2.0 stable download is offering a beta of the build sitting next
    /// to it, which is untrue in the way this file has already paid for once.
    func testThePageNoLongerOffersABeta() throws {
        let page = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/index.html"),
            encoding: .utf8
        )
        XCTAssertFalse(page.contains("data-beta-line"), "the beta row came back")
        XCTAssertFalse(
            page.contains("newestCompletePrerelease"),
            "the beta selector came back without its row"
        )
    }
}
