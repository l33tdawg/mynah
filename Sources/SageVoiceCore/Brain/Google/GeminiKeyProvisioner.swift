import Foundation

/// Turns a Google sign-in into a Gemini API key the owner actually owns.
///
/// This is the point of preferring it over Code Assist. The key that comes out
/// is an ordinary key in the owner's own Google console: they can see it, rotate
/// it, revoke it, and watch its quota. It then rides `OpenAICompatBackend` — a
/// documented, public, already-tested path — instead of `v1internal`, which is
/// Google's private wire to its own CLI and carries no compatibility promise.
///
/// The cost is that "one button" is four services deep:
///
///   1. find a usable project, or create one     (cloudresourcemanager)
///   2. enable the API Keys service on it        (serviceusage)
///   3. enable the Gemini API on it              (serviceusage)
///   4. create a key, then fetch its string      (apikeys, two calls)
///
/// Every create returns a long-running operation, so each step is a poll rather
/// than a request. That is why this is one type with an explicit state machine
/// instead of four call sites: any of these can fail in a way the owner has to
/// be told about in plain words, and the failure has to name which step.
public actor GeminiKeyProvisioner {

    // MARK: Endpoints

    enum API {
        static let resourceManager = URL(string: "https://cloudresourcemanager.googleapis.com/v1")!
        static let serviceUsage = URL(string: "https://serviceusage.googleapis.com/v1")!
        static let apiKeys = URL(string: "https://apikeys.googleapis.com/v2")!

        static let geminiService = "generativelanguage.googleapis.com"
        static let apiKeysService = "apikeys.googleapis.com"
    }

    public enum Step: String, Sendable {
        case findingProject = "finding your Google Cloud project"
        case creatingProject = "creating a Google Cloud project"
        case enablingServices = "switching on the Gemini API"
        case creatingKey = "creating your API key"
        case readingKey = "reading your API key"
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case step(Step, String)
        case operationTimedOut(Step)
        case noProjectAvailable

        public var description: String {
            switch self {
            case .step(let step, let detail):
                return "\(step.rawValue) failed: \(detail)"
            case .operationTimedOut(let step):
                return "\(step.rawValue) did not finish in time"
            case .noProjectAvailable:
                return "no Google Cloud project is available and one could not be created"
            }
        }

        /// Said to the owner. They are non-technical by assumption, so this must
        /// name what to do, not what broke.
        public var spokenDescription: String {
            switch self {
            case .noProjectAvailable:
                return "Google wouldn't let me set up a project for you. You may have hit Google's project limit."
            case .operationTimedOut:
                return "Google is taking a long time to set this up. Try again in a minute."
            case .step(let step, _):
                return "Setting up Gemini failed while \(step.rawValue)."
            }
        }
    }

    /// Sends an authorised request and returns the body. Injected so the whole
    /// chain is testable without a Google account.
    public protocol Transport: Sendable {
        func send(_ request: URLRequest) async throws -> Data
    }

    private let transport: Transport
    private let log: @Sendable (String) -> Void
    /// Injectable so tests exercise the polling loop without sleeping through
    /// it. A suite that waits on real timers gets quietly slower until nobody
    /// runs it.
    private let pollInterval: UInt64

    public init(
        transport: Transport,
        pollInterval: UInt64 = GeminiKeyProvisioner.pollIntervalNanoseconds,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.pollInterval = pollInterval
        self.log = log
    }

    // MARK: The chain

    /// Signs the owner in to Gemini and hands back a key.
    ///
    /// - Parameter preferredProjectID: reuse instead of creating. Creating is
    ///   the last resort — Google caps projects per account, and burning one of
    ///   a person's allowance to install a voice assistant is rude.
    public func provision(preferredProjectID: String? = nil) async throws -> String {
        let projectID = try await resolveProject(preferred: preferredProjectID)
        log("[gemini] using project \(projectID)")

        // API Keys must be on before it will mint anything, and the Gemini API
        // must be on before the key is worth having. Order matters; neither is
        // optional.
        try await enableService(API.apiKeysService, on: projectID)
        try await enableService(API.geminiService, on: projectID)

        let keyName = try await createKey(in: projectID)
        let keyString = try await readKeyString(named: keyName)
        log("[gemini] provisioned a key restricted to \(API.geminiService)")
        return keyString
    }

    // MARK: 1 — project

    func resolveProject(preferred: String?) async throws -> String {
        if let preferred, !preferred.isEmpty { return preferred }

        if let existing = try await firstActiveProject() { return existing }
        return try await createProject()
    }

    func firstActiveProject() async throws -> String? {
        var request = URLRequest(url: API.resourceManager.appendingPathComponent("projects"))
        request.httpMethod = "GET"

        let data: Data
        do {
            data = try await transport.send(request)
        } catch {
            // Not fatal: a brand new account has no projects and may not even
            // have the API on. Fall through to creating one.
            log("[gemini] could not list projects (\(error)); will try to create one")
            return nil
        }

        struct Response: Decodable {
            struct Project: Decodable {
                let projectId: String
                let lifecycleState: String?
            }
            let projects: [Project]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.projects?.first { ($0.lifecycleState ?? "ACTIVE") == "ACTIVE" }?.projectId
    }

    func createProject() async throws -> String {
        let projectID = Self.generatedProjectID()
        var request = URLRequest(url: API.resourceManager.appendingPathComponent("projects"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "projectId": projectID,
            "name": "SAGE Voice Bridge"
        ])

        let data: Data
        do {
            data = try await transport.send(request)
        } catch {
            throw Failure.step(.creatingProject, "\(error)")
        }
        _ = try await awaitOperation(
            from: data,
            step: .creatingProject,
            pollURL: { API.resourceManager.appendingPathComponent($0) }
        )
        return projectID
    }

    /// Project ids are globally unique across all of Google Cloud, 6–30
    /// characters, lowercase alphanumeric and hyphens, and must not end in a
    /// hyphen. A collision is a hard failure rather than a retry, so this leans
    /// on randomness rather than on the owner's name.
    static func generatedProjectID(random: () -> UInt32 = { UInt32.random(in: 0..<UInt32.max) }) -> String {
        let suffix = String(random(), radix: 36)
        let padded = String((suffix + "000000").prefix(8))
        return "sage-voice-\(padded)"
    }

    // MARK: 2 — services

    func enableService(_ service: String, on projectID: String) async throws {
        let url = API.serviceUsage
            .appendingPathComponent("projects/\(projectID)/services/\(service):enable")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let data: Data
        do {
            data = try await transport.send(request)
        } catch {
            throw Failure.step(.enablingServices, "\(service): \(error)")
        }
        _ = try await awaitOperation(
            from: data,
            step: .enablingServices,
            pollURL: { API.serviceUsage.appendingPathComponent($0) }
        )
    }

    // MARK: 3 — key

    func createKey(in projectID: String) async throws -> String {
        let url = API.apiKeys.appendingPathComponent("projects/\(projectID)/locations/global/keys")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "displayName": "SAGE Voice Bridge",
            // Least privilege, and not a formality. This key is written to the
            // owner's disk on an appliance that is on the internet; an
            // unrestricted key would be a credential for their entire Google
            // Cloud surface rather than for one text-generation API.
            "restrictions": [
                "apiTargets": [["service": API.geminiService]]
            ]
        ])

        let data: Data
        do {
            data = try await transport.send(request)
        } catch {
            throw Failure.step(.creatingKey, "\(error)")
        }

        let response = try await awaitOperation(
            from: data,
            step: .creatingKey,
            pollURL: { API.apiKeys.appendingPathComponent($0) }
        )
        guard let name = response?["name"] as? String else {
            throw Failure.step(.creatingKey, "the finished operation carried no key name")
        }
        return name
    }

    /// `create` returns the key resource but never its secret; the string comes
    /// from a second, separate call.
    func readKeyString(named name: String) async throws -> String {
        let url = API.apiKeys.appendingPathComponent("\(name):getKeyString")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let data: Data
        do {
            data = try await transport.send(request)
        } catch {
            throw Failure.step(.readingKey, "\(error)")
        }

        struct Response: Decodable { let keyString: String? }
        guard
            let response = try? JSONDecoder().decode(Response.self, from: data),
            let keyString = response.keyString,
            !keyString.isEmpty
        else {
            throw Failure.step(.readingKey, "no key string in the response")
        }
        return keyString
    }

    // MARK: Long-running operations

    /// Google's create calls return before the thing exists.
    ///
    /// Project creation "usually takes a few seconds, but can sometimes take
    /// much longer", so this polls rather than assuming. Returns the `response`
    /// object of the finished operation.
    public static let maximumPolls = 30
    public static let pollIntervalNanoseconds: UInt64 = 2_000_000_000

    func awaitOperation(
        from data: Data,
        step: Step,
        pollURL: (String) -> URL,
        sleeper: @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) async throws -> [String: Any]? {
        var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        for _ in 0..<Self.maximumPolls {
            if let error = payload["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "\(error)"
                throw Failure.step(step, message)
            }
            // An immediate, already-complete result has no `name` to poll and
            // no `done` flag — treat the absence of an operation as success.
            let isOperation = payload["name"] is String && payload["done"] != nil
            if !isOperation {
                return payload["response"] as? [String: Any] ?? payload
            }
            if payload["done"] as? Bool == true {
                return payload["response"] as? [String: Any]
            }

            guard let name = payload["name"] as? String else {
                return payload["response"] as? [String: Any] ?? payload
            }
            await sleeper(pollInterval)

            var request = URLRequest(url: pollURL(name))
            request.httpMethod = "GET"
            guard
                let next = try? await transport.send(request),
                let decoded = (try? JSONSerialization.jsonObject(with: next)) as? [String: Any]
            else {
                throw Failure.step(step, "lost track of Google's progress")
            }
            payload = decoded
        }
        throw Failure.operationTimedOut(step)
    }
}

// MARK: - Transport over a Google credential

/// Signs every request with the owner's Google token and turns HTTP errors into
/// something a person can read.
public struct GoogleAuthorizedTransport: GeminiKeyProvisioner.Transport {
    private let credential: GoogleOAuthCredential
    private let session: URLSession

    public init(credential: GoogleOAuthCredential, session: URLSession? = nil) {
        self.credential = credential
        self.session = session ?? WebSearchHTTP.makeSession(timeout: 30)
    }

    public func send(_ request: URLRequest) async throws -> Data {
        var authorized = request
        for (name, value) in try await credential.authorizationHeaders() {
            authorized.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: authorized)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            // Google's error envelope explains far more than the status code,
            // and this chain fails in ways (billing, quota, org policy) that are
            // indistinguishable without it.
            let detail = Self.googleErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw GeminiKeyProvisioner.Failure.step(.findingProject, detail)
        }
        return data
    }

    static func googleErrorMessage(_ data: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                let message: String?
                let status: String?
            }
            let error: Inner?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return envelope.error?.message ?? envelope.error?.status
    }
}
