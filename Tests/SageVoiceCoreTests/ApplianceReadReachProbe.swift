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

/// What the *appliance's own identity* can actually read, asked of the live
/// node. Opt-in, prints rather than asserts, and it exists because nothing else
/// in this repository can answer the question.
///
/// **It was written after three people got the answer wrong twice in one
/// afternoon, in both directions.** The sequence is worth keeping:
///
/// 1. The page claimed Mynah could not read other agents' memories. Reasoning
///    from the capability mask, which is a *write* mask.
/// 2. We corrected it to "reads every subject on this Mac", on the strength of
///    `sage_status` returning ~700 subject names and every agent's counts. Two
///    of us ran that call independently and agreed — which added confidence and
///    no evidence, because **`sage_status` is metadata**. It needs no read
///    access at all: a directory listing, not the files.
/// 3. I then ran real content reads and found denials — but signed as *this
///    session's* agent, not the appliance's, and briefly reported that as
///    Mynah's reach.
/// 4. Only this — content, signed as the appliance — settled it, and the answer
///    was neither of the previous two.
///
/// So: the instrument has to be a content read, made as the identity in
/// question. Totals prove nothing, an error from another agent proves nothing
/// about this one, and three people agreeing proves least of all.
///
/// Prints rather than asserts on purpose. What a given node's ACLs permit is a
/// property of somebody's machine, not of this code, and a test that pinned
/// today's answer would fail on the first grant anybody makes.
@MainActor
final class ApplianceReadReachProbe: XCTestCase {

    func testWhatMynahCanActuallyRead() async throws {
        try LiveNode.required("signs as the appliance and reads from the live node")

        // `SageMemoryStore` is the app's own reader and signs with
        // `MynahIdentity.applianceEnvironment()` — Mynah's key, not this
        // session's.
        // The first five are the original sample. The last four are a
        // **predictive** test of why the first five came out as they did.
        //
        // `thread` verified the reads but not the explanation: "unowned" being
        // the discriminator was an attribution, and four data points fitting it
        // is not the same as it being true. Fitting an explanation to the
        // points you already have is how three wrong versions of this got
        // written today.
        //
        // SAGE's own source names the ownerless set. `agent_capabilities.go`,
        // on `DenySharedDomainWrite`: *"blocks memory creation in ownerless
        // shared domains (general, self, meta, sage-*, and dynamic shared
        // domains)"*. So the hypothesis predicts, before running:
        //
        //   meta, sage-federation      → readable  (ownerless / sage-*)
        //   levelup-bugs, quiettype-release → closed (ordinary owned subjects)
        //
        // Written down here in advance so the result can falsify it rather than
        // be read to fit it.
        for domain in [
            "general", "voice-interface", "native-shell-ci", "sage-release", "self",
            "meta", "sage-federation", "levelup-bugs", "quiettype-release"
        ] {
            do {
                let page = try await SageMemoryStore.shared.recent(topic: domain, limit: 2, offset: 0)
                print("READ \(domain): ok, \(page.memories.count) of \(page.total)")
            } catch {
                print("READ \(domain): REFUSED — \(String(describing: error))")
            }
        }
        // And with no domain filter at all, which is what the screen does.
        do {
            let page = try await SageMemoryStore.shared.recent(topic: nil, limit: 3, offset: 0)
            print("READ <no filter>: ok, \(page.memories.count) of \(page.total)")
        } catch {
            print("READ <no filter>: REFUSED — \(String(describing: error))")
        }
    }
}
#endif  // os(macOS)
