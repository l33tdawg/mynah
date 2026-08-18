import XCTest

/// **The guard that stops a third one appearing.**
///
/// The defect this file closes was not that a test was wrong. It was that a
/// test *skipped*, in the one environment that runs it, for a reason that read
/// as reasonable at the time: a root process walks past a directory mode, so
/// the failure the test wanted to stage did not stage, so the test excused
/// itself. It sat that way through every Linux run the port ever made — a test
/// that could not redden where it mattered, which is the same thing as no test
/// at all, and it announced itself only as one line in a skip count nobody had
/// a measured expectation for.
///
/// Fixing the two occurrences fixes today. It does nothing about the next
/// person who stages a failure with a file mode, watches it not fail under
/// root, and reaches for the obvious guard — the reach is *sensible*, which is
/// exactly why a comment asking them not to would not hold. So this reads the
/// suite instead, in the same idiom the repository already uses to keep a rule
/// from depending on memory.
///
/// A uid check is not banned; `ImpossibleRemoval` itself makes one, and has to.
/// What is banned is a uid check anywhere else in the suite, because every
/// honest use of one here has the same answer — stage the failure so that it
/// fails for root too, which is what this file is for.
final class NoTestExcusesItselfForBeingRootTests: XCTestCase {

    func testNothingInTheSuiteSkipsBecauseItIsRunningAsRoot() throws {
        let suite = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // **The one file allowed to ask, named here rather than pattern-matched.**
        //
        // `ImpossibleRemoval` has to know whether it is root, because that is
        // the branch between dropping capabilities and doing nothing. Listing
        // it by name means adding a second exemption is a deliberate edit to
        // this line with a reason beside it, rather than something a new file
        // can acquire by looking similar. This file is skipped too, or the
        // strings it searches for would convict it of containing them.
        let mayAsk: Set<String> = [
            "ImpossibleRemoval.swift",
            URL(fileURLWithPath: #filePath).lastPathComponent
        ]

        let files = try FileManager.default
            .contentsOfDirectory(at: suite, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !mayAsk.contains($0.lastPathComponent) }

        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Both spellings. `getuid` is the one the removed skip used and is
            // the wrong one on its own terms — DAC checks are made against the
            // effective uid — so a file reaching for either is a file about to
            // repeat this.
            guard text.contains("getuid()") || text.contains("geteuid()") else { continue }
            offenders.append(file.lastPathComponent)
        }

        XCTAssertEqual(
            offenders, [],
            """
            \(offenders.joined(separator: ", ")) decides something from the process's uid.

            If that is a skip, it is the defect this file exists to close: the \
            Linux container runs as root, so the test would stop running in the \
            only environment that runs it, and the suite would go quiet by one \
            without anything going red.

            Stage the failure so it fails for root as well, with \
            ImpossibleRemoval.staged(in:) — it drops CAP_DAC_OVERRIDE and its \
            two neighbours on Linux, sets UF_IMMUTABLE on Darwin, and proves \
            the staging with a decoy rather than trusting either worked.

            If the uid genuinely is the thing under test, this assertion is the \
            wrong shape and should be narrowed to name that file deliberately — \
            not deleted.
            """
        )
    }
}
