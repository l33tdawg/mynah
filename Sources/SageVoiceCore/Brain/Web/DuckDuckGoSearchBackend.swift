import Foundation

/// Keyless web search, by scraping DuckDuckGo's no-JavaScript HTML endpoint.
///
/// This exists so the appliance can answer a question about the world on the
/// day it is installed, with no account, no billing page and no key pasted into
/// a config file. That matters more than it sounds: every keyed provider turns
/// "give it web search" into a twenty-minute errand, and a feature behind an
/// errand is a feature most owners never switch on.
///
/// The cost is honest and worth stating: this parses a page that is not a
/// contract. DuckDuckGo can restyle it, gate it behind a challenge, or start
/// rate-limiting this machine's IP, and any of those breaks search without
/// breaking the build. That is why `BraveSearchBackend` exists alongside it,
/// why parse failure is a distinct error from "no results", and why the
/// provider name is spoken in the output — when this rots, it should be
/// obvious *which* thing rotted.
public struct DuckDuckGoSearchBackend: WebSearchBackend {

    public let providerName = "DuckDuckGo"

    private let endpoint: URL
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "https://html.duckduckgo.com/html/")!,
        timeout: TimeInterval = 12,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.session = session ?? WebSearchHTTP.makeSession(timeout: timeout)
    }

    public func search(query: String, count: Int) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.emptyQuery }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // A blank User-Agent gets a challenge page rather than results. This is
        // a plain desktop string; nothing here is trying to look like a browser
        // it is not, and the query is the only thing sent.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = Self.formBody(["q": trimmed])

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

        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.unparseableResponse("response was not UTF-8")
        }

        return try Self.parse(html: html, limit: count)
    }

    // MARK: - Parsing

    /// Pulls results out of the HTML result page.
    ///
    /// Not a real HTML parser and does not need to be — it looks for the two
    /// class names DuckDuckGo's lite page has used for years and ignores
    /// everything else on the page.
    static func parse(html: String, limit: Int) throws -> [WebSearchResult] {
        let links = matches(in: html, pattern: #"<a\s([^>]*class="[^"]*result__a[^"]*"[^>]*)>(.*?)</a>"#)
        let snippets = matches(in: html, pattern: #"<a\s[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>"#)

        guard !links.isEmpty else {
            // Distinguishing these two is the whole reason this is a throw and
            // not an empty array. "Nothing matched your query" is an answer;
            // "DuckDuckGo served us a challenge page" is a fault, and telling
            // the owner the first when it was the second sends them looking for
            // a better query instead of a broken scraper.
            if Self.looksLikeAResultsPage(html) {
                return []
            }
            throw WebSearchError.unparseableResponse(
                "no result markup on the page — DuckDuckGo may be challenging or rate-limiting this machine"
            )
        }

        var results: [WebSearchResult] = []
        for (index, link) in links.enumerated() where results.count < limit {
            guard
                let attributes = link.group(1),
                let rawHref = firstGroup(in: attributes, pattern: #"href="([^"]*)""#),
                let title = link.group(2).map({ HTMLText.plain($0) }),
                !title.isEmpty
            else { continue }

            let url = unwrapRedirect(HTMLText.decodeEntities(rawHref))
            guard let url, !url.isEmpty else { continue }

            // Results and snippets appear in the same document order, one each,
            // so index alignment holds. If a result somehow has no snippet the
            // pairing after it would shift — a missing snippet is worth less
            // than a wrong one, so a short list just yields empty text.
            let snippet = index < snippets.count
                ? snippets[index].group(1).map { HTMLText.plain($0) } ?? ""
                : ""

            results.append(WebSearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// True when this is a genuine result page that simply found nothing.
    static func looksLikeAResultsPage(_ html: String) -> Bool {
        html.contains("no-results")
            || html.contains("No results found")
            || html.contains("results.js")
    }

    /// DuckDuckGo wraps outbound links as `//duckduckgo.com/l/?uddg=<encoded>`.
    ///
    /// The wrapper is useless to speak aloud and useless to the model, so it is
    /// unwrapped back to the real destination. Anything unrecognised is passed
    /// through rather than dropped.
    static func unwrapRedirect(_ href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard
            absolute.contains("duckduckgo.com/l/"),
            let components = URLComponents(string: absolute),
            let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else {
            return absolute
        }
        return target
    }

    // MARK: - Small helpers

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(escaped)"
        }
        return encoded.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static func matches(in text: String, pattern: String) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { RegexMatch(match: $0, source: text) }
    }

    private static func firstGroup(in text: String, pattern: String) -> String? {
        matches(in: text, pattern: pattern).first?.group(1)
    }

    struct RegexMatch {
        let match: NSTextCheckingResult
        let source: String

        func group(_ index: Int) -> String? {
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: source) else { return nil }
            return String(source[range])
        }
    }
}
