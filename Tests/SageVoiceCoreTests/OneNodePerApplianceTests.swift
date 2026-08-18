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
@testable import SageVoiceCore

/// One appliance, one SAGE.
///
/// ## What was actually happening
///
/// A single window launch had **two** SAGE children, seen in the live process
/// tree on 4 August 2026:
///
///     23577  Mynah (window)
///       ├─ 23579  /Applications/SAGE.app/…/sage-gui            ← Memories, Agents
///       └─ 23582  Mynah.app/Contents/Resources/SAGE.app/…      ← the conversation
///     23590  sage-voiced (daemon)
///       └─ 23593  /Applications/SAGE.app/…/sage-gui            ← one, correctly
///
/// `SageNodeChoice.resolve` prefers an **installed** node and falls back to the
/// vendored copy; the daemon, the Memories page and the agents roster all used
/// it. `ConversationModel.locateMemoryNode` did not — it returned the vendored
/// copy first, unconditionally.
///
/// So the chat answered out of one node while the screen showing the owner what
/// Mynah remembers read from another, on a different version. Two writable
/// stores with no arbiter — the hazard `EventKitCalendar` has a whole paragraph
/// about, and this had none. The owner, shown the process tree: *"we should not
/// be doing that bro; will cause conflicts for sure"*.
///
/// It also made a claim we had sent to the SAGE team wrong, and they had already
/// built guidance on it.
///
/// ## Why a source scan
///
/// The failure is not in what any one resolver returns — each was individually
/// defensible. It is in there being more than one. That is a property of the
/// tree, and only a scan of the tree can hold it.
final class OneNodePerApplianceTests: XCTestCase {

    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no Swift sources, so this guard is checking nothing")
        return try files.map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Code with `//` comments removed. Every fix for this class of bug carries
    /// a long comment describing the bug, and a guard that reads prose flags the
    /// very fix it protects — which has already happened twice in this project.
    private func code(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let comment = line.range(of: "//") else { return String(line) }
            return String(line[..<comment.lowerBound])
        }.joined(separator: "\n")
    }

    // MARK: The invariant

    /// **Nothing may reach for the vendored node without going through the one
    /// resolver.** `SageNodeLocator.vendoredExecutableURL()` is legitimate only
    /// as the argument to `SageNodeChoice.resolve`, which decides between it and
    /// an installed node. Used on its own it *is* the decision, made a second
    /// time and differently.
    func testTheVendoredNodeIsOnlyEverOfferedToTheOneResolver() throws {
        // **Looks back over the enclosing expression, not the line.** The first
        // version of this matched line by line and flagged four call sites that
        // were all correct — three of them multi-line `SageNodeChoice.resolve(`
        // calls with the argument on its own line. A guard that cries wolf gets
        // deleted, which is the same end as a guard that cannot fire.
        //
        // 200 characters is enough to span the widest real call here and short
        // enough not to reach a neighbouring statement — the failure mode of the
        // Memories-page guard written earlier the same day.
        let allowed: Set<String> = [
            // Owns the decision.
            "SageNodeChoice.swift",
            // Owns the path.
            "SageNodeLocator.swift",
            // Builds the *list of places to look* for the probe, which is a
            // different question from which one to run.
            "EnvironmentProbe.swift"
        ]

        var rogue: [String] = []
        for file in try sources() where !allowed.contains(file.name) {
            let text = code(in: file.text)
            var search = text.startIndex..<text.endIndex
            while let hit = text.range(of: "vendoredExecutableURL", range: search) {
                search = hit.upperBound..<text.endIndex
                let start = text.index(hit.lowerBound, offsetBy: -200, limitedBy: text.startIndex)
                    ?? text.startIndex
                guard !text[start..<hit.lowerBound].contains("SageNodeChoice") else { continue }
                rogue.append("\(file.name): …\(text[start..<hit.upperBound].suffix(80))")
            }
        }

        XCTAssertEqual(
            rogue, [],
            """
            These pick the vendored SAGE without asking SageNodeChoice, which prefers the owner's \
            installed node. A second answer to "which SAGE" is a second SAGE: the window ran two \
            at once, and the conversation and the Memories page read different memories from \
            different versions. Pass it to SageNodeChoice.resolve.
            """
        )
    }

    /// And the resolver's preference itself: installed before vendored. An
    /// installed SAGE is the owner's own node, with his memories and his
    /// governance; the bundled copy is what a Mac without one falls back to.
    /// Preferring the bundle means preferring an empty stranger to his real
    /// brain.
    func testAnInstalledNodeWinsOverTheBundledOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("one-node-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vendored = directory.appendingPathComponent("Vendored.app/Contents/MacOS/sage-gui")
        try FileManager.default.createDirectory(
            at: vendored.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: vendored.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )

        // No installed candidate at all: the vendored copy is the answer, which
        // is the case it was written for and must keep working.
        let onlyVendored = SageNodeChoice.resolve(vendored: vendored, installedCandidates: [])
        XCTAssertEqual(onlyVendored?.executable, vendored)
        XCTAssertEqual(onlyVendored?.source, .vendored)

        // And nothing at all is nil rather than a guess.
        XCTAssertNil(SageNodeChoice.resolve(vendored: nil, installedCandidates: []))
    }

    /// The conversation must resolve the same way as everything else. Named
    /// explicitly because this is the one that drifted, and a future refactor
    /// that reintroduces a bespoke lookup here would recreate the split.
    func testTheConversationUsesTheSharedResolver() throws {
        let conversation = try sources().first { $0.name == "ConversationModel.swift" }
        let text = try XCTUnwrap(conversation?.text)

        XCTAssertTrue(
            code(in: text).contains("SageNodeChoice.resolve"),
            "the window's chat is choosing its own node again — see the process tree in this file's header"
        )
    }

    // MARK: Not installing over the owner's node

    /// **Detected means leave it alone.** The owner: *"once local sage is
    /// detected, mynah should not try and install again unless user explicitly
    /// redoes the install from scratch and sage is not detected"*.
    ///
    /// Already true, and asserted so it stays true: `provision(given:)` returns
    /// `.alreadyPresent` the moment the probe reports an executable, and a node
    /// that is present but unverifiable is reported rather than replaced —
    /// because verification fails for ordinary reasons on the machine of
    /// somebody who works on SAGE, and none of them entitle an appliance to
    /// overwrite the store holding their memories, agents and keys.
    /// **Stated as "nothing was fetched", not as "the outcome was
    /// `.alreadyPresent`".**
    ///
    /// Those are different claims, and the difference is what made this test
    /// depend on the machine it ran on. It handed `provision` the path
    /// `/Applications/SAGE.app/...`, which exists on the owner's Mac and does
    /// not exist on a CI runner — so verification succeeded here and failed
    /// there, and the test that passed locally failed the **release build**,
    /// after the artefact had already been signed and notarized.
    ///
    /// Both surviving outcomes honour the instruction: `.alreadyPresent` uses
    /// the node, `.unusable` reports it and stops. The one that would break it
    /// is `.downloadedAwaitingUser` — a replacement being fetched over the store
    /// holding somebody's memories, agents and keys.
    ///
    /// Driven with both a node this Mac may or may not have and one that is
    /// guaranteed absent, so the assertion is the same everywhere it runs.
    func testAPresentNodeIsNeverReinstalledOver() async {
        let absent = NSTemporaryDirectory()
            + "no-such-sage-\(UUID().uuidString)/SAGE.app/Contents/MacOS/sage-gui"

        for path in ["/Applications/SAGE.app/Contents/MacOS/sage-gui", absent] {
            var probe = EnvironmentProbeResult()
            probe.sage = SageInstallReport(executablePath: path)

            let outcome = await SageNodeInstaller().provision(given: probe)

            switch outcome {
            case .alreadyPresent, .unusable:
                break // Both leave the owner's node exactly where it is.
            case .downloadedAwaitingUser, .unavailable:
                XCTFail(
                    """
                    a SAGE already on this Mac (\(path)) was not left alone — \
                    Mynah went looking for a replacement: \(outcome)
                    """
                )
            }
        }
    }

    /// And that a node which *does* verify is actually used, not merely spared.
    ///
    /// Separated from the test above and skipped rather than folded into it,
    /// because this one genuinely cannot run without a real SAGE installed. The
    /// alternative — asserting it anyway — is the arrangement that just failed a
    /// release.
    func testAVerifiableNodeIsUsedRatherThanOnlySpared() async throws {
        let installed = "/Applications/SAGE.app/Contents/MacOS/sage-gui"
        guard FileManager.default.fileExists(atPath: installed) else {
            throw XCTSkip(
                "no SAGE installed at /Applications/SAGE.app, so there is no verifiable "
                    + "node on this machine to check against"
            )
        }

        var probe = EnvironmentProbeResult()
        probe.sage = SageInstallReport(executablePath: installed)

        let outcome = await SageNodeInstaller().provision(given: probe)

        guard case .alreadyPresent(let path, _) = outcome else {
            XCTFail("a SAGE that verifies was not adopted: \(outcome)")
            return
        }
        XCTAssertEqual(path, installed)
        XCTAssertTrue(outcome.isReady, "a verified node left the setup flow waiting on something")
    }
}
#endif  // os(macOS)
