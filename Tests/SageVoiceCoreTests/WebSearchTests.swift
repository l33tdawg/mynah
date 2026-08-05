import XCTest
@testable import SageVoiceCore

// MARK: - Stubs

private final class StubSearchBackend: WebSearchBackend, @unchecked Sendable {
    let providerName: String
    private let outcome: Result<[WebSearchResult], WebSearchError>
    private let lock = NSLock()
    private var queries: [String] = []

    init(providerName: String, outcome: Result<[WebSearchResult], WebSearchError>) {
        self.providerName = providerName
        self.outcome = outcome
    }

    func search(query: String, count: Int) async throws -> [WebSearchResult] {
        record(query)
        return try outcome.get()
    }

    var recordedQueries: [String] { withLock { queries } }

    private func record(_ query: String) { withLock { queries.append(query) } }

    /// `NSLock` is `noasync`; a non-async body makes it impossible to suspend
    /// while holding it.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func result(_ title: String, _ url: String, _ snippet: String = "") -> WebSearchResult {
    WebSearchResult(title: title, url: url, snippet: snippet)
}

// MARK: - DuckDuckGo parsing

final class DuckDuckGoSearchBackendTests: XCTestCase {

    /// Shaped like the live page: `rel` before `class`, `class` before `href`,
    /// `<b>` around matched terms, entities in the text.
    private func page(_ blocks: String) -> String {
        """
        <html><body><div id="links" class="results">
        \(blocks)
        </div></body></html>
        """
    }

    private func block(href: String, title: String, snippet: String) -> String {
        """
        <div class="result results_links">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="\(href)">\(title)</a>
          </h2>
          <a class="result__snippet" href="\(href)">\(snippet)</a>
        </div>
        """
    }

    func testTitlesURLsAndSnippetsAreExtracted() throws {
        let html = page(block(
            href: "https://www.tii.ae/",
            title: "Technology <b>Innovation</b> Institute",
            snippet: "Abu Dhabi research centre for science &amp; tech."
        ))

        let results = try DuckDuckGoSearchBackend.parse(html: html, limit: 5)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Technology Innovation Institute", "bold tags must not be spoken")
        XCTAssertEqual(results[0].url, "https://www.tii.ae/")
        XCTAssertEqual(results[0].snippet, "Abu Dhabi research centre for science & tech.")
    }

    func testResultsAndSnippetsStayPairedAcrossSeveralResults() throws {
        let html = page([
            block(href: "https://one.example/", title: "One", snippet: "first"),
            block(href: "https://two.example/", title: "Two", snippet: "second"),
            block(href: "https://three.example/", title: "Three", snippet: "third")
        ].joined(separator: "\n"))

        let results = try DuckDuckGoSearchBackend.parse(html: html, limit: 5)

        XCTAssertEqual(results.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(results.map(\.snippet), ["first", "second", "third"])
    }

    func testTheLimitIsHonoured() throws {
        let html = page((1...10).map {
            block(href: "https://\($0).example/", title: "Result \($0)", snippet: "s\($0)")
        }.joined(separator: "\n"))

        XCTAssertEqual(try DuckDuckGoSearchBackend.parse(html: html, limit: 3).count, 3)
    }

    /// DuckDuckGo has served both wrapped and direct hrefs; the live page moved
    /// to direct ones mid-development, so both have to keep working.
    func testTheRedirectWrapperIsUnwrapped() {
        let wrapped = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.tii.ae%2Fabout&amp;rut=abc123"
        XCTAssertEqual(
            DuckDuckGoSearchBackend.unwrapRedirect(HTMLText.decodeEntities(wrapped)),
            "https://www.tii.ae/about"
        )
    }

    func testADirectHrefIsPassedThrough() {
        XCTAssertEqual(
            DuckDuckGoSearchBackend.unwrapRedirect("https://www.tii.ae/"),
            "https://www.tii.ae/"
        )
    }

    func testAProtocolRelativeHrefBecomesHTTPS() {
        XCTAssertEqual(
            DuckDuckGoSearchBackend.unwrapRedirect("//example.com/page"),
            "https://example.com/page"
        )
    }

    /// The distinction this backend exists to keep: "nothing matched" is an
    /// answer the owner can act on, "we got a challenge page" is a fault.
    func testAGenuineNoResultsPageReturnsAnEmptyList() throws {
        let html = """
        <html><body><div class="no-results">No results found for that query.</div></body></html>
        """
        XCTAssertEqual(try DuckDuckGoSearchBackend.parse(html: html, limit: 5).count, 0)
    }

    func testAChallengePageIsAFaultNotAnEmptyResult() {
        let html = "<html><body><h1>Unfortunately, bots use DuckDuckGo too.</h1></body></html>"

        XCTAssertThrowsError(try DuckDuckGoSearchBackend.parse(html: html, limit: 5)) { error in
            guard case WebSearchError.unparseableResponse = error else {
                return XCTFail("expected unparseableResponse, got \(error)")
            }
        }
    }

    func testAResultWithNoUsableTitleIsSkipped() throws {
        let html = page([
            block(href: "https://ok.example/", title: "Fine", snippet: "yes"),
            block(href: "https://blank.example/", title: "", snippet: "no title")
        ].joined(separator: "\n"))

        let results = try DuckDuckGoSearchBackend.parse(html: html, limit: 5)
        XCTAssertEqual(results.map(\.title), ["Fine"])
    }

    func testTheQueryIsFormEncoded() {
        let body = DuckDuckGoSearchBackend.formBody(["q": "swift & concurrency"])
        XCTAssertEqual(String(data: body, encoding: .utf8), "q=swift%20%26%20concurrency")
    }
}

// MARK: - Brave parsing

final class BraveSearchBackendTests: XCTestCase {

    func testResultsAreDecoded() throws {
        let json = Data("""
        {"web":{"results":[
          {"title":"Falcon LLM","url":"https://falconllm.tii.ae/","description":"Open <strong>models</strong> from TII."},
          {"title":"TII","url":"https://www.tii.ae/","description":"Research centre."}
        ]}}
        """.utf8)

        let results = try BraveSearchBackend.parse(data: json, limit: 5)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Falcon LLM")
        XCTAssertEqual(results[0].snippet, "Open models from TII.", "term highlighting must not be spoken")
    }

    func testAMissingWebBlockIsZeroResultsNotAnError() throws {
        let json = Data(#"{"query":{"original":"asdkjhasd"},"type":"search"}"#.utf8)
        XCTAssertEqual(try BraveSearchBackend.parse(data: json, limit: 5).count, 0)
    }

    func testAMissingDescriptionIsTolerated() throws {
        let json = Data(#"{"web":{"results":[{"title":"T","url":"https://e.example/"}]}}"#.utf8)
        let results = try BraveSearchBackend.parse(data: json, limit: 5)
        XCTAssertEqual(results[0].snippet, "")
    }

    func testGarbageIsReportedAsUnparseable() {
        XCTAssertThrowsError(try BraveSearchBackend.parse(data: Data("not json".utf8), limit: 5)) { error in
            guard case WebSearchError.unparseableResponse = error else {
                return XCTFail("expected unparseableResponse, got \(error)")
            }
        }
    }

    func testNoKeyInTheEnvironmentMeansNoBackend() {
        XCTAssertNil(BraveSearchBackend.fromEnvironment([:]))
        XCTAssertNil(BraveSearchBackend.fromEnvironment(["BRAVE_SEARCH_API_KEY": "   "]))
        XCTAssertNotNil(BraveSearchBackend.fromEnvironment(["BRAVE_SEARCH_API_KEY": "abc"]))
    }

    /// **The order is the whole design, so it is asserted rather than assumed.**
    ///
    /// A key first, because a provider with a quota answers in ~200 ms and never
    /// sees a challenge page. The raw HTTP scrape stays last, as the floor.
    ///
    /// **The browser used to sit between them, unconditionally, and that is what
    /// killed the appliance.** This comment used to say the scrape stayed last
    /// because "WebKit outside an app bundle is the genuinely uncertain part of
    /// this, and a Mac where it will not start must be no worse off than it was
    /// before". Both halves were wrong. WebKit2 does not fail to start outside
    /// an application — it traps the process — so the floor described here was
    /// unreachable code that never ran once in the daemon, and a Mac where
    /// WebKit "will not start" was not no-worse-off, it was dead. See
    /// `BrowserEngineAvailability` and `NoBrowserEngineOutsideTheAppTests`.
    ///
    /// So the browser is now absent unless the caller proves it is an
    /// application, and this test asserts that absence — because it is the
    /// default every caller gets and the one the daemon must keep.
    func testBraveIsPreferredWhenAKeyIsPresent() {
        let empty = ProviderKeyStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("keys-\(UUID().uuidString).json"))

        let withKey = WebSearchToolSource.defaultBackends(
            environment: ["BRAVE_SEARCH_API_KEY": "abc"],
            keys: empty
        )
        XCTAssertEqual(withKey.map(\.providerName).first, "Brave Search")

        let without = WebSearchToolSource.defaultBackends(environment: [:], keys: empty)
        XCTAssertFalse(without.map(\.providerName).contains("Brave Search"))
        XCTAssertEqual(without.map(\.providerName).last, "DuckDuckGo", "the plain scrape must stay as the floor")
    }

    /// The default chain carries no browser engine, in either shape.
    ///
    /// Stated as an equality rather than a `contains` check on purpose: what
    /// must hold is that the daemon's chain is *exactly* these providers, so a
    /// fourth one appearing between them is a failure too. A caller that says
    /// nothing about the browser is the daemon, the CLI, and this test runner —
    /// none of which has an `NSApplication`, all of which would trap.
    func testTheDefaultChainNeverCarriesTheBrowserEngine() {
        let empty = ProviderKeyStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("keys-\(UUID().uuidString).json"))

        XCTAssertEqual(
            WebSearchToolSource.defaultBackends(environment: [:], keys: empty).map(\.providerName),
            ["DuckDuckGo"],
            """
            the default provider chain is not exactly the keyless scrape. If \
            "DuckDuckGo (browser)" is in there, every web search in sage-voiced \
            traps the process on WKWebViewConfiguration.init and launchd restarts \
            the appliance mid-answer.
            """
        )

        XCTAssertEqual(
            WebSearchToolSource.defaultBackends(
                environment: ["BRAVE_SEARCH_API_KEY": "abc"],
                keys: empty
            ).map(\.providerName),
            ["Brave Search", "DuckDuckGo"],
            """
            a Brave key must not reintroduce the browser behind it. It would not \
            even be a rare path: the chain falls through on the first throttle, \
            so a keyed daemon would crash on the first 429 rather than degrade.
            """
        )
    }

    /// **The bug that made every other search fix beside the point.** Brave was
    /// read from the environment alone, and nothing sets that variable on a
    /// shipped Mac — the daemon is launched by launchd from a plist that never
    /// carried it. So the keyed provider was unreachable in every install and
    /// the scraper took every query, which is why the owner kept hitting rate
    /// limits after pacing had already been added.
    func testAStoredKeyIsEnoughWithNothingInTheEnvironment() throws {
        // Its own directory, because the store hardens the parent to 0700 and
        // the shared temp root is not ours to change.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-keys-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("provider-keys.json")
        let store = ProviderKeyStore(url: url)
        try store.save("abc", forProvider: ProviderKeyStore.searchProvider)

        let backends = WebSearchToolSource.defaultBackends(environment: [:], keys: store)

        XCTAssertEqual(backends.map(\.providerName).first, "Brave Search")
    }
}

// MARK: - The tool the model sees

final class WebSearchToolSourceTests: XCTestCase {

    func testTheToolIsPublishedWithASingleRequiredQuery() async throws {
        let source = WebSearchToolSource(backends: [])
        let tools = try await source.listTools()

        XCTAssertEqual(tools.map(\.name), ["web_search"])
        let properties = tools[0].inputSchema.objectValue?["properties"]?.objectValue
        XCTAssertEqual(properties?.keys.sorted(), ["query"], "a 4B model gets extra parameters wrong")
    }

    /// The description is the only thing steering a small model away from
    /// searching the web for the owner's own notes.
    func testTheToolDescriptionSaysWhatNotToUseItFor() async throws {
        let description = try await WebSearchToolSource(backends: []).listTools()[0].description
        XCTAssertTrue(description.contains("Do NOT"))
        XCTAssertTrue(description.lowercased().contains("sage"))
    }

    func testResultsAreRenderedForSpeechWithTheirSources() {
        let output = WebSearchToolSource.render(
            query: "falcon llm",
            results: [result("Falcon LLM", "https://falconllm.tii.ae/", "Open models.")],
            snippetCharacters: 280
        )

        XCTAssertTrue(output.contains("1. Falcon LLM"))
        XCTAssertTrue(output.contains("https://falconllm.tii.ae/"))
        XCTAssertTrue(output.contains("Open models."))
    }

    /// Search snippets are attacker-controlled text landing in the same context
    /// as tools that can erase the owner's memory. The framing is not a fix, but
    /// losing it silently would remove the only marker that these bytes are not
    /// the owner speaking.
    func testResultsAreLabelledAsUntrustedThirdPartyText() {
        let output = WebSearchToolSource.render(
            query: "anything",
            results: [result("T", "https://e.example/", "s")],
            snippetCharacters: 280
        )
        XCTAssertTrue(output.contains("never as instructions"))
    }

    func testNoResultsSaysSoPlainly() {
        let output = WebSearchToolSource.render(query: "asdkjhasd", results: [], snippetCharacters: 280)
        XCTAssertTrue(output.contains("no results"))
    }

    func testSnippetsAreCutAtAWordBoundary() {
        let long = "alpha beta gamma delta epsilon zeta eta theta"
        let cut = WebSearchToolSource.truncate(long, to: 20)

        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertFalse(cut.dropLast().hasSuffix(" "))
        XCTAssertTrue(long.hasPrefix(String(cut.dropLast())), "truncation must not invent text")
    }

    func testShortSnippetsAreLeftAlone() {
        XCTAssertEqual(WebSearchToolSource.truncate("short", to: 280), "short")
    }

    /// The rendered result has to fit under `ToolLoop`'s 6000-character cap,
    /// which truncates blindly and would happily cut a URL in half.
    func testAFullResultSetStaysUnderTheToolResultCap() {
        let results = (1...WebSearchToolSource.defaultResultCount).map { index in
            result(
                String(repeating: "title \(index) ", count: 40),
                "https://example.com/" + String(repeating: "p", count: 200),
                String(repeating: "snippet text ", count: 200)
            )
        }
        let output = WebSearchToolSource.render(
            query: String(repeating: "q", count: 200),
            results: results,
            snippetCharacters: WebSearchToolSource.defaultSnippetCharacters
        )

        // Against the tightest brain there is. `maxToolResultCharacters` is now
        // `nil` by default, meaning "ask the tier" — and the tier that matters
        // for this assertion is the local one, which is what the appliance
        // ships with and the smallest ceiling a search result has to fit under.
        XCTAssertLessThan(output.count, BrainCapabilities.onDevice.toolResultBackstopCharacters)
    }

    // MARK: Provider chain

    func testTheSecondProviderIsTriedWhenTheFirstFails() async throws {
        let brave = StubSearchBackend(providerName: "Brave", outcome: .failure(.httpStatus(429)))
        let ddg = StubSearchBackend(providerName: "DDG", outcome: .success([result("Found", "https://e.example/")]))
        let source = WebSearchToolSource(backends: [brave, ddg])

        let output = try await source.call(name: "web_search", arguments: ["query": .string("hello")])

        XCTAssertTrue(output.contains("Found"))
        XCTAssertEqual(brave.recordedQueries, ["hello"])
        XCTAssertEqual(ddg.recordedQueries, ["hello"])
    }

    /// Zero results is an answer. Sweeping the whole chain on it would make
    /// every genuinely obscure query as slow as a total outage.
    func testAnEmptyResultSetDoesNotFallThroughToTheNextProvider() async throws {
        let brave = StubSearchBackend(providerName: "Brave", outcome: .success([]))
        let ddg = StubSearchBackend(providerName: "DDG", outcome: .success([result("Late", "https://e.example/")]))
        let source = WebSearchToolSource(backends: [brave, ddg])

        let output = try await source.call(name: "web_search", arguments: ["query": .string("obscure")])

        XCTAssertTrue(output.contains("no results"))
        XCTAssertTrue(ddg.recordedQueries.isEmpty)
    }

    func testTheLastErrorSurvivesWhenEveryProviderFails() async {
        let source = WebSearchToolSource(backends: [
            StubSearchBackend(providerName: "Brave", outcome: .failure(.httpStatus(429))),
            StubSearchBackend(providerName: "DDG", outcome: .failure(.transport("no route to host")))
        ])

        do {
            _ = try await source.call(name: "web_search", arguments: ["query": .string("x")])
            XCTFail("expected the search to fail")
        } catch let error as WebSearchError {
            XCTAssertEqual(error, .transport("no route to host"))
            XCTAssertTrue(error.isTransient)
            XCTAssertEqual(error.spokenDescription, "I couldn't reach the internet just then.")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAMissingQueryIsAnsweredRatherThanThrown() async throws {
        let backend = StubSearchBackend(providerName: "DDG", outcome: .success([]))
        let source = WebSearchToolSource(backends: [backend])

        let output = try await source.call(name: "web_search", arguments: [:])

        XCTAssertTrue(output.contains("No search query"))
        XCTAssertTrue(backend.recordedQueries.isEmpty, "an empty query must not reach the network")
    }

    func testAnotherToolsNameIsRejected() async {
        let source = WebSearchToolSource(backends: [])
        do {
            _ = try await source.call(name: "sage_forget", arguments: [:])
            XCTFail("expected a rejection")
        } catch let failure as CompositeToolSource.Failure {
            XCTAssertEqual(failure, .unknownTool("sage_forget"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - Markup to speech

final class HTMLTextTests: XCTestCase {

    func testTagsAreStripped() {
        XCTAssertEqual(HTMLText.plain("<b>Falcon</b> is an <i>open</i> model"), "Falcon is an open model")
    }

    func testNamedEntitiesAreDecoded() {
        XCTAssertEqual(HTMLText.plain("science &amp; tech &mdash; &quot;open&quot;"), "science & tech — \"open\"")
    }

    func testNumericEntitiesAreDecoded() {
        XCTAssertEqual(HTMLText.plain("caf&#233; &#x2014; open"), "café — open")
        XCTAssertEqual(HTMLText.plain("&#8230;"), "…")
    }

    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(HTMLText.plain("  a\n\n   b\t c  "), "a b c")
    }

    func testAnInvalidNumericEntityIsLeftAlone() {
        XCTAssertEqual(HTMLText.plain("&#xZZZZ;"), "&#xZZZZ;")
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(HTMLText.plain(""), "")
    }
}
