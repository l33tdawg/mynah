import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Web search through Brave's Search API.
///
/// The upgrade path from the keyless scraper: a documented JSON contract that
/// does not break when someone restyles a page, an independent index rather
/// than a reseller's, and a free tier that covers an appliance one person talks
/// to. It needs a key, which is exactly why it is not the default — see
/// `DuckDuckGoSearchBackend` on why an errand-gated feature stays off.
///
/// Configured, this takes precedence. Search quality is the whole product here:
/// a spoken answer is built from the snippets, so a better snippet is a better
/// answer, and there is no page for the owner to scroll past a bad one.
public struct BraveSearchBackend: WebSearchBackend {

    public let providerName = "Brave Search"

    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.search.brave.com/res/v1/web/search")!,
        timeout: TimeInterval = 12,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.session = session ?? WebSearchHTTP.makeSession(timeout: timeout)
    }

    /// Reads the key from the environment, or returns nil so the caller can
    /// fall back rather than fail.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BraveSearchBackend? {
        let key = environment["BRAVE_SEARCH_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }
        return BraveSearchBackend(apiKey: key)
    }

    public func search(query: String, count: Int) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.emptyQuery }
        guard !apiKey.isEmpty else { throw WebSearchError.missingCredential(providerName) }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw WebSearchError.transport("bad endpoint \(endpoint)")
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            // Brave caps this at 20; the appliance never wants more than a
            // handful, since every result is context a 4B model has to read.
            URLQueryItem(name: "count", value: String(max(1, min(count, 20))))
        ]
        guard let url = components.url else {
            throw WebSearchError.transport("could not build search URL")
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebSearchError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebSearchError.httpStatus(http.statusCode)
        }

        return try Self.parse(data: data, limit: count)
    }

    static func parse(data: Data, limit: Int) throws -> [WebSearchResult] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw WebSearchError.unparseableResponse(error.localizedDescription)
        }

        // A missing `web` block is a valid Brave response — it means the query
        // only matched other result types — so it is zero results, not a fault.
        let results = payload.web?.results ?? []
        return results.prefix(limit).map { result in
            WebSearchResult(
                title: HTMLText.plain(result.title),
                url: result.url,
                // Brave marks query terms with <strong> in descriptions.
                snippet: HTMLText.plain(result.description ?? "")
            )
        }
    }

    /// Only the three fields that survive being read aloud. Brave returns far
    /// more; `Decodable` ignores the rest, so new fields cannot break this.
    private struct Payload: Decodable {
        struct Web: Decodable {
            struct Result: Decodable {
                let title: String
                let url: String
                let description: String?
            }
            let results: [Result]
        }
        let web: Web?
    }
}
