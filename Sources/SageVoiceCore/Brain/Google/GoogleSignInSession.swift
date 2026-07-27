import Foundation
import Network

/// Runs the browser half of "Sign in with Google".
///
/// Opens the consent page, listens on a loopback port for Google to redirect
/// back, and exchanges the authorization code for tokens. Separated from
/// `GoogleOAuthFlow` because everything here needs a live browser and a real
/// socket to exercise, while the URL building and response parsing next door
/// are pure and heavily tested.
public actor GoogleSignInSession {

    /// Long enough for a person to find the browser window, pick an account and
    /// read a consent screen; short enough that a forgotten window does not pin
    /// a listening socket open forever.
    public static let defaultTimeoutSeconds: TimeInterval = 300

    private let client: GoogleOAuthClient
    private let store: GoogleTokenStore
    private let session: URLSession
    private let log: @Sendable (String) -> Void

    public init(
        client: GoogleOAuthClient,
        store: GoogleTokenStore,
        session: URLSession? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.client = client
        self.store = store
        self.session = session ?? WebSearchHTTP.makeSession(timeout: 30)
        self.log = log
    }

    /// Signs in and returns tokens, having already persisted them.
    ///
    /// - Parameter openURL: how the consent page is shown. Injected so a headless
    ///   run can print the URL instead of launching a browser — which is exactly
    ///   what the appliance needs, since nobody is sitting at the Mac mini.
    public func signIn(
        timeout: TimeInterval = GoogleSignInSession.defaultTimeoutSeconds,
        openURL: @Sendable (URL) -> Void
    ) async throws -> GoogleOAuthTokens {
        let pkce = PKCEPair.random()
        // Guards against a different page — or a different tab — delivering a
        // code to our listener. Compared before the code is ever redeemed.
        let state = Data.secureRandom(count: 16).base64URLEncodedString()

        let listener = try LoopbackCallbackListener()
        let port = try listener.start()
        defer { listener.stop() }

        let url = GoogleOAuthFlow.authorizationURL(client: client, pkce: pkce, state: state, port: port)
        log("[google] waiting for sign-in on 127.0.0.1:\(port)")
        openURL(url)

        let requestLine = try await listener.awaitCallback(timeout: timeout)
        let callback = GoogleOAuthFlow.parseCallback(requestLine: requestLine)

        let code: String
        switch callback {
        case .success(let (returnedCode, returnedState)):
            guard returnedState == state else { throw GoogleOAuthError.stateMismatch }
            code = returnedCode
        case .failure(let error):
            throw error
        }

        var request = URLRequest(url: GoogleOAuthFlow.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuthFlow.codeExchangeBody(
            client: client, code: code, pkce: pkce, port: port
        )

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw GoogleOAuthError.tokenEndpoint(error.localizedDescription)
        }

        let tokens = try GoogleOAuthFlow.decodeTokenResponse(data)
        try store.save(tokens)
        log("[google] signed in; refresh token \(tokens.refreshToken == nil ? "MISSING" : "stored")")
        return tokens
    }
}

// MARK: - Loopback listener

/// A single-shot HTTP listener for the OAuth redirect.
///
/// Not a web server. It accepts one connection, reads the request line, answers
/// with a page telling the owner to go back to the app, and stops. Anything more
/// would be a network service running on the appliance for the rest of its life.
final class LoopbackCallbackListener: @unchecked Sendable {

    enum Failure: Error, CustomStringConvertible {
        case couldNotListen(String)
        case timedOut

        var description: String {
            switch self {
            case .couldNotListen(let detail): return "could not listen for Google's redirect: \(detail)"
            case .timedOut: return "Google's redirect never arrived"
            }
        }
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        // Loopback only. Binding the wildcard would expose the callback to the
        // network for the duration of a sign-in.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.couldNotListen("\(error)")
        }
    }

    /// Starts listening and returns the port the OS chose.
    ///
    /// The port has to be known before the authorization URL is built, because
    /// it is part of the redirect_uri Google will echo back — so this blocks
    /// briefly rather than reporting it asynchronously.
    func start() throws -> Int {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))

        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue else {
            listener.cancel()
            throw Failure.couldNotListen("the listener never became ready")
        }
        return Int(port)
    }

    func awaitCallback(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    self.continuation = continuation
                    lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timedOut }
            return first
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? text

            // The owner is looking at a browser tab, not at the app. Say
            // something, or the sign-in looks like it failed.
            let body = """
            <!doctype html><meta charset="utf-8">
            <title>Signed in</title>
            <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:4rem;color:#111">
            <h2>You're signed in.</h2><p>You can close this tab and go back to the app.</p>
            """
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            self.deliver(requestLine)
        }
    }

    /// Resumes exactly once. A second connection — a favicon request, a retry,
    /// a browser prefetch — must not resume a continuation again.
    private func deliver(_ requestLine: String) {
        lock.lock()
        let pending = finished ? nil : continuation
        finished = true
        continuation = nil
        lock.unlock()
        pending?.resume(returning: requestLine)
    }
}
