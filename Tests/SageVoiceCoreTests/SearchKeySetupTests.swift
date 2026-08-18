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

/// Connecting a search provider, and keeping it out of the brain vocabulary.
///
/// The key slot for Brave has existed in `ProviderKeyStore` for weeks with no
/// way to fill it: no field in Settings, and a CLI that refuses the identifier
/// twice. So the daemon's chain began at the keyless scraper on every install —
/// the owner's *"still hitting rate limits"*, which no amount of pacing could
/// fix, because pacing cannot buy a quota.
final class SearchKeySetupTests: XCTestCase {

    private func scratchStore() -> ProviderKeyStore {
        ProviderKeyStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-searchkey-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("provider-keys.json"))
    }

    // MARK: Connecting

    func testAWorkingTokenIsVerifiedAndSaved() async {
        let store = scratchStore()
        let outcome = await SearchKeySetup.connect("  tok-123  ", into: store, save: true) { key in
            // Trimmed before it reaches the service, so a token pasted with a
            // trailing newline is not rejected for it.
            XCTAssertEqual(key, "tok-123")
        }

        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(
            store.key(forProvider: ProviderKeyStore.searchProvider, environment: [:]),
            "tok-123"
        )
    }

    /// A token the service rejects is never written.
    ///
    /// The important half: a bad key saved is worse than none, because the chain
    /// then spends its first provider on a guaranteed failure before falling
    /// through to the scrape it would have used anyway.
    ///
    /// **Throws a real refusal.** This used to throw an anonymous stub error,
    /// which is a fine stand-in for "something went wrong" and a useless one
    /// here: it bridges to a non-URL domain, so it took the reject branch
    /// whether the transport classifier existed or not. That is how the dead
    /// classifier shipped.
    ///
    /// 401 rather than 422 on purpose, so the two are covered separately —
    /// `testARefusedTokenIsNotMistakenForANetworkProblem` carries 422, which is
    /// the status Brave really sends and the one a later round found on the
    /// wrong side of the classifier.
    func testARejectedTokenIsNotSaved() async {
        let store = scratchStore()
        let outcome = await SearchKeySetup.connect("nope", into: store, save: true) { _ in
            throw WebSearchError.httpStatus(401)
        }

        guard case .rejected = outcome else {
            return XCTFail("a rejected token reported \(outcome)")
        }
        XCTAssertNil(
            store.key(forProvider: ProviderKeyStore.searchProvider, environment: [:]),
            "a token the service refused was stored anyway"
        )
    }

    // MARK: Told apart: a bad token and an unreachable service

    /// **Fed the exact values `BraveSearchBackend` throws, not invented ones.**
    ///
    /// The first version of this classifier tested for `NSURLErrorDomain`, which
    /// is what URLSession raises — and none of those ever reaches it, because
    /// `BraveSearchBackend` catches every one and rethrows
    /// `WebSearchError.transport`. So it returned false for every error the
    /// shipped binary can produce: the branch was dead, the key was still
    /// thrown away, and nothing failed.
    ///
    /// Nothing failed because nothing tested it. The rejection test used to
    /// throw an anonymous stub error, which bridges to a non-URL domain and so
    /// passed identically with the classifier present or deleted.
    ///
    /// These use the real cases from the real backend, taken from the seven
    /// `throw WebSearchError...` sites in BraveSearchBackend.swift.
    func testAnUnreachableServiceIsNotEvidenceAboutTheToken() {
        // BraveSearchBackend.swift:72 — every URLSession failure becomes this.
        XCTAssertTrue(
            SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(
                WebSearchError.transport("The Internet connection appears to be offline.")
            ),
            """
            a transport failure is being read as the token being wrong. This is \
            the exact error the production path produces when the connection is \
            down, so the owner's good key is discarded and he is told to check \
            he copied it properly.
            """
        )
        // :87 — a captive portal or a redesigned page.
        XCTAssertTrue(
            SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(
                WebSearchError.unparseableResponse("not JSON")
            )
        )
        // :76 — throttled, or the service having an outage.
        XCTAssertTrue(SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(WebSearchError.httpStatus(429)))
        XCTAssertTrue(SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(WebSearchError.httpStatus(503)))
    }

    /// And the answers that ARE about the token.
    ///
    /// **422 first, because it is the one Brave actually sends.** Brave's Web
    /// Search endpoint documents 200, 404, 422 and 429 — no 401, no 403 — and a
    /// wrong or wrong-endpoint subscription token comes back
    /// `422 SUBSCRIPTION_TOKEN_INVALID`, which Brave's own payload tags
    /// `"component": "authentication"`. A classifier that recognised only
    /// 401/403 as refusals therefore stored the bad token and told the owner the
    /// service was unreachable. Found by the fourth review round, which checked
    /// Brave's documentation rather than assuming the usual statuses.
    func testARefusedTokenIsNotMistakenForANetworkProblem() {
        XCTAssertFalse(
            SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(WebSearchError.httpStatus(422)),
            """
            422 is what Brave sends for an invalid subscription token, and it is \
            being read as a network problem — so a mistyped token is stored, \
            announced as an outage, and put at the head of the daemon's search \
            chain where it costs a doomed request on every later search.
            """
        )
        XCTAssertFalse(
            SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(WebSearchError.httpStatus(401)),
            "a token the service rejected is being kept and called a network problem"
        )
        XCTAssertFalse(SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(WebSearchError.httpStatus(403)))
        // Anything else a service says to refuse a request is about the request,
        // not the wire. Only "not now" is the wire.
        XCTAssertFalse(SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(WebSearchError.httpStatus(400)))
        XCTAssertFalse(SearchKeySetup.looksLikeTheNetworkRatherThanTheToken(WebSearchError.httpStatus(404)))
    }

    /// And end to end, because the classifier being right is not the property
    /// that matters — the bad key not being stored is.
    func testAnInvalidTokenIsNotStored() async {
        let store = scratchStore()
        let outcome = await SearchKeySetup.connect("mistyped", into: store, save: true) { _ in
            throw WebSearchError.httpStatus(422)
        }

        guard case .rejected = outcome else {
            return XCTFail("an invalid token reported \(outcome), so a dead key is now first in the search chain")
        }
        XCTAssertNil(store.key(forProvider: ProviderKeyStore.searchProvider, environment: [:]))
    }

    /// End to end: the outcome the owner actually gets, on the real error.
    ///
    /// The classifier being right is not the property that matters — the
    /// property that matters is that his key survives. Asserted through
    /// `connect`, so a correct classifier wired up wrongly still fails.
    func testAGoodTokenSurvivesAnOutageAndIsSaved() async {
        let store = scratchStore()
        let outcome = await SearchKeySetup.connect("tok-123", into: store, save: true) { _ in
            throw WebSearchError.transport("The Internet connection appears to be offline.")
        }

        guard case .savedUnchecked = outcome else {
            return XCTFail("a good token during an outage reported \(outcome), so it was thrown away")
        }
        XCTAssertEqual(
            store.key(forProvider: ProviderKeyStore.searchProvider, environment: [:]),
            "tok-123",
            "the key was not saved, so the owner has to find his token again once the connection is back"
        )
    }

    /// Without `--save` an outage says so rather than blaming the token.
    func testAnOutageWithoutSaveSaysItCouldNotCheck() async {
        let store = scratchStore()
        let outcome = await SearchKeySetup.connect("tok-123", into: store, save: false) { _ in
            throw WebSearchError.transport("offline")
        }

        guard case .couldNotCheck = outcome else {
            return XCTFail("an outage reported \(outcome) instead of saying it could not check")
        }
        XCTAssertFalse(outcome.isUsable)
    }

    func testWithoutSaveItIsCheckedAndDiscarded() async {
        let store = scratchStore()
        let outcome = await SearchKeySetup.connect("tok-123", into: store, save: false) { _ in }

        XCTAssertEqual(outcome, .verifiedButNotSaved)
        XCTAssertNil(store.key(forProvider: ProviderKeyStore.searchProvider, environment: [:]))
    }

    func testAnEmptyTokenIsRefusedBeforeTheServiceIsAsked() async {
        let store = scratchStore()
        var asked = false
        let outcome = await SearchKeySetup.connect("   ", into: store, save: true) { _ in asked = true }

        XCTAssertEqual(outcome, .empty)
        XCTAssertFalse(asked, "an empty token was sent to the service, spending a request to learn nothing")
    }

    // MARK: The name the owner will actually type

    /// `brave-search` is what the store calls it and nobody would guess it.
    func testTheObviousSpellingsResolve() {
        XCTAssertTrue(SearchKeySetup.resolvesToSearchProvider("brave-search"))
        XCTAssertTrue(SearchKeySetup.resolvesToSearchProvider("brave"))
        XCTAssertTrue(SearchKeySetup.resolvesToSearchProvider("search"))
        XCTAssertTrue(SearchKeySetup.resolvesToSearchProvider("Brave"))

        XCTAssertFalse(SearchKeySetup.resolvesToSearchProvider("gemini"))
        XCTAssertFalse(SearchKeySetup.resolvesToSearchProvider("anthropic"))
    }

    /// The identifier it stores under is the one the chain reads.
    ///
    /// Two constants that must agree, in two files, with nothing else checking.
    func testItStoresUnderTheIdentifierTheChainLooksFor() async {
        let store = scratchStore()
        _ = await SearchKeySetup.connect("tok-123", into: store, save: true) { _ in }

        XCTAssertEqual(
            WebSearchToolSource.defaultBackends(environment: [:], keys: store).map(\.providerName),
            ["Brave Search", "DuckDuckGo"],
            "a saved search key did not change the provider chain, so connecting it accomplishes nothing"
        )
    }

    // MARK: Not a brain

    /// **Search must stay out of the brain vocabulary.**
    ///
    /// `APIKeyOnboarding.keyedProviders` is walked by tests that assert every
    /// entry names a model and states a cost, and `makeBackend` builds a
    /// `BrainBackend` from every identifier it accepts. Brave is neither, so it
    /// lives in its own type — and this asserts the separation rather than
    /// leaving it to the fact that nobody has added it yet.
    func testBraveIsNotABrainProvider() {
        XCTAssertNil(
            APIKeyOnboarding.instructions(forProvider: ProviderKeyStore.searchProvider),
            "the search provider has been added to the brain vocabulary"
        )
        XCTAssertFalse(
            APIKeyOnboarding.keyedProviders.contains(ProviderKeyStore.searchProvider),
            "the search provider is being listed as a brain the owner could choose"
        )
    }

    /// And Settings must not file it under Brain.
    ///
    /// The row this feeds says "Keys saved on this Mac" under the Brain heading,
    /// and it is shown exactly when the brain choice was never recorded — so it
    /// is the one statement on that screen the owner has to take on trust. Left
    /// unfiltered, connecting search on a Mac with no brain would produce a
    /// Brain group announcing he had one.
    ///
    /// **Read as a source scan, not as a re-implementation.** The first version
    /// of this test wrote out the filter expression again — `stored.keys.filter
    /// { APIKeyOnboarding.instructions(forProvider: $0) != nil }` — and asserted
    /// on *that*. It passed with the production filter deleted, because it never
    /// touched the production filter: it proved only that the expression the
    /// test itself had just written did what the test said. Found by the 1.7.3
    /// review. A guard that cannot fail is worse than no guard, because it is
    /// read as coverage.
    ///
    /// `SettingsModel.providersWithKeys` cannot be called directly — it reads
    /// `KeyStorage.load()` from a fixed path with nothing injectable — so what
    /// is checkable is that the filter is still *in* it. Both halves are
    /// asserted: the production property still filters, and the filter's
    /// predicate really does exclude the search key.
    func testAStoredSearchKeyIsNotShownAsABrain() throws {
        // Half one: the predicate genuinely separates them. Not a
        // re-implementation of the filter — this is the fact the filter relies
        // on, stated against the two real identifiers.
        XCTAssertNil(
            APIKeyOnboarding.instructions(forProvider: ProviderKeyStore.searchProvider),
            "the search provider now has brain instructions, so filtering by them would no longer exclude it"
        )
        XCTAssertNotNil(
            APIKeyOnboarding.instructions(forProvider: "deepseek"),
            "a real brain has no instructions, so the filter would hide brains the owner does have"
        )

        // Half two: the production property still applies it. This is the part
        // the earlier version could not fail on.
        let settings = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/SettingsView.swift"),
            encoding: .utf8
        )
        let scan = SwiftSourceScan(settings)
        let declaration = try XCTUnwrap(
            scan.indices(of: "var providersWithKeys: [String] {").first,
            "providersWithKeys is gone from SettingsView, so this guard is reading for something that no longer exists"
        )
        // **The property's real body, by brace matching.**
        //
        // This read a fixed 260 characters from the declaration, which is the
        // distance-guessing `SwiftSourceScan` exists to abolish: measured
        // against today's formatting, it overshot the body by about ninety
        // characters, so a filter written in whatever happens to follow would
        // have satisfied it. `block(from:)` balances braces and knows where the
        // property actually ends.
        let bodyRange = try XCTUnwrap(
            scan.block(from: declaration),
            "could not find the body of providersWithKeys, so this guard cannot say what is in it"
        )
        let body = scan.text(in: bodyRange)

        XCTAssertTrue(
            body.contains("APIKeyOnboarding.instructions(forProvider:"),
            """
            SettingsView.providersWithKeys no longer filters by brain instructions, so \
            the Brain group will list every stored key as a brain — telling an owner who \
            connected only web search that he has a brain called Brave Search, on the row \
            that exists because nothing else on that screen knows what the brain is.
            """
        )
    }
}
#endif  // os(macOS)
