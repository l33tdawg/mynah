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

    private struct Refused: Error {}

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
    func testARejectedTokenIsNotSaved() async {
        let store = scratchStore()
        let outcome = await SearchKeySetup.connect("nope", into: store, save: true) { _ in
            throw Refused()
        }

        guard case .rejected = outcome else {
            return XCTFail("a rejected token reported \(outcome)")
        }
        XCTAssertNil(
            store.key(forProvider: ProviderKeyStore.searchProvider, environment: [:]),
            "a token the service refused was stored anyway"
        )
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
        let body = scan.text(in: declaration..<min(declaration + 260, scan.characters.count))

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
