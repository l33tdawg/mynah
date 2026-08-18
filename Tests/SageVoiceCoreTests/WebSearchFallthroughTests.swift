import XCTest
@testable import SageVoiceCore

/// The provider chain's one promise: a provider that cannot answer degrades to
/// one that can.
///
/// **It did not cover "does not answer at all", and that took web search down
/// for twenty-eight hours across eight releases.**
///
/// `BrowserSearchBackend` is `@MainActor`, because `WKWebView` must be. The
/// daemon parked its main thread in `semaphore.wait()`, so nothing serviced the
/// main queue — and in Swift concurrency the main queue *is* the main actor's
/// executor. Every hop into that backend suspended and was never resumed. It
/// never threw, so the chain never fell through to the HTTP provider sitting
/// right behind it, and it never logged, because it hung before it could.
///
/// From the owner's side: "Let me search and see what's out there", then six
/// minutes of nothing, then the daemon's own ceiling apologising. Three times in
/// one afternoon. The log is unambiguous in hindsight — not one `[web_search]`
/// line of any kind after 10:36 on 3 August, and `DuckDuckGo (browser)` never
/// printed once in the appliance's whole history — while the Mac app, which has
/// a real main actor, searched perfectly the entire time.
///
/// The root cause is fixed in `runAndExit`. This is the belt: whatever a
/// provider does, the chain moves on.
final class WebSearchFallthroughTests: XCTestCase {

    /// Never returns and cannot be cancelled — a stand-in for an isolation hop
    /// that will never be scheduled.
    private struct WedgedBackend: WebSearchBackend {
        let providerName = "Wedged"
        func search(query: String, count: Int) async throws -> [WebSearchResult] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3600) {
                    continuation.resume()
                }
            }
            return []
        }
    }

    private struct AnsweringBackend: WebSearchBackend {
        let providerName = "Answering"
        func search(query: String, count: Int) async throws -> [WebSearchResult] {
            [WebSearchResult(title: "found", url: "https://example.com", snippet: "yes")]
        }
    }

    #if os(macOS)
    /// The bound has to sit above every provider's own timeout, or it fires on
    /// providers that were about to answer.
    func testTheGiveUpBoundIsAboveTheBrowsersOwnTimeout() {
        XCTAssertGreaterThan(
            WebSearchToolSource.secondsBeforeGivingUpOnAProvider,
            BrowserSearchBackend.loadTimeout,
            "the chain would abandon a page load that was still within its own budget"
        )
    }
    #endif  // os(macOS)

    /// **The regression test for the outage.** A provider that never returns
    /// must not take the search with it.
    func testAProviderThatNeverAnswersFallsThroughToTheNextOne() async throws {
        let source = WebSearchToolSource(
            backends: [WedgedBackend(), AnsweringBackend()],
            // The real bound is 25s and spending it here would buy nothing: the
            // mechanism is the same at any value, and a suite nobody runs
            // because it is slow catches nothing.
            giveUpOnAProviderAfter: 0.2,
            log: { _ in }
        )

        let started = Date()
        let reply = try await source.call(
            name: WebSearchToolSource.toolName,
            arguments: ["query": .string("dgx spark")]
        )

        XCTAssertTrue(reply.contains("found"), reply)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 10,
            "the chain waited on the provider it had already abandoned"
        )
    }
}
