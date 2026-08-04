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

        // **Comments stripped, because `sage_domains` appears twice in prose in
        // that file.** The guard passed with the node call deleted: it was
        // reading the paragraph that explains the fix as evidence the fix was
        // there. Found by the 1.7.0 audit.
        let scan = SwiftSourceScan(source)
        let code = scan.text(in: 0..<scan.characters.count)
        XCTAssertTrue(
            code.contains("sage_domains"),
            """
            the Memories page no longer asks the node which domains it owns — \
            11.17.4 answers that directly, and everything else is a guess about \
            somebody else's memories
            """
        )
    }

    /// **The same question, one method below, and the fix missed it.**
    ///
    /// `recent` was scoped to the owned set and `search` was left calling
    /// `sage_recall` with no domain whenever the owner has not picked a topic —
    /// which is the unscoped question the whole change exists to remove, and
    /// the one that put another agent's notes on the screen. The owner's report
    /// was about what he *saw*, and typing in the box is how he sees it.
    ///
    /// Found by the 1.7.0 audit.
    func testAnUnfilteredSearchIsScopedToWhatMynahOwns() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/MemoriesView.swift"),
            encoding: .utf8
        )
        let scan = SwiftSourceScan(source)

        // The body of the store's `search`, matched by brace depth so the
        // assertion is about that method rather than about the file containing
        // the words somewhere.
        let bodies = scan.indices(of: "func search(_ query: String, topic: String?, limit: Int)")
            .compactMap { scan.block(from: $0) }
            .map { scan.text(in: $0) }
        XCTAssertFalse(
            bodies.isEmpty,
            "no search method was found, so this guard is checking nothing"
        )

        // Only the ones that ask the node. `PreviewMemoryStore` implements the
        // same protocol out of an array in memory — it has no node to ask which
        // domains it owns, and demanding one of it would be a guard crying wolf
        // at a SwiftUI preview. What makes a store real here is that it goes
        // through `sage_recall`.
        let real = bodies.filter { $0.contains("sage_recall") }
        XCTAssertFalse(
            real.isEmpty,
            "no search reaches sage_recall, so this guard is watching a stub"
        )

        let unscoped = real.filter { !$0.contains("ownedDomains()") }
        XCTAssertEqual(
            unscoped.count, 0,
            """
            a search with no topic still asks the node for everything this \
            caller may read, which is how the SAGE team's notes appeared under \
            "What Mynah remembers"
            """
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

        // **This used to assert `private static let ownDomains` existed**, which
        // made it a test of a spelling rather than of a rule — and worse, a test
        // that would fail the moment the constant was correctly replaced by the
        // node's answer. It did exactly that.
        //
        // What has to stay true is that the set is *asked for*. The behaviour is
        // pinned properly in MemoryClearScopeTests, which drives a node that owns
        // a third domain; this only catches the constant coming back.
        let scan = SwiftSourceScan(source)
        let code = scan.text(in: 0..<scan.characters.count)
        XCTAssertTrue(
            code.contains("store.domainsMynahOwns()"),
            """
            the owned set that bulk forget and the per-card Forget cross filter \
            through is a constant again. A third owned domain would be listed, \
            shown, and then treated as somebody else's.
            """
        )
    }
}
