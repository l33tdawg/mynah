import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The unfiltered Memories list must ask for what Mynah **owns**, never for
/// everything it may read.
///
/// ## What the owner saw
///
/// After his node moved to 11.17.4: *"the mynah agent now on 11.17.4 can see
/// memories that don't belong to it - seems like its picking up all mynah-*
/// domains instead of those only scoped to its ownership"*. The screen headed
/// "What Mynah remembers · 59 things" was listing `mynah-sage-auth` entries —
/// the SAGE team's own working notes, *"SAGE v11.17.5 patch release…"*,
/// *"[DON'T] Do not disrupt Chrome tabs owned by another active control
/// session"*.
///
/// ## Why it happened
///
/// `recent(topic:limit:offset:)` set `domain` only when a topic filter was
/// chosen. On "Everything" — the default, and where the owner lands — it asked
/// `sage_list` with no domain at all, and an unscoped `sage_list` answers with
/// everything the caller may *read*. Reading those may well be permitted; a
/// Companion profile reads within clearance and writes only to its own home. But
/// *permitted to read* and *its own* are different sentences, and only one of
/// them is what that heading promises.
///
/// `ScopedRecall` did not help: it wraps `sage_recall`, only when `domain` is
/// absent, and this screen calls `sage_list` through `SageMemoryStore` directly.
/// The fourth instance in one week of a guard written for one call site while an
/// identical one went unwatched.
final class MemoryOwnedScopeTests: XCTestCase {

    /// Records every `sage_list` call so the test can assert on the *question*
    /// rather than on the answer — the bug was entirely in what was asked.
    private final class RecordingNode: @unchecked Sendable {
        let lock = NSLock()
        private(set) var listedDomains: [String?] = []

        func record(domain: String?) {
            lock.lock()
            defer { lock.unlock() }
            listedDomains.append(domain)
        }
    }

    // MARK: The source guard

    /// **A source scan, because the seam that broke is inside an actor holding a
    /// live MCP connection**, and standing one up in a test means spawning a
    /// node. What can be checked cheaply, and is exactly what went wrong, is
    /// that the unfiltered branch never reaches `sage_list` without a domain.
    ///
    /// Comments are stripped first — this file and the fix both *describe* the
    /// unscoped call at length, and a guard that reads prose would flag the very
    /// fix it exists to protect.
    func testTheUnfilteredListingNeverAsksSageListWithoutADomain() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/MemoriesView.swift"),
            encoding: .utf8
        )
        let code = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let comment = line.range(of: "//") else { return String(line) }
            return String(line[..<comment.lowerBound])
        }.joined(separator: "\n")

        // **Bracket-matched, not a byte window**, and the first attempt at this
        // guard proves why. It looked 400 characters either side of
        // `"sage_list"` for a `"domain"` — and the unscoped call sits a few
        // lines below the *scoped* one, so the neighbouring branch's domain
        // satisfied it. Mutation-checked and green on the bug it exists to
        // catch: a guard about guards that cannot fail, that could not fail.
        //
        // So the span is the argument literal itself: from the `[` that opens
        // `arguments:` to its matching `]`, and nothing outside it counts.
        var unscoped: [String] = []
        var search = code.startIndex..<code.endIndex
        while let hit = code.range(of: "\"sage_list\"", range: search) {
            search = hit.upperBound..<code.endIndex
            guard let open = code.range(of: "[", range: hit.upperBound..<code.endIndex) else { continue }
            var depth = 0
            var index = open.lowerBound
            var close = open.lowerBound
            while index < code.endIndex {
                if code[index] == "[" { depth += 1 }
                if code[index] == "]" {
                    depth -= 1
                    if depth == 0 { close = index; break }
                }
                index = code.index(after: index)
            }
            let arguments = code[open.lowerBound...close]
            if !arguments.contains("\"domain\"") {
                unscoped.append(String(arguments.prefix(160)))
            }
        }
        XCTAssertFalse(
            code.range(of: "\"sage_list\"") == nil,
            "the scan found no sage_list call at all, so it is checking nothing"
        )

        XCTAssertEqual(
            unscoped, [],
            """
            A sage_list call has no domain. Unscoped it returns everything this agent may READ, \
            which is how the SAGE team's own notes ended up under "What Mynah remembers". \
            Scope it to owned domains — see SageMemoryStore.ownedDomains().
            """
        )
    }

    /// The owned set must come from the node, not from a constant that was right
    /// only until somebody added a third domain.
    func testTheOwnedSetIsAskedForRatherThanAssumed() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/MemoriesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("sage_domains"),
            "11.17.4 answers 'which domains does this caller own' directly; ask it"
        )
    }

    // MARK: What must not regress

    /// Picking a topic still asks for exactly that topic. The fix is about the
    /// *unfiltered* case, and a filter that silently widened to every owned
    /// domain would be its own bug.
    func testAChosenTopicIsStillAskedForExactly() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/MemoriesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("\"domain\": .string(topic)"),
            "the chosen-topic branch must still pass the owner's chosen topic through unchanged"
        )
    }

    /// **The destructive path was already right, and this pins it.** Deleting is
    /// where a readable-versus-owned confusion would have cost something
    /// irreversible, and `forgetEverythingMynahOwns` has always filtered to the
    /// owned set before calling `sage_forget`. Verified before the bug was ever
    /// reported to the SAGE team, and asserted here so it stays true.
    func testForgetAllStillOnlyOffersWhatMynahOwns() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/MemoriesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let mine = mynahOwned"), "bulk forget stopped filtering by ownership")
        XCTAssertTrue(
            source.contains("private static let ownDomains"),
            "the owned set that bulk forget filters through is gone"
        )
    }
}
