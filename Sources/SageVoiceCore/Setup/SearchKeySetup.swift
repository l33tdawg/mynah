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
    static func looksLikeTheNetworkRatherThanTheToken(_ error: Error) -> Bool {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { return false }
        // Anything URLSession itself raised: no connection, DNS, timeout, TLS.
        // An HTTP 401/403 does not arrive this way — `BraveSearchBackend` turns
        // those into its own error, which is a real rejection.
        return true
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
