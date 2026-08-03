#if canImport(WebKit)
import Foundation
import WebKit

/// Keyless search through a real browser engine instead of an HTTP scrape.
///
/// **The owner's call, and the reasoning behind it is sound:** *"why are we
/// using a scraper bro ? its running on the users machine right; just use links
/// or chrome headless browser"*.
///
/// He is right that a machine somebody owns can browse rather than impersonate.
/// Two corrections to the shape of it, both settled before writing this:
///
/// - **`links`/`lynx` would change nothing.** They are HTTP clients with a
///   distinctive User-Agent, which is what we already are. The block is not
///   about which program asks; it is about asking like a program.
/// - **Chrome headless is the expensive version.** It needs Chrome installed —
///   an assumption an appliance cannot make on somebody else's Mac — plus a
///   process to supervise and a debugging port to speak to. `WKWebView` is the
///   same capability already sitting in the OS: a real engine, a real TLS
///   fingerprint, a real cookie jar, nothing to install and nothing to ship.
///
/// ## Why it loads the same URL as the scraper
///
/// The obvious move is to browse the normal search page like a person. That
/// means parsing a JavaScript-rendered page whose markup changes whenever the
/// site is redesigned, which is a second fragile thing to own.
///
/// This loads exactly the endpoint the HTTP backend already loads, so
/// `DuckDuckGoSearchBackend.parse` reads it unchanged. Everything gained is at
/// the transport layer — the request now comes from WebKit, with WebKit's
/// headers, WebKit's TLS handshake and a cookie jar that persists across a turn
/// — which is the part the challenge page was reacting to. One new failure mode
/// instead of two.
///
/// ## What it costs
///
/// A page load rather than a request: roughly a second, against a turn that
/// already spends 40–60 s in the model. Bounded by `loadTimeout`, and the plain
/// HTTP backend stays behind it in the chain, so a Mac where WebKit will not
/// start is no worse off than before.
@MainActor
public final class BrowserSearchBackend: NSObject, WebSearchBackend {

    public nonisolated var providerName: String { "DuckDuckGo (browser)" }

    /// Long enough for a slow connection, short enough that a turn does not
    /// stall behind a page that will never finish.
    public static let loadTimeout: TimeInterval = 20

    private let endpoint: URL
    private var webView: WKWebView?
    private var pending: CheckedContinuation<Void, Error>?

    /// `nonisolated` so the provider chain can be assembled off the main actor —
    /// the daemon builds it during start-up, which is not a main-thread context.
    /// Only stored properties are touched here; everything that speaks to WebKit
    /// is isolated below.
    public nonisolated init(endpoint: URL = URL(string: "https://html.duckduckgo.com/html/")!) {
        self.endpoint = endpoint
        super.init()
    }

    public nonisolated func search(query: String, count: Int) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.emptyQuery }
        return try await load(query: trimmed, count: count)
    }

    private func load(query: String, count: Int) async throws -> [WebSearchResult] {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw WebSearchError.transport("bad endpoint \(endpoint)")
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            throw WebSearchError.transport("could not build a search URL")
        }

        // Rebuilt per search rather than held. A long-lived web view in a daemon
        // that runs for weeks accumulates whatever the last twenty pages left
        // behind, and the isolation is worth more here than the startup cost —
        // this is the owner's own searching, and one query must not be joinable
        // to the next.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        defer {
            view.navigationDelegate = nil
            webView = nil
            pending = nil
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.pending = continuation
                    view.load(URLRequest(url: url))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.loadTimeout))
                throw WebSearchError.transport("the page did not finish loading in time")
            }
            // First to finish wins; the other is cancelled. A timeout that let
            // the load keep running would leave a web view alive with nothing
            // holding it.
            try await group.next()
            group.cancelAll()
        }

        let html = try await outerHTML(of: view)
        return try DuckDuckGoSearchBackend.parse(html: html, limit: count)
    }

    private func outerHTML(of view: WKWebView) async throws -> String {
        let value = try await view.evaluateJavaScript("document.documentElement.outerHTML")
        guard let html = value as? String, !html.isEmpty else {
            throw WebSearchError.unparseableResponse("the page returned no markup")
        }
        return html
    }
}

extension BrowserSearchBackend: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pending?.resume()
        pending = nil
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        pending?.resume(throwing: WebSearchError.transport("\(error.localizedDescription)"))
        pending = nil
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        pending?.resume(throwing: WebSearchError.transport("\(error.localizedDescription)"))
        pending = nil
    }
}
#endif
