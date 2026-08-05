import XCTest
@testable import SageVoiceCore

/// **Nothing the appliance says to a live caller may promise a later delivery.**
///
/// The defect, #47, shipped for the whole of 1.7.x: the call surface drew its
/// opener from `WorkingReply`, whose catch-all pool carries every request that
/// names nothing in particular — which is most of them. Those six sentences all
/// commit to coming back:
///
///     "On it — give me a couple of minutes and I'll come back when it's all done."
///     "Working on it now. I'll come back to you once everything's ready."
///
/// On Signal that is true and is what the owner asked for. On a call the line
/// drops and there is no thread to come back to, so the caller was told to wait
/// for something nothing was going to send.
///
/// The owner's ruling, 5 August 2026: *the call gets its own opener pool, whose
/// lines never promise a later delivery. Signal's pool is untouched.*
///
/// ## Why this walks the pools instead of probing them
///
/// Because the 1.7.3 review found the identical guard wrong twice, in the file
/// written to catch exactly this class of defect. A hand-picked list of probe
/// requests missed ten of sixteen pools — a probe list is a guess about a
/// function's branches, and it goes stale the moment somebody adds a `case` —
/// and the non-vacuity sentinel meant to catch that had been calibrated to what
/// the probes happened to return, so it passed.
///
/// Two independent enumerations here, and neither can be calibrated:
///
/// 1. `RequestKind.allCases`, which is every classification the call surface can
///    land on. A new kind is a compile error in `CallOpening.lines(for:)` and
///    appears here the same day.
/// 2. Every string literal in `CallOpening.swift`, read from the file. That
///    catches a sentence added outside the pools entirely — a fallback, a
///    special case — which the first enumeration would not see.
///
/// And the sentinel itself is checked rather than trusted: `testTheSentinelFires`
/// requires it to flag all six of Signal's lines. A promise detector that
/// cannot detect the promises this project actually wrote is decoration.
final class CallOpeningPromisesNothingTests: XCTestCase {

    // MARK: - The sentinel

    /// Phrases that commit the appliance to delivering something later.
    ///
    /// Chosen from what was *actually being said* — Signal's six catch-all lines
    /// and the per-tool hand-off pool — rather than from imagination, and then
    /// proved against them below. Each is a way of saying "not now, later":
    ///
    /// - `i'll` / `i will`: any first-person future commitment at all. The
    ///   broadest of them, and the one that catches a promise phrased in wording
    ///   nobody anticipated.
    /// - `come back`, `get back`, `follow up`, `let you know`: the promise to
    ///   return, which is the whole finding.
    /// - `send it`, `send you`, `send that`, `send over`: a delivery to a thread
    ///   the call does not have. Also forbidden outright during a call by the
    ///   owner's other ruling of the same day (#21).
    /// - `once it`, `once everything`, `when it's`, `when its`, `when everything`,
    ///   `the moment it`: a completion the caller is being told to wait for.
    static let promisesLater = [
        "i'll", "i will",
        "come back", "get back", "follow up", "let you know",
        "send it", "send you", "send that", "send over",
        "once it", "once everything", "when it's", "when its", "when everything",
        "the moment it"
    ]

    private func promise(in line: String) -> String? {
        let lowered = line.lowercased()
        return Self.promisesLater.first { lowered.contains($0) }
    }

    /// **The sentinel must catch the promises this project really wrote.**
    ///
    /// Without this the whole file is unfalsifiable: a marker list that matches
    /// nothing passes every assertion below while the call says whatever it
    /// likes. Signal's catch-all is the ground truth — every one of those six
    /// lines is a promise, by the owner's explicit design, so a detector that
    /// misses any of them is not detecting promises.
    func testTheSentinelFires() {
        XCTAssertFalse(WorkingReply.catchAllOptions.isEmpty)
        for line in WorkingReply.catchAllOptions {
            XCTAssertNotNil(
                promise(in: line),
                """
                the promise detector does not flag "\(line)", which Signal's own \
                testEveryCatchAllPromisesToComeBack requires to be a promise. \
                Every assertion in this file is vacuous until it does.
                """
            )
        }
    }

    // MARK: - Every pool the call can reach

    /// Walks `RequestKind.allCases`, so a new classification cannot slip past.
    func testNoPoolTheCallReadsPromisesALaterDelivery() {
        for kind in WorkingReply.RequestKind.allCases {
            let pool = CallOpening.lines(for: kind)
            XCTAssertFalse(
                pool.isEmpty,
                "the call has nothing to say for \(kind), so it falls silent on those turns"
            )
            for line in pool {
                XCTAssertNil(
                    promise(in: line),
                    """
                    the call can say "\(line)" (kind: \(kind)), which promises \
                    "\(promise(in: line) ?? "")". The line drops at the end of a call \
                    and there is no thread to deliver into.
                    """
                )
            }
        }
    }

    /// Including the cut-in compositions, which are assembled rather than stored.
    ///
    /// `interruptedOpening` builds *"Right — looking into that now."* out of two
    /// halves. Checking only the pools would miss a promise living in the
    /// acknowledgement or in the tail used when nothing was named.
    func testNoLineTheCallCanSpeakPromisesALaterDelivery() {
        let spoken = CallOpening.everySpokenLine
        XCTAssertGreaterThan(
            spoken.count, WorkingReply.RequestKind.allCases.count,
            "everySpokenLine did not enumerate the compositions, so this is checking less than it says"
        )
        for line in spoken {
            XCTAssertNil(promise(in: line), "the call can say \"\(line)\"")
        }
    }

    /// The second enumeration: every literal in the file, whether or not it is
    /// in a pool.
    ///
    /// A sentence added as a one-off fallback would be invisible to
    /// `RequestKind.allCases` and is caught here. Over-broad on purpose — it
    /// reads doc-comment-adjacent code literals too, and none of those may
    /// promise either, because anything written in this file is a candidate for
    /// being spoken.
    func testNothingWrittenInTheCallsOpenerFilePromises() throws {
        let literals = try callOpeningLiterals()
        XCTAssertGreaterThan(
            literals.count, 8,
            "only \(literals.count) literals were read from CallOpening.swift; the extractor is not working"
        )
        for line in literals {
            XCTAssertNil(
                promise(in: line),
                "\"\(line)\" is written in CallOpening.swift and promises a later delivery"
            )
        }
    }

    // MARK: - Wired up, and Signal left alone

    /// **The call surface must actually read `CallOpening`.**
    ///
    /// Everything above is true of a type nobody calls. This is the assertion
    /// that the fix is connected: `CallTurnServer` must not reach for
    /// `WorkingReply`'s openers, because those are Signal's and promise a
    /// return.
    func testTheCallSurfaceDoesNotReachForSignalsOpeners() throws {
        let scan = SwiftSourceScan(try source(of: "Sources/SageVoiceCore/Call/CallTurnServer.swift"))

        for reached in ["WorkingReply.opening", "WorkingReply.interruptedOpening", "WorkingReply.instantLine"] {
            let hits = scan.indices(of: reached)
            XCTAssertEqual(
                hits, [],
                """
                CallTurnServer still calls \(reached) at line \
                \(hits.map { String(scan.line(of: $0)) }.joined(separator: ", ")). \
                That is Signal's pool: its catch-all promises to come back later, \
                and a call has nothing to come back to.
                """
            )
        }
        XCTAssertTrue(
            scan.contains("CallOpening."),
            "CallTurnServer no longer speaks an opener at all, which is not the fix"
        )
    }

    /// **Signal's pool is byte-identical afterwards**, which the owner asked for
    /// in as many words.
    ///
    /// Pinned literally rather than counted or spot-checked. The point of his
    /// ruling was that "I'll come back to you" is *correct* on the surface that
    /// has a thread to come back to — so the risk this guards is not a typo, it
    /// is a well-meaning later change that quietly strips the promises from both
    /// pools because one of them looked wrong.
    func testSignalsPoolIsUnchanged() {
        XCTAssertEqual(
            WorkingReply.catchAllOptions,
            [
                "On it — give me a couple of minutes and I'll come back when it's all done.",
                "Working on it now. I'll come back to you once everything's ready.",
                "Give me a couple of minutes — I'll send it over when it's ready to look at.",
                "Let me get this sorted, and I'll come back to you with the whole thing.",
                "I'm on it. It'll take a few minutes — I'll let you know the moment it's done.",
                "Doing that now. Give me a little while and I'll come back when it's ready."
            ],
            """
            Signal's catch-all changed. It is supposed to promise a return — there \
            is a thread to return to, and 1.7.3 made the promise durable. If this \
            failed while fixing the call, the fix went to the wrong surface.
            """
        )
    }

    /// And the call's own catch-all is a real pool, not one line.
    ///
    /// This is the sentence a caller hears on nearly every turn — out loud,
    /// where repetition is far more obvious than it is in text. `opening` also
    /// refuses to repeat the previous line, so a pool of one falls silent
    /// exactly when it is needed twice.
    func testTheCallsCatchAllIsWorthHearingTwice() {
        let pool = CallOpening.catchAllOptions
        XCTAssertGreaterThanOrEqual(pool.count, 5, "this is the line heard most; five is the owner's floor on Signal")
        XCTAssertEqual(Set(pool).count, pool.count, "a duplicate is one fewer variation than the count claims")

        let firstWords = pool.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertGreaterThanOrEqual(
            Set(firstWords).count, 4,
            "these read as one line rewritten: \(firstWords)"
        )
    }

    /// Nothing said before the model has decided anything may name a tool or a
    /// source. The same rule Signal's catch-all lives under, and for the same
    /// reason: at this moment nothing has chosen a tool, so naming one is the
    /// appliance guessing out loud.
    func testTheCallsCatchAllClaimsNothing() {
        for line in CallOpening.catchAllOptions {
            for claim in ["online", "search", "web", "memory", "sage", "note", "backlog"] {
                XCTAssertFalse(
                    line.localizedCaseInsensitiveContains(claim),
                    "the call's catch-all line \"\(line)\" claims \(claim) before anything has decided to do it"
                )
            }
        }
    }

    // MARK: - Scaffolding

    private func source(of path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func callOpeningLiterals() throws -> Set<String> {
        SwiftSourceScan(try source(of: "Sources/SageVoiceCore/Call/CallOpening.swift")).stringLiterals()
    }
}
