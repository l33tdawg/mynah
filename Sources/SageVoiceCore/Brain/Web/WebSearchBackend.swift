import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One result as the appliance will speak it: a name, where it came from, and
/// enough text to answer with.
///
/// Deliberately not the union of every provider's fields. Ranking signals,
/// favicons, thumbnails and freshness scores are real, and none of them survive
/// being read aloud over Signal, so they are dropped at the boundary rather
/// than carried through the system unused.
public struct WebSearchResult: Sendable, Equatable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Where results come from.
///
/// The same seam as `BrainBackend`, for the same reason: the good providers
/// want an API key and the keyless one is a scraper on borrowed time. Neither
/// should be welded into the tool.
public protocol WebSearchBackend: Sendable {
    /// Named in the tool output, so the owner can hear which provider answered
    /// and knows where a wrong result came from.
    var providerName: String { get }

    func search(query: String, count: Int) async throws -> [WebSearchResult]
}

public enum WebSearchError: Error, CustomStringConvertible, Equatable {
    case emptyQuery
    case transport(String)
    case httpStatus(Int)
    /// The provider answered, but with something that is not a result page —
    /// a bot challenge, a redesign, a rate-limit interstitial.
    case unparseableResponse(String)
    case missingCredential(String)

    public var description: String {
        switch self {
        case .emptyQuery:
            return "search query was empty"
        case .transport(let detail):
            return "search request failed: \(detail)"
        case .httpStatus(let code):
            return "search provider returned HTTP \(code)"
        case .unparseableResponse(let detail):
            return "could not read the search provider's response: \(detail)"
        case .missingCredential(let name):
            return "no API key configured for \(name)"
        }
    }

    /// What the appliance says out loud. The owner is on a phone and cannot see
    /// a stack trace; they need to know whether to try again or stop asking.
    public var spokenDescription: String {
        switch self {
        case .emptyQuery:
            return "I didn't catch what to search for."
        case .transport:
            return "I couldn't reach the internet just then."
        case .httpStatus(429):
            return "Search is rate-limiting me — give it a minute."
        case .httpStatus:
            return "The search provider had a problem."
        case .unparseableResponse:
            return "Search answered with something I couldn't read."
        case .missingCredential:
            return "Web search isn't set up yet."
        }
    }

    /// Worth trying again on the next turn.
    public var isTransient: Bool {
        switch self {
        case .transport, .httpStatus:
            return true
        case .emptyQuery, .unparseableResponse, .missingCredential:
            return false
        }
    }
}

// MARK: - Shared HTTP session

enum WebSearchHTTP {
    /// Ordinary outbound session — emphatically *not* `LoopbackSecurity`'s.
    ///
    /// Everything else in this package talks to loopback and refuses redirects
    /// because the payload is the owner's transcript. A search query is also
    /// the owner's words, but the whole point is that it leaves the machine, so
    /// the loopback rule cannot apply. What still applies: no cookies, so
    /// queries cannot be stitched into a profile across turns.
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: configuration)
    }
}
