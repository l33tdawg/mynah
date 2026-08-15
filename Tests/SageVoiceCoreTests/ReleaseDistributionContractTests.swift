import JavaScriptCore
import XCTest

/// Release publishing has two consumers: GitHub Releases and the Pages beta
/// link. Both must agree that a distributable beta is the same four files.
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

    func testPagesChoosesNewestCompleteBetaFromScrambledResults() throws {
        let page = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/index.html"),
            encoding: .utf8
        )
        let regexStart = try XCTUnwrap(page.range(of: "const DISK_IMAGE =")).lowerBound
        let regexEnd = try XCTUnwrap(page.range(of: ";", range: regexStart..<page.endIndex)).upperBound
        let functionStart = try XCTUnwrap(
            page.range(of: "function newestCompletePrerelease", range: regexEnd..<page.endIndex)
        ).lowerBound
        let marker = try XCTUnwrap(
            page.range(of: "// END newestCompletePrerelease", range: functionStart..<page.endIndex)
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
            // Deliberately scrambled: the expected release is not first.
            ["tag_name": "v2.0.0-beta.8", "prerelease": true, "draft": false,
             "published_at": "2026-08-01T00:00:00Z", "assets": assets("2.0.0-beta.8")],
            // Newer, but still uploading its ZIP pair.
            ["tag_name": "v2.0.0-beta.11", "prerelease": true, "draft": false,
             "published_at": "2026-08-11T00:00:00Z", "assets": assets("2.0.0-beta.11", complete: false)],
            // Newest complete object is a draft and must remain invisible.
            ["tag_name": "v2.0.0-beta.12", "prerelease": true, "draft": true,
             "published_at": "2026-08-12T00:00:00Z", "assets": assets("2.0.0-beta.12")],
            ["tag_name": "v2.0.0-beta.10", "prerelease": true, "draft": false,
             "created_at": "2026-08-10T00:00:00Z", "assets": assets("2.0.0-beta.10")],
            ["tag_name": "v1.9.0", "prerelease": false, "draft": false,
             "published_at": "2026-08-13T00:00:00Z", "assets": assets("1.9.0")]
        ]
        let data = try JSONSerialization.data(withJSONObject: releases)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let selected = context.evaluateScript(
            "newestCompletePrerelease(\(json)).tag_name"
        )?.toString()

        XCTAssertEqual(selected, "v2.0.0-beta.10")
        XCTAssertEqual(page.components(separatedBy: "data-beta-line hidden").count - 1, 2)
    }
}
