import XCTest
@testable import SageVoiceCore

final class PKCETests: XCTestCase {

    /// RFC 7636 test vector. If the challenge derivation is wrong, Google
    /// rejects the exchange with an opaque error, so this pins it to the spec
    /// rather than to our own output.
    func testChallengeMatchesTheSpecVector() {
        let pair = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pair.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(pair.method, "S256")
    }

    func testVerifiersAreTheRequiredLengthAndAlphabet() {
        let pair = PKCEPair.random()
        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertLessThanOrEqual(pair.verifier.count, 128)

        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertNil(
            pair.verifier.rangeOfCharacter(from: unreserved.inverted),
            "base64url output must not contain +, / or ="
        )
    }

    func testVerifiersAreNotReused() {
        let verifiers = Set((0..<50).map { _ in PKCEPair.random().verifier })
        XCTAssertEqual(verifiers.count, 50, "a repeated verifier would defeat the point of PKCE")
    }
}

final class GoogleOAuthFlowTests: XCTestCase {

    private let client = GoogleOAuthClient(clientID: "test-client.apps.googleusercontent.com")

    // MARK: Authorization URL

    func testAuthorizationURLCarriesEverythingGoogleRequires() {
        let pkce = PKCEPair(verifier: String(repeating: "a", count: 43))
        let url = GoogleOAuthFlow.authorizationURL(client: client, pkce: pkce, state: "xyz", port: 51789)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? [:] as? [URLQueryItem] ?? []

        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(value("client_id"), "test-client.apps.googleusercontent.com")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("code_challenge"), pkce.challenge)
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "xyz")
    }

    /// Without `access_type=offline` Google issues no refresh token, and the
    /// appliance stops working an hour after setup — on a machine the owner is
    /// not sitting at.
    func testOfflineAccessAndConsentAreRequested() {
        let url = GoogleOAuthFlow.authorizationURL(
            client: client, pkce: .random(), state: "s", port: 1234
        )
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("access_type=offline"))
        XCTAssertTrue(query.contains("prompt=consent"))
    }

    /// Google requires a loopback IP literal for installed apps; `localhost`
    /// resolution can be redirected.
    func testRedirectIsALoopbackIPLiteral() {
        XCTAssertEqual(GoogleOAuthFlow.redirectURI(port: 8080), "http://127.0.0.1:8080/oauth2callback")
        XCTAssertFalse(GoogleOAuthFlow.redirectURI(port: 8080).contains("localhost"))
    }

    /// `cloud-platform` is what lets the token mint an API key later, so path B
    /// does not need a second consent screen.
    func testGeminiScopesIncludeCloudPlatform() {
        XCTAssertTrue(GoogleOAuthClient.geminiScopes.contains("https://www.googleapis.com/auth/cloud-platform"))
    }

    // MARK: Callback parsing

    func testCallbackYieldsCodeAndState() {
        let result = GoogleOAuthFlow.parseCallback(
            requestLine: "GET /oauth2callback?state=abc123&code=4/0AY0e HTTP/1.1"
        )
        switch result {
        case .success(let (code, state)):
            XCTAssertEqual(code, "4/0AY0e")
            XCTAssertEqual(state, "abc123")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    /// The owner pressing "Cancel" must read as cancellation, not as a crash.
    func testADeclinedConsentReportsWhatGoogleSaid() {
        let result = GoogleOAuthFlow.parseCallback(
            requestLine: "GET /oauth2callback?error=access_denied&state=abc HTTP/1.1"
        )
        guard case .failure(.browserFlowFailed(let detail)) = result else {
            return XCTFail("expected a browserFlowFailed, got \(result)")
        }
        XCTAssertEqual(detail, "access_denied")
    }

    func testAGarbledCallbackFailsRatherThanCrashing() {
        guard case .failure = GoogleOAuthFlow.parseCallback(requestLine: "nonsense") else {
            return XCTFail("expected a failure")
        }
    }

    func testACallbackWithoutACodeIsAFailure() {
        guard case .failure = GoogleOAuthFlow.parseCallback(
            requestLine: "GET /oauth2callback?state=abc HTTP/1.1"
        ) else {
            return XCTFail("expected a failure")
        }
    }

    // MARK: Token exchange

    func testCodeExchangeSendsTheVerifierNotTheChallenge() {
        let pkce = PKCEPair.random()
        let body = GoogleOAuthFlow.codeExchangeBody(client: client, code: "abc", pkce: pkce, port: 4321)
        let text = String(data: body, encoding: .utf8) ?? ""

        XCTAssertTrue(text.contains("grant_type=authorization_code"))
        XCTAssertTrue(text.contains("code_verifier="))
        XCTAssertFalse(text.contains(pkce.challenge), "sending the challenge here defeats PKCE entirely")
    }

    func testFormEncodingEscapesReservedCharacters() {
        let body = GoogleOAuthFlow.formEncoded(["redirect_uri": "http://127.0.0.1:80/oauth2callback"])
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("://"), "an unescaped URL would corrupt the form body")
    }

    func testAbsoluteExpiryIsDerivedFromExpiresIn() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = Data(#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#.utf8)

        let tokens = try GoogleOAuthFlow.decodeTokenResponse(json, now: now)

        XCTAssertEqual(tokens.accessToken, "at")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
    }

    /// Google routinely omits `refresh_token` when refreshing. Overwriting the
    /// stored one with nil logs the owner out on the very first refresh.
    func testARefreshWithoutANewRefreshTokenKeepsTheOldOne() throws {
        let json = Data(#"{"access_token":"new","expires_in":3600}"#.utf8)

        let tokens = try GoogleOAuthFlow.decodeTokenResponse(json, existingRefreshToken: "original")

        XCTAssertEqual(tokens.accessToken, "new")
        XCTAssertEqual(tokens.refreshToken, "original")
    }

    func testAnErrorResponseIsReportedWithGooglesDescription() {
        let json = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)

        XCTAssertThrowsError(try GoogleOAuthFlow.decodeTokenResponse(json)) { error in
            guard case GoogleOAuthError.tokenEndpoint(let detail) = error else {
                return XCTFail("expected tokenEndpoint, got \(error)")
            }
            XCTAssertEqual(detail, "Token has been expired or revoked.")
        }
    }

    // MARK: Expiry

    /// A token that passes the check and then expires in flight fails the
    /// owner's turn, which on a phone reads as "it's broken".
    func testTokensAreTreatedAsExpiredBeforeTheyActuallyAre() {
        let now = Date()
        let almost = GoogleOAuthTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(GoogleOAuthTokens.refreshMargin - 1)
        )
        XCTAssertTrue(almost.isExpired(now: now))

        let healthy = GoogleOAuthTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(GoogleOAuthTokens.refreshMargin + 60)
        )
        XCTAssertFalse(healthy.isExpired(now: now))
    }

    // MARK: Client configuration

    /// Credentials must be configuration. Compiling in Gemini CLI's client id
    /// would make this app authenticate as Google's CLI — revocable at any
    /// time, and it would break in the field rather than in testing.
    func testNoClientIsConfiguredWithoutTheEnvironment() {
        XCTAssertNil(GoogleOAuthClient.fromEnvironment([:]))
        XCTAssertNil(GoogleOAuthClient.fromEnvironment(["GOOGLE_OAUTH_CLIENT_ID": "   "]))

        let configured = GoogleOAuthClient.fromEnvironment([
            "GOOGLE_OAUTH_CLIENT_ID": "abc.apps.googleusercontent.com",
            "GOOGLE_OAUTH_CLIENT_SECRET": "shh"
        ])
        XCTAssertEqual(configured?.clientID, "abc.apps.googleusercontent.com")
        XCTAssertEqual(configured?.clientSecret, "shh")
    }
}

final class GoogleTokenStoreTests: XCTestCase {

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oauth-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("google-oauth.json")
    }

    func testTokensSurviveARoundTrip() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = GoogleTokenStore(url: url)
        let tokens = GoogleOAuthTokens(
            accessToken: "at",
            refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 2_000_000)
        )

        try store.save(tokens)

        XCTAssertEqual(store.load(), tokens)
    }

    /// A refresh token is a long-lived key to the owner's Google account.
    func testTheTokenFileIsOwnerOnly() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = GoogleTokenStore(url: url)

        try store.save(GoogleOAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date()))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600, "a refresh token must not be group- or world-readable")
    }

    func testAMissingStoreIsNotAnError() {
        XCTAssertNil(GoogleTokenStore(url: temporaryStoreURL()).load())
    }

    func testSigningOutRemovesTheToken() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = GoogleTokenStore(url: url)
        try store.save(GoogleOAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date()))

        store.clear()

        XCTAssertNil(store.load())
    }
}
