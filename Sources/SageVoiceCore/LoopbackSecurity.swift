import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Loopback enforcement for local-only AI services (ASR, TTS, the local model).
///
/// The product promise is that the owner's voice and words never leave the
/// machine. Two things are required to keep that true, and checking only the
/// first is the bug this type exists to prevent:
///
///  1. the endpoint we *dial* must be loopback, and
///  2. the endpoint we actually *talk to* must still be loopback after
///     URLSession has had its way with redirects.
///
/// `URLSession` follows 3xx redirects by default and re-sends the request body.
/// A hostile or compromised process listening on the configured port can
/// therefore answer `307 Location: https://evil.example/steal` and receive the
/// full request body — the owner's transcript — despite the initial URL having
/// passed a naive host check.
public enum LoopbackSecurity {

    public enum Violation: Error, CustomStringConvertible, Equatable {
        case nonLoopbackEndpoint(String)
        case redirectAttempted(from: String, to: String)

        public var description: String {
            switch self {
            case .nonLoopbackEndpoint(let url):
                return "refusing to use non-loopback endpoint: \(url)"
            case .redirectAttempted(let from, let to):
                return "refusing redirect from loopback \(from) to \(to)"
            }
        }
    }

    /// True only for plain-HTTP loopback hosts.
    ///
    /// Deliberately an exact host match. Tricks like `127.0.0.1.evil.com`,
    /// `127.0.0.1@evil.com` and the integer form `2130706433` all fail here.
    public static func isLoopback(_ url: URL?) -> Bool {
        guard let url, url.scheme == "http", let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    public static func requireLoopback(_ url: URL) throws {
        guard isLoopback(url) else {
            throw Violation.nonLoopbackEndpoint(url.absoluteString)
        }
    }

    /// A `URLSession` that refuses every redirect.
    ///
    /// Use this for any request carrying owner content to a local service.
    /// Refusing outright (rather than re-validating the target) is deliberate:
    /// a local AI service has no legitimate reason to redirect, so a redirect
    /// is either a misconfiguration or an exfiltration attempt, and both should
    /// be loud rather than silently followed.
    public static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(
            configuration: configuration,
            delegate: RedirectBlocker.shared,
            delegateQueue: nil
        )
    }

    /// A `URLSession` for a response that is *meant* to stay open.
    ///
    /// Same refusal of redirects, same absence of cookies and credentials. The
    /// one difference is the whole reason it exists: `makeSession(timeout:)`
    /// sets `timeoutIntervalForResource`, which is a ceiling on the *total*
    /// life of a transfer, and an event stream that is behaving perfectly has
    /// no total life. Dialling the message wake bus through it would tear a
    /// healthy stream down on a fixed clock and redial forever, which reads in
    /// a log exactly like a node that keeps dropping the connection.
    ///
    /// `idleTimeout` still applies, and still means what it says — no bytes for
    /// this long. SAGE writes a heartbeat comment every fifteen seconds
    /// precisely so a silent-but-live stream is distinguishable from a dead
    /// one, so this wants to be comfortably longer than that and no longer.
    public static func makeStreamingSession(idleTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // A stream read byte-by-byte must not sit in a buffer waiting to be
        // economical about wake-ups; the point of the bus is promptness.
        //
        // Darwin-only: `.responsiveData` is not a case of
        // `URLRequest.NetworkServiceType` on swift-corelibs-foundation, so
        // naming it off-Darwin fails to compile. It is a hint either way — the
        // corelibs transfer does no such coalescing to ask it to skip — so the
        // stream is just as prompt on Linux without it.
        #if canImport(Darwin)
        configuration.networkServiceType = .responsiveData
        #endif
        return URLSession(
            configuration: configuration,
            delegate: RedirectBlocker.shared,
            delegateQueue: nil
        )
    }

    /// Post-hoc check for callers using a session we do not own.
    ///
    /// If the response came back from anywhere other than the loopback URL we
    /// dialled, the body has already left the machine — fail loudly so it is
    /// visible rather than silent.
    public static func verifyResponseOrigin(_ response: URLResponse?, expected: URL) throws {
        guard let actual = response?.url else { return }
        guard isLoopback(actual) else {
            throw Violation.redirectAttempted(
                from: expected.absoluteString,
                to: actual.absoluteString
            )
        }
    }

    /// Refuses every HTTP redirect. Stateless, so one shared instance is safe.
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = RedirectBlocker()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // nil => do not follow. The 3xx is surfaced to the caller instead.
            completionHandler(nil)
        }
    }
}
