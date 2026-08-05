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
        case empty
        case rejected(String)
        case couldNotSave(String)

        public var isUsable: Bool {
            switch self {
            case .saved, .verifiedButNotSaved: return true
            case .empty, .rejected, .couldNotSave: return false
            }
        }
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

        do {
            try await verify(key)
        } catch {
            return .rejected("\(error)")
        }

        guard save else { return .verifiedButNotSaved }

        do {
            try store.save(key, forProvider: ProviderKeyStore.searchProvider)
            return .saved
        } catch {
            return .couldNotSave("\(error)")
        }
    }
}
