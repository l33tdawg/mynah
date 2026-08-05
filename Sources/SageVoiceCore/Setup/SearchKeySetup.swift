import Foundation

/// Connecting a search provider, which is not a brain and needs its own door.
///
/// ## Why this is not in `APIKeyOnboarding`
///
/// That type is the brain vocabulary — `keyedProviders` is walked by tests that
/// assert every entry names a model and states a cost, and `makeBackend` builds
/// a `BrainBackend` from every identifier it accepts. Brave Search is neither.
/// Adding it there would have made every one of those statements false about one
/// member.
///
/// ## Why it exists at all
///
/// Because the key had no reachable door. `ProviderKeyStore` has held a
/// `brave-search` slot for weeks and nothing could write it: no Settings field
/// anywhere in the app, and the CLI's `key` command refuses the identifier twice
/// over — once at the instructions lookup, again at the backend build. The
/// stored slot was real, documented and unreachable.
///
/// That mattered more than it looked. With no key, the daemon's provider chain
/// begins at the keyless scraper, which is the thing most likely to be handed a
/// challenge page — the owner's *"still hitting rate limits"*, twice, after
/// pacing had already been added. Pacing cannot fix a provider with no quota.
///
/// It matters more still now: the browser engine that used to sit in front of
/// the scraper has been removed from the daemon's chain, because it trapped the
/// process. Stopping the crash without restoring a working search would leave
/// the appliance alive and unable to look anything up.
public enum SearchKeySetup {

    /// What the owner is told, in the same shape as a brain provider's, so the
    /// CLI can print either through one path.
    public static let instructions = APIKeyOnboarding.Instructions(
        providerName: "Brave Search",
        keyPageURL: URL(string: "https://api-dashboard.search.brave.com/app/keys")!,
        steps: [
            "Open the Brave Search API dashboard and sign in.",
            "Subscribe to the free \"Data for Search\" plan.",
            "Create a subscription token and copy it."
        ],
        looksLikeHint: "It is a short string of letters, numbers and dashes.",
        costNote: "The free tier is enough for one person and does not ask for a card."
    )

    /// The identifiers a person might reasonably type for this.
    ///
    /// `brave-search` is what the store calls it, and nobody would guess that.
    /// A command that dead-ends on the obvious spelling is a command that does
    /// not exist, so the obvious spellings resolve.
    public static func resolvesToSearchProvider(_ identifier: String) -> Bool {
        ["brave-search", "brave", "search"].contains(identifier.lowercased())
    }

    public enum Outcome: Equatable, Sendable {
        case saved
        case verifiedButNotSaved
        /// Saved without a successful check, because the check could not be
        /// made. See `couldNotCheck`.
        case savedUnchecked(String)
        case empty
        case rejected(String)
        case couldNotCheck(String)
        case couldNotSave(String)

        public var isUsable: Bool {
            switch self {
            case .saved, .verifiedButNotSaved, .savedUnchecked: return true
            case .empty, .rejected, .couldNotCheck, .couldNotSave: return false
            }
        }
    }

    /// Whether a failure means "your token is wrong" or "I could not ask".
    ///
    /// **The difference reaches the owner, and getting it wrong throws his key
    /// away.** Every failure used to be reported as `rejected` — *"Brave Search
    /// did not accept that token"* — and refused to save. So connecting a
    /// perfectly good key on a flaky connection, on a plane, or while Brave was
    /// having an outage told him his token was bad and discarded it. He would
    /// then go and generate another one, which would also be "refused".
    ///
    /// A transport failure is not evidence about the token. It is evidence about
    /// the network, and the honest thing is to say so and keep the key.
    ///
    /// ## The first version of this could never return true
    ///
    /// It tested `(error as NSError).domain == NSURLErrorDomain`, reasoning that
    /// URLSession failures arrive that way. They do — and none of them reaches
    /// here, because `BraveSearchBackend` catches every one and rethrows
    /// `WebSearchError.transport(error.localizedDescription)`. `WebSearchError`
    /// is a plain Swift enum, so its bridged domain is the mangled type name and
    /// never `NSURLErrorDomain`.
    ///
    /// So the guard returned false for every error the shipped binary can
    /// produce: `savedUnchecked` and `couldNotCheck` were unreachable, the key
    /// was still discarded, and the message was now *more* confident about the
    /// wrong diagnosis than before the repair. Found by the third review round,
    /// which compiled the enum standalone to check the bridging rather than
    /// reasoning about it. A guard that cannot fire, in a fix for a usability
    /// defect — and no test touched it, which is why it went unnoticed.
    ///
    /// It classifies on the error the production path actually throws now.
    static func looksLikeTheNetworkRatherThanTheToken(_ error: Error) -> Bool {
        if let search = error as? WebSearchError {
            switch search {
            case .transport, .unparseableResponse:
                // Could not reach the provider, or reached something that was
                // not the provider — a captive portal, a proxy error page.
                // Neither says anything about the token.
                return true
            case .httpStatus(let code):
                // **Only "not now" counts as the network. Every other refusal is
                // about the token.**
                //
                // The first version of this said `code != 401 && code != 403`,
                // on the reasoning that those two are how a service rejects a
                // credential. Brave does not use them: its Web Search endpoint
                // documents 200, 404, 422 and 429, and a wrong or wrong-endpoint
                // subscription token comes back
                // `422 SUBSCRIPTION_TOKEN_INVALID` — tagged, in Brave's own
                // payload, `"component": "authentication"`. So the one answer
                // this exists to catch fell on the wrong side of it: a mistyped
                // token was stored, announced as an outage, and installed at the
                // head of the daemon's chain, where it costs a doomed request
                // and a 1.5s pacing slot on every search thereafter. Round two's
                // broken classifier got this right by accident, because it sent
                // everything to `rejected`.
                //
                // Inverted, so an unrecognised refusal discards the key. That
                // matches the asymmetry this file argues elsewhere: a wrongly
                // kept bad key costs every later search, a wrongly discarded
                // good one costs one re-paste.
                return code == 429 || (500...599).contains(code)
            case .emptyQuery, .missingCredential:
                // Neither can occur here — `connect` rejects an empty key before
                // verifying, and the key is passed explicitly — but if one did,
                // it is our bug rather than the network's.
                return false
            }
        }
        // Kept for any caller that verifies without going through
        // `BraveSearchBackend`, where a raw URLSession error would arrive.
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// Checks a token against the real service, then stores it.
    ///
    /// - Parameter verify: performing a real search is the check, deliberately.
    ///   There is no shape to validate — a Brave token is an opaque string, so
    ///   the only question worth asking is whether the service accepts it, and
    ///   the answer is worth one query. Injected so the test suite spends no
    ///   quota and needs no network.
    /// - Parameter save: whether to keep it, or only report that it works.
    public static func connect(
        _ raw: String,
        into store: ProviderKeyStore,
        save: Bool,
        verify: (String) async throws -> Void
    ) async -> Outcome {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .empty }

        var unchecked: String?
        do {
            try await verify(key)
        } catch {
            // A token the service refused is a token to throw away. A token we
            // could not ask about is not — see
            // `looksLikeTheNetworkRatherThanTheToken`.
            guard Self.looksLikeTheNetworkRatherThanTheToken(error) else {
                return .rejected("\(error)")
            }
            guard save else { return .couldNotCheck("\(error)") }
            unchecked = "\(error)"
        }

        guard save else { return .verifiedButNotSaved }

        do {
            try store.save(key, forProvider: ProviderKeyStore.searchProvider)
            return unchecked.map { .savedUnchecked($0) } ?? .saved
        } catch {
            return .couldNotSave("\(error)")
        }
    }
}
