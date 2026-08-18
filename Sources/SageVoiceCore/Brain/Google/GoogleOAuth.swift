#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// "Sign in with Google", for owners who will never paste an API key.
///
/// This is the foundation under both Gemini paths and is why it is built first:
///
///  * **Code Assist** — the token calls `cloudcode-pa.googleapis.com/v1internal`
///    directly. Free tier, no billing, but an internal endpoint with no public
///    contract.
///  * **Key provisioning** — the token mints a real Gemini API key through
///    `apikeys.googleapis.com`, which then rides the documented, already-tested
///    `OpenAICompatBackend`. The key is the owner's, visible in their own Google
///    console and revocable there.
///
/// Both need exactly this: a browser round trip and a refreshable token.
///
/// **Credentials are configuration, never source.** Gemini CLI embeds its own
/// client id and secret in its repository, and copying them is tempting because
/// it would work today. It would also mean this app authenticates as Google's
/// CLI — Google can revoke that pairing at any time, and it would break in the
/// field rather than in testing. Register an OAuth client, pass it in.
public struct GoogleOAuthClient: Sendable {
    public let clientID: String
    /// Google issues a "secret" for installed apps, which cannot actually be
    /// kept secret in a binary anyone can open. That is why PKCE exists and why
    /// it is mandatory here rather than optional.
    public let clientSecret: String?
    public let scopes: [String]

    /// What Gemini's own client asks for. `cloud-platform` is the one that
    /// matters: it is what lets a token mint an API key, so path B is reachable
    /// without sending the owner back through a second consent screen.
    public static let geminiScopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email"
    ]

    public init(clientID: String, clientSecret: String? = nil, scopes: [String] = GoogleOAuthClient.geminiScopes) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }

    /// Reads the client from the environment so no credential is compiled in.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GoogleOAuthClient? {
        let id = environment["GOOGLE_OAUTH_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { return nil }
        let secret = environment["GOOGLE_OAUTH_CLIENT_SECRET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GoogleOAuthClient(clientID: id, clientSecret: secret?.isEmpty == true ? nil : secret)
    }
}

// MARK: - PKCE

/// Proof Key for Code Exchange.
///
/// A desktop app cannot hold a secret, so the authorization code alone is not
/// proof of anything: anything that can intercept the loopback redirect could
/// redeem it. PKCE binds the code to a verifier that never leaves this process
/// — the browser carries only its SHA-256.
public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    /// RFC 7636 requires 43–128 characters from an unreserved alphabet; 32
    /// random bytes base64url-encoded lands at 43.
    public static func random() -> PKCEPair {
        PKCEPair(verifier: Data.secureRandom(count: 32).base64URLEncodedString())
    }
}

// MARK: - Tokens

public struct GoogleOAuthTokens: Sendable, Codable, Equatable {
    public var accessToken: String
    /// Absent when Google declines to reissue one on refresh, which it does
    /// routinely — the original must be kept rather than overwritten with nil.
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// Treated as expired early on purpose. A token that passes this check and
    /// then expires in flight fails the owner's turn, and the appliance is
    /// spoken to from a phone where a 401 reads as "it's broken".
    public static let refreshMargin: TimeInterval = 120

    public func isExpired(now: Date = Date()) -> Bool {
        now.addingTimeInterval(Self.refreshMargin) >= expiresAt
    }
}

public enum GoogleOAuthError: Error, CustomStringConvertible, Equatable {
    case notSignedIn
    case noRefreshToken
    case browserFlowFailed(String)
    case tokenEndpoint(String)
    case stateMismatch

    public var description: String {
        switch self {
        case .notSignedIn:
            return "not signed in to Google"
        case .noRefreshToken:
            return "the stored Google sign-in has no refresh token; sign in again"
        case .browserFlowFailed(let detail):
            return "Google sign-in did not complete: \(detail)"
        case .tokenEndpoint(let detail):
            return "Google rejected the token request: \(detail)"
        case .stateMismatch:
            return "the sign-in response did not match the request it answered"
        }
    }

    public var spokenDescription: String {
        switch self {
        case .notSignedIn, .noRefreshToken:
            return "I need you to sign in to Google again in the app."
        case .browserFlowFailed, .tokenEndpoint, .stateMismatch:
            return "Signing in to Google didn't work."
        }
    }
}

// MARK: - Token store

/// Where the refresh token lives between launches.
///
/// A refresh token is a long-lived key to the owner's Google account, so the
/// file is 0600 in a 0700 directory — the same discipline the rest of this
/// package applies to the owner's transcripts.
public struct GoogleTokenStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Beside the provider keys, on whichever platform this is — which is why
    /// the directory comes from `ApplianceSupportDirectory` and is not spelled
    /// again here.
    public static func defaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ApplianceSupportDirectory.url(
            for: "google-oauth.json",
            layout: layout,
            homeDirectory: homeDirectory,
            environment: environment
        )
    }

    public func load() -> GoogleOAuthTokens? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GoogleOAuthTokens.self, from: data)
    }

    public func save(_ tokens: GoogleOAuthTokens) throws {
        try OwnerOnlyFileSecurity.prepareDirectory(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(tokens)
        try data.write(to: url, options: [.atomic])
        try OwnerOnlyFileSecurity.protectFile(url)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Flow construction

/// The pure, testable half of the dance: building the URL the browser opens and
/// reading what comes back. Deliberately separated from the socket work, which
/// needs a live browser to exercise and so tends to go untested.
public enum GoogleOAuthFlow {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Google requires a literal loopback address for installed apps —
    /// `localhost` resolution can be hijacked, so the IP is spelled out.
    public static func redirectURI(port: Int) -> String {
        "http://127.0.0.1:\(port)/oauth2callback"
    }

    public static func authorizationURL(
        client: GoogleOAuthClient,
        pkce: PKCEPair,
        state: String,
        port: Int
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI(port: port)),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: client.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            // Without offline access Google returns no refresh token, and the
            // appliance would silently stop working an hour after setup — on a
            // machine the owner is not sitting at.
            URLQueryItem(name: "access_type", value: "offline"),
            // Forces the consent screen so a re-sign-in actually reissues a
            // refresh token instead of returning an access token alone.
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    /// Pulls `code` and `state` out of the browser's callback request line.
    ///
    /// Returns the error Google reported when the owner declines, so the app can
    /// say "you cancelled" rather than "sign-in failed".
    public static func parseCallback(requestLine: String) -> Result<(code: String, state: String), GoogleOAuthError> {
        // e.g. "GET /oauth2callback?state=…&code=… HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            return .failure(.browserFlowFailed("unreadable callback request"))
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            return .failure(.browserFlowFailed(error))
        }
        guard
            let code = items.first(where: { $0.name == "code" })?.value,
            let state = items.first(where: { $0.name == "state" })?.value
        else {
            return .failure(.browserFlowFailed("callback carried no authorization code"))
        }
        return .success((code, state))
    }

    /// Body for exchanging the authorization code.
    public static func codeExchangeBody(
        client: GoogleOAuthClient,
        code: String,
        pkce: PKCEPair,
        port: Int
    ) -> Data {
        var fields = [
            "client_id": client.clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI(port: port)
        ]
        if let secret = client.clientSecret {
            fields["client_secret"] = secret
        }
        return formEncoded(fields)
    }

    public static func refreshBody(client: GoogleOAuthClient, refreshToken: String) -> Data {
        var fields = [
            "client_id": client.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let secret = client.clientSecret {
            fields["client_secret"] = secret
        }
        return formEncoded(fields)
    }

    /// Google returns `expires_in` seconds; everything downstream wants an
    /// absolute instant, so the conversion happens once, here.
    public static func decodeTokenResponse(
        _ data: Data,
        now: Date = Date(),
        existingRefreshToken: String? = nil
    ) throws -> GoogleOAuthTokens {
        struct Payload: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
            let error: String?
            let error_description: String?
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw GoogleOAuthError.tokenEndpoint("unreadable response")
        }
        if let error = payload.error {
            throw GoogleOAuthError.tokenEndpoint(payload.error_description ?? error)
        }
        guard let accessToken = payload.access_token else {
            throw GoogleOAuthError.tokenEndpoint("no access token in response")
        }
        return GoogleOAuthTokens(
            accessToken: accessToken,
            // A refresh response usually omits this. Keeping the existing one is
            // the difference between staying signed in and being logged out on
            // the first refresh.
            refreshToken: payload.refresh_token ?? existingRefreshToken,
            expiresAt: now.addingTimeInterval(payload.expires_in ?? 3600),
            scope: payload.scope
        )
    }

    static func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
        return encoded.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

// MARK: - Credential

/// A `BrainCredential` that keeps a Google token fresh.
///
/// Refreshing here rather than at sign-in is the whole point of the protocol
/// taking an async call per request: an appliance sits idle for hours and is
/// then wanted immediately, so its token is almost always stale when it matters.
public actor GoogleOAuthCredential: BrainCredential {
    private let client: GoogleOAuthClient
    private let store: GoogleTokenStore
    private let session: URLSession
    private var tokens: GoogleOAuthTokens?

    public init(
        client: GoogleOAuthClient,
        store: GoogleTokenStore,
        session: URLSession? = nil
    ) {
        self.client = client
        self.store = store
        self.session = session ?? WebSearchHTTP.makeSession(timeout: 20)
        self.tokens = store.load()
    }

    public var isSignedIn: Bool { tokens?.refreshToken != nil }

    public func authorizationHeaders() async throws -> [String: String] {
        let token = try await validAccessToken()
        return ["Authorization": "Bearer \(token)"]
    }

    public func validAccessToken() async throws -> String {
        guard let current = tokens else { throw GoogleOAuthError.notSignedIn }
        guard current.isExpired() else { return current.accessToken }
        guard let refreshToken = current.refreshToken else { throw GoogleOAuthError.noRefreshToken }

        var request = URLRequest(url: GoogleOAuthFlow.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuthFlow.refreshBody(client: client, refreshToken: refreshToken)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw GoogleOAuthError.tokenEndpoint(error.localizedDescription)
        }

        let refreshed = try GoogleOAuthFlow.decodeTokenResponse(
            data,
            existingRefreshToken: refreshToken
        )
        tokens = refreshed
        try? store.save(refreshed)
        return refreshed.accessToken
    }

    /// Adopts tokens obtained by the browser flow.
    public func adopt(_ newTokens: GoogleOAuthTokens) throws {
        tokens = newTokens
        try store.save(newTokens)
    }

    public func signOut() {
        tokens = nil
        store.clear()
    }
}

// MARK: - Small helpers

extension Data {
    /// base64url, per RFC 7636 — the standard alphabet's `+`, `/` and `=` are
    /// not URL-safe and Google rejects them.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `SystemRandomNumberGenerator` is documented as cryptographically secure
    /// on Apple platforms, unlike `Int.random(in:)` on an arbitrary generator.
    static func secureRandom(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
