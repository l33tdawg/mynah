import XCTest
@testable import SageVoiceCore

/// **That an owner who links a phone gets calling, without anybody's help.**
///
/// Calling used to need a line added by hand to a file on the relay host. The
/// owner named that as the thing to fix: *"call relay secret is something we
/// should be minting for the user bro ... so when they link their signal, this
/// calling thing should be enabled by default"*.
///
/// The properties worth pinning are not "it works" — they are the ones that
/// decide whether this is safe to leave switched on for everybody: that it never
/// blocks linking, that it never sends anything identifying, and that it cannot
/// hand an appliance a half-credential it will fail on later.
final class CallEnrolmentTests: XCTestCase {

    private var directory: URL!
    private var secret: URL!
    private var identity: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("enrol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        secret = directory.appendingPathComponent("call-relay.secret")
        identity = directory.appendingPathComponent("call-relay.id")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func minting(
        status: Int = 200,
        body: String = #"{"id":"abc123","secret":"deadbeef"}"#,
        record: (@Sendable (URLRequest) -> Void)? = nil
    ) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            record?(request)
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    }

    // MARK: The happy path

    func testAMacWithNoCredentialMintsOneAndIsReady() async throws {
        let outcome = await CallEnrolment.enrolIfNeeded(
            secretURL: secret,
            identityURL: identity,
            transport: minting()
        )

        XCTAssertEqual(outcome, .enrolled(id: "abc123"))
        XCTAssertTrue(outcome.isReady)
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "deadbeef")
        XCTAssertEqual(CallEnrolment.identity(at: identity), "abc123")
        XCTAssertTrue(
            CallHost.isSetUpForCalls(secretURL: secret),
            "the appliance minted a credential and still reports itself unable to call"
        )
    }

    /// Enrolment happens once in an appliance's life. This is reached from a
    /// `didSet` that fires on every path to a linked phone, so a second call
    /// must cost a file check and nothing else.
    func testAnAlreadyCredentialledMacDoesNotEnrolAgain() async throws {
        try "provisioned-by-hand".write(to: secret, atomically: true, encoding: .utf8)
        var reached = false

        let outcome = await CallEnrolment.enrolIfNeeded(
            secretURL: secret,
            identityURL: identity,
            transport: minting(record: { _ in reached = true })
        )

        XCTAssertEqual(outcome, .alreadyEnrolled)
        XCTAssertFalse(reached, "a Mac that can already call went back to the relay for another")
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "provisioned-by-hand")
    }

    // MARK: What must never happen

    /// **The privacy line.** Enrolment carries nothing that identifies an owner —
    /// no phone number, no hash of one, no name. A hashed number would have been
    /// the appearance of privacy rather than privacy: the number space is small
    /// enough to walk in seconds.
    func testEnrolmentSendsNothingThatIdentifiesAnybody() async {
        let captured = Captured()

        _ = await CallEnrolment.enrolIfNeeded(
            secretURL: secret,
            identityURL: identity,
            transport: minting(record: { captured.store($0) })
        )

        let request = captured.request
        XCTAssertNotNil(request)
        XCTAssertNil(request?.httpBody, "enrolment grew a body; nothing about the owner may go in it")
        XCTAssertEqual(request?.allHTTPHeaderFields ?? [:], [:], "enrolment grew headers")
        XCTAssertEqual(request?.url?.query, nil, "a query string on an anonymous request")
    }

    /// **A failed enrolment must not look like a working one.** The appliance
    /// reports itself unable to call, which is true, and `//call` says the one
    /// honest sentence about it rather than sending the owner to change models.
    func testARelayThatCannotMintLeavesTheMacHonestlyUnready() async {
        for status in [404, 501] {
            let outcome = await CallEnrolment.enrolIfNeeded(
                secretURL: secret,
                identityURL: identity,
                transport: minting(status: status, body: "")
            )
            XCTAssertEqual(outcome, .relayCannotMint)
            XCTAssertFalse(outcome.isReady)
            XCTAssertFalse(CallHost.isSetUpForCalls(secretURL: secret))
            XCTAssertEqual(CallInvitation.refusal(isSetUpForCalls: false), .notSetUpForCalls)
        }
    }

    func testAnUnreachableRelayIsReportedAndWritesNothing() async {
        struct Offline: Error {}

        let outcome = await CallEnrolment.enrolIfNeeded(
            secretURL: secret,
            identityURL: identity,
            transport: { _ in throw Offline() }
        )

        guard case .couldNotReach = outcome else {
            return XCTFail("expected couldNotReach, got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secret.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: identity.path))
    }

    /// A body that is not what was asked for must not be written as though it
    /// were. Half a credential is worse than none: the Mac would believe it can
    /// call and fail authentication at the relay, which reads as a broken
    /// appliance rather than an unfinished setup.
    func testAMalformedAnswerIsRefusedRatherThanStored() async {
        for body in ["", "not json", #"{"id":"abc"}"#, #"{"id":"","secret":""}"#] {
            let outcome = await CallEnrolment.enrolIfNeeded(
                secretURL: secret,
                identityURL: identity,
                transport: minting(body: body)
            )
            XCTAssertEqual(outcome, .refused(status: 200), "accepted \(body)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: secret.path), "wrote \(body)")
        }
    }

    /// The credential is the owner's, and it lands with the same permissions as
    /// their provider keys and their conversations.
    func testTheMintedCredentialIsWrittenOwnerOnly() async throws {
        _ = await CallEnrolment.enrolIfNeeded(
            secretURL: secret,
            identityURL: identity,
            transport: minting()
        )

        for url in [secret!, identity!] {
            let mode = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.int16Value, 0o600, "\(url.lastPathComponent) is not owner-only")
        }
    }

    // MARK: Hand-provisioned Macs

    /// A Mac carrying a secret from the relay's own file has no id, sends no
    /// header, and is found by scanning — which is what every appliance did
    /// before minting existed. Reading an absent identity must be quiet.
    func testAHandProvisionedApplianceHasNoIdentityAndThatIsFine() {
        XCTAssertNil(CallEnrolment.identity(at: identity))
    }

    func testABlankIdentityFileIsTreatedAsAbsent() throws {
        try "   \n".write(to: identity, atomically: true, encoding: .utf8)
        XCTAssertNil(
            CallEnrolment.identity(at: identity),
            "a blank id would be sent as a header the relay derives a wrong secret from"
        )
    }
}

/// Captures across the sendable boundary the transport closure imposes.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?

    func store(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        stored = request
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
