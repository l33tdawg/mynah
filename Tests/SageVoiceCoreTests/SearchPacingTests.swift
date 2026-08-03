import XCTest
@testable import SageVoiceCore

/// **The one tool with somebody else's quota.**
///
/// Every other tool talks to the owner's node over a local socket: free,
/// instant, unlimited. `web_search` talks to a third party that throttles by IP,
/// and the keyless provider behind the chain is a scraper, so what it gets when
/// it asks too fast is a challenge page rather than a 429.
///
/// That did not matter while a reply could hold three tool calls. Raising it to
/// twelve — so a four-part job would not come back three-quarters done — made a
/// burst of eight searches reachable in one step, and the owner got *"my
/// searches kept getting throttled mid-way"* on a real question within the hour.
/// The general limit was the wrong place to bound this. A per-tool pace is the
/// right one, because the constraint belongs to the service and not to the loop.
final class SearchPacingTests: XCTestCase {

    /// Records when it was asked and can be told to fail.
    private final class RecordingBackend: WebSearchBackend, @unchecked Sendable {
        let providerName: String
        private let lock = NSLock()
        private(set) var startedAt: [Date] = []
        var failuresRemaining: Int
        var failure: Error

        init(name: String = "stub", failuresRemaining: Int = 0, failure: Error = WebSearchError.transport("no result markup on the page")) {
            self.providerName = name
            self.failuresRemaining = failuresRemaining
            self.failure = failure
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return startedAt.count
        }

        func search(query: String, count: Int) async throws -> [WebSearchResult] {
            lock.lock()
            startedAt.append(Date())
            let shouldFail = failuresRemaining > 0
            if shouldFail { failuresRemaining -= 1 }
            lock.unlock()

            if shouldFail { throw failure }
            return [WebSearchResult(title: "t", url: "https://example.com", snippet: "s")]
        }
    }

    private func source(_ backend: WebSearchBackend) -> WebSearchToolSource {
        WebSearchToolSource(backends: [backend])
    }

    private func search(_ source: WebSearchToolSource, _ query: String) async throws -> String {
        try await source.call(name: WebSearchToolSource.toolName, arguments: ["query": .string(query)])
    }

    // MARK: Pace

    /// **Spaced, not merely retried.** A burst is what gets an IP blocked in the
    /// first place, and no amount of backing off afterwards un-blocks it.
    func testConsecutiveSearchesAreSpacedApart() async throws {
        let backend = RecordingBackend()
        let source = source(backend)

        _ = try await search(source, "eurorack dealers malaysia")
        _ = try await search(source, "eurorack dealers kuala lumpur")

        XCTAssertEqual(backend.startedAt.count, 2)
        let gap = backend.startedAt[1].timeIntervalSince(backend.startedAt[0])
        XCTAssertGreaterThanOrEqual(
            gap,
            WebSearchToolSource.leastSecondsBetweenSearches * 0.8,
            "two searches went out back to back, which is what trips the throttle"
        )
    }

    /// The pace holds when a single reply asks for several at once — which is
    /// the case that caused this, and the case a per-call delay would miss.
    func testAFanOutOfSearchesIsStillPaced() async throws {
        let backend = RecordingBackend()
        let source = source(backend)

        let began = Date()
        await withTaskGroup(of: Void.self) { group in
            for query in ["a", "b", "c"] {
                group.addTask { _ = try? await self.search(source, query) }
            }
        }

        XCTAssertEqual(backend.callCount, 3)
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(began),
            WebSearchToolSource.leastSecondsBetweenSearches * 1.5,
            "three concurrent searches all went out at once"
        )
    }

    /// It paces, it never refuses. A search dropped for pace would be
    /// indistinguishable from a search that found nothing, which is the failure
    /// this whole area exists to stop making.
    func testNothingIsEverDroppedForPace() async throws {
        let backend = RecordingBackend()
        let source = source(backend)

        for query in ["a", "b", "c"] {
            let reply = try await search(source, query)
            XCTAssertTrue(reply.contains("example.com"), reply)
        }
        XCTAssertEqual(backend.callCount, 3)
    }

    // MARK: Throttles

    func testAThrottleIsRecognisedFromAScrapersOwnWording() {
        XCTAssertTrue(WebSearchToolSource.looksThrottled(
            WebSearchError.transport("no result markup on the page — DuckDuckGo may be challenging or rate-limiting this machine")
        ))
        XCTAssertTrue(WebSearchToolSource.looksThrottled(WebSearchError.transport("HTTP 429 Too Many Requests")))
    }

    /// A missing key will fail again in four seconds, and spending the owner's
    /// turn proving that helps nobody.
    func testAnOrdinaryFailureIsNotTreatedAsAThrottle() {
        XCTAssertFalse(WebSearchToolSource.looksThrottled(WebSearchError.missingCredential("Brave")))
    }

    func testAThrottleGetsOneRetry() async throws {
        let backend = RecordingBackend(failuresRemaining: 1)
        let source = source(backend)

        let reply = try await search(source, "eurorack")

        XCTAssertEqual(backend.callCount, 2, "the throttle was not retried")
        XCTAssertTrue(reply.contains("example.com"), reply)
    }

    /// **Throttled is not empty, and the difference has to reach the owner.**
    ///
    /// A failed search surfaced as something the model read as an absence, so a
    /// question that could not be answered came back as a finding. The reply now
    /// says which it was, in words aimed at the model that will read it.
    func testAThrottleThatSurvivesRetryIsNotReportedAsNothingFound() async throws {
        let backend = RecordingBackend(failuresRemaining: 99)
        let source = source(backend)

        let reply = try await search(source, "eurorack dealers malaysia")

        XCTAssertTrue(reply.lowercased().contains("rate-limiting"), reply)
        XCTAssertTrue(reply.contains("not a result"), reply)
        XCTAssertFalse(reply.lowercased().contains("no results found"), reply)
    }

    /// It still names the query, so the model can say *which* part it could not
    /// check rather than abandoning the whole answer.
    func testTheUncheckedQueryIsNamed() async throws {
        let backend = RecordingBackend(failuresRemaining: 99)
        let source = source(backend)

        let reply = try await search(source, "make noise stockist kl")

        XCTAssertTrue(reply.contains("make noise stockist kl"), reply)
    }
}
