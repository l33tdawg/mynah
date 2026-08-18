import XCTest
@testable import SageVoiceCore
#if canImport(FoundationNetworking)
// `URLRequest`, `URLSession` and `HTTPURLResponse` are in Foundation on a Mac
// and in this second module everywhere else. Same convention as the twenty-eight
// files under Sources/ that already reach for the network.
import FoundationNetworking
#endif

/// Replays scripted Google responses keyed by a substring of the request URL,
/// so a test reads as "when it asks for X, Google says Y".
private final class ScriptedGoogle: GeminiKeyProvisioner.Transport, @unchecked Sendable {
    struct Rule {
        let match: String
        let method: String?
        let responses: [String]
    }

    private let lock = NSLock()
    private var rules: [Rule]
    private var hits: [String: Int] = [:]
    private(set) var requests: [(method: String, url: String, body: String)] = []

    init(_ rules: [Rule]) {
        self.rules = rules
    }

    func send(_ request: URLRequest) async throws -> Data {
        let url = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        return try withLock {
            requests.append((method, url, body))
            guard let rule = rules.first(where: {
                url.contains($0.match) && ($0.method == nil || $0.method == method)
            }) else {
                throw ProvisionTestError.unexpected("\(method) \(url)")
            }
            let index = min(hits[rule.match] ?? 0, rule.responses.count - 1)
            hits[rule.match] = (hits[rule.match] ?? 0) + 1
            return Data(rule.responses[index].utf8)
        }
    }

    func callCount(matching fragment: String) -> Int {
        withLock { requests.filter { $0.url.contains(fragment) }.count }
    }

    func body(matching fragment: String) -> String? {
        withLock { requests.first { $0.url.contains(fragment) }?.body }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private enum ProvisionTestError: Error, CustomStringConvertible {
    case unexpected(String)
    var description: String {
        switch self { case .unexpected(let what): return "unscripted request: \(what)" }
    }
}

// MARK: - Tests

final class GeminiKeyProvisionerTests: XCTestCase {

    private func happyPathRules(projects: String) -> [ScriptedGoogle.Rule] {
        [
            .init(match: "cloudresourcemanager.googleapis.com/v1/projects",
                  method: "GET",
                  responses: [projects]),
            .init(match: ":enable", method: "POST", responses: [#"{"name":"operations/e1","done":true}"#]),
            .init(match: "/locations/global/keys", method: "POST", responses: [
                #"{"name":"operations/k1","done":true,"response":{"name":"projects/p1/locations/global/keys/k"}}"#
            ]),
            .init(match: ":getKeyString", method: "GET", responses: [#"{"keyString":"AIzaTESTKEY"}"#])
        ]
    }

    func testAnExistingProjectYieldsAKeyWithoutCreatingOne() async throws {
        let google = ScriptedGoogle(happyPathRules(
            projects: #"{"projects":[{"projectId":"my-project","lifecycleState":"ACTIVE"}]}"#
        ))
        let provisioner = GeminiKeyProvisioner(transport: google, pollInterval: 0)

        let key = try await provisioner.provision()

        XCTAssertEqual(key, "AIzaTESTKEY")
        XCTAssertEqual(
            google.requests.filter { $0.method == "POST" && $0.url.hasSuffix("/v1/projects") }.count,
            0,
            "creating a project when one exists burns the owner's project quota"
        )
    }

    /// Google caps projects per account. Spending one to install a voice
    /// assistant, when the owner already has a usable project, is rude.
    func testAnExistingProjectIsPreferredOverCreatingOne() async throws {
        let google = ScriptedGoogle(happyPathRules(
            projects: #"{"projects":[{"projectId":"existing-one","lifecycleState":"ACTIVE"}]}"#
        ))
        let provisioner = GeminiKeyProvisioner(transport: google, pollInterval: 0)

        _ = try await provisioner.provision()

        XCTAssertEqual(google.callCount(matching: "projects/existing-one/services"), 2)
    }

    func testADeletedProjectIsNotReused() async throws {
        var rules = happyPathRules(
            projects: #"{"projects":[{"projectId":"dead","lifecycleState":"DELETE_REQUESTED"}]}"#
        )
        rules.append(.init(match: "/v1/projects", method: "POST",
                           responses: [#"{"name":"operations/p1","done":true}"#]))
        let google = ScriptedGoogle(rules)

        _ = try await GeminiKeyProvisioner(transport: google, pollInterval: 0).provision()

        XCTAssertEqual(google.callCount(matching: "projects/dead/services"), 0)
    }

    func testAnExplicitProjectSkipsDiscoveryEntirely() async throws {
        let google = ScriptedGoogle(happyPathRules(projects: "{}"))

        let key = try await GeminiKeyProvisioner(transport: google, pollInterval: 0)
            .provision(preferredProjectID: "chosen-project")

        XCTAssertEqual(key, "AIzaTESTKEY")
        XCTAssertEqual(google.callCount(matching: "projects/chosen-project/services"), 2)
    }

    // MARK: Least privilege

    /// The key lands on disk on an internet-connected appliance. Unrestricted,
    /// it would be a credential for the owner's whole Google Cloud surface
    /// rather than for one text-generation API.
    func testTheKeyIsRestrictedToTheGeminiAPI() async throws {
        let google = ScriptedGoogle(happyPathRules(
            projects: #"{"projects":[{"projectId":"p","lifecycleState":"ACTIVE"}]}"#
        ))

        _ = try await GeminiKeyProvisioner(transport: google, pollInterval: 0).provision()

        let body = google.body(matching: "/locations/global/keys") ?? ""
        XCTAssertTrue(body.contains("apiTargets"))
        XCTAssertTrue(body.contains("generativelanguage.googleapis.com"))
    }

    func testBothRequiredServicesAreEnabled() async throws {
        let google = ScriptedGoogle(happyPathRules(
            projects: #"{"projects":[{"projectId":"p","lifecycleState":"ACTIVE"}]}"#
        ))

        _ = try await GeminiKeyProvisioner(transport: google, pollInterval: 0).provision()

        let enables = google.requests.filter { $0.url.contains(":enable") }.map(\.url)
        XCTAssertTrue(enables.contains { $0.contains("apikeys.googleapis.com:enable") },
                      "API Keys must be on or nothing can be minted")
        XCTAssertTrue(enables.contains { $0.contains("generativelanguage.googleapis.com:enable") },
                      "the Gemini API must be on or the key is worthless")
    }

    // MARK: Long-running operations

    /// Google's creates return before the thing exists.
    func testAPendingOperationIsPolledUntilItFinishes() async throws {
        var rules = happyPathRules(projects: #"{"projects":[{"projectId":"p","lifecycleState":"ACTIVE"}]}"#)
        rules.removeAll { $0.match == "/locations/global/keys" }
        rules.append(.init(match: "/locations/global/keys", method: "POST", responses: [
            #"{"name":"operations/k1","done":false}"#
        ]))
        rules.append(.init(match: "operations/k1", method: "GET", responses: [
            #"{"name":"operations/k1","done":false}"#,
            #"{"name":"operations/k1","done":true,"response":{"name":"projects/p/locations/global/keys/k"}}"#
        ]))
        let google = ScriptedGoogle(rules)

        let key = try await GeminiKeyProvisioner(transport: google, pollInterval: 0).provision()

        XCTAssertEqual(key, "AIzaTESTKEY")
        XCTAssertGreaterThanOrEqual(google.callCount(matching: "operations/k1"), 2)
    }

    func testAnOperationErrorIsReportedWithGooglesMessage() async {
        var rules = happyPathRules(projects: #"{"projects":[{"projectId":"p","lifecycleState":"ACTIVE"}]}"#)
        rules.removeAll { $0.match == ":enable" }
        rules.append(.init(match: ":enable", method: "POST", responses: [
            #"{"error":{"message":"Billing must be enabled","status":"FAILED_PRECONDITION"}}"#
        ]))
        let google = ScriptedGoogle(rules)

        do {
            _ = try await GeminiKeyProvisioner(transport: google, pollInterval: 0).provision()
            XCTFail("expected the enable step to fail")
        } catch let failure as GeminiKeyProvisioner.Failure {
            guard case .step(let step, let detail) = failure else {
                return XCTFail("wrong failure: \(failure)")
            }
            XCTAssertEqual(step, .enablingServices)
            XCTAssertTrue(detail.contains("Billing must be enabled"),
                          "the owner cannot act on a message we swallowed")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Failures the owner has to understand

    func testAMissingKeyStringIsAFailureRatherThanAnEmptyKey() async {
        var rules = happyPathRules(projects: #"{"projects":[{"projectId":"p","lifecycleState":"ACTIVE"}]}"#)
        rules.removeAll { $0.match == ":getKeyString" }
        rules.append(.init(match: ":getKeyString", method: "GET", responses: [#"{}"#]))
        let google = ScriptedGoogle(rules)

        do {
            _ = try await GeminiKeyProvisioner(transport: google, pollInterval: 0).provision()
            XCTFail("expected a failure rather than an empty key")
        } catch let failure as GeminiKeyProvisioner.Failure {
            guard case .step(let step, _) = failure else { return XCTFail("wrong failure") }
            XCTAssertEqual(step, .readingKey)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Every failure is read by someone who will never open a terminal.
    func testEveryFailureHasPlainLanguage() {
        let failures: [GeminiKeyProvisioner.Failure] = [
            .noProjectAvailable,
            .operationTimedOut(.creatingKey),
            .step(.enablingServices, "PERMISSION_DENIED")
        ]
        for failure in failures {
            XCTAssertFalse(failure.spokenDescription.isEmpty)
            XCTAssertFalse(failure.spokenDescription.contains("PERMISSION_DENIED"),
                           "raw API status codes must not reach the owner")
        }
    }

    // MARK: Project ids

    /// Globally unique across all of Google Cloud, 6–30 chars, lowercase
    /// alphanumeric and hyphens, not ending in a hyphen.
    func testGeneratedProjectIDsSatisfyGooglesRules() {
        for seed in [UInt32(0), 1, 12345, UInt32.max - 1] {
            let id = GeminiKeyProvisioner.generatedProjectID(random: { seed })
            XCTAssertGreaterThanOrEqual(id.count, 6)
            XCTAssertLessThanOrEqual(id.count, 30)
            XCTAssertFalse(id.hasSuffix("-"))
            XCTAssertEqual(id, id.lowercased())
            XCTAssertNil(
                id.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").inverted)
            )
        }
    }

    func testGeneratedProjectIDsDiffer() {
        let ids = Set((0..<25).map { _ in GeminiKeyProvisioner.generatedProjectID() })
        XCTAssertGreaterThan(ids.count, 1, "a fixed id would collide globally on the second install")
    }

    // MARK: Error envelope

    func testGooglesErrorMessageIsExtracted() {
        let data = Data(#"{"error":{"code":403,"message":"Cloud Resource Manager API has not been used","status":"PERMISSION_DENIED"}}"#.utf8)
        XCTAssertEqual(
            GoogleAuthorizedTransport.googleErrorMessage(data),
            "Cloud Resource Manager API has not been used"
        )
    }

    func testANonGoogleBodyYieldsNoMessage() {
        XCTAssertNil(GoogleAuthorizedTransport.googleErrorMessage(Data("<html>502</html>".utf8)))
    }
}
