import Foundation

/// Gets this Mac its own credential for the call relay, without asking anyone.
///
/// ## Why this exists
///
/// Calling used to need a line added by hand to a file on the relay host. That
/// is a workaround wearing the clothes of a feature: it does not scale past the
/// people who can ssh there, and it left an owner who had linked their phone
/// holding half a product with no way to ask for the other half. Worse, the
/// thing standing in their way was never named — `//call` sent them off to
/// change their brain, which fixed nothing.
///
/// The owner's instruction: *"call relay secret is something we should be
/// minting for the user bro ... so when they link their signal, this calling
/// thing should be enabled by default"*.
///
/// ## What the relay hands back, and what it keeps
///
/// Nothing. The secret is `HMAC(rootKey, id)`, so the relay recomputes it from
/// the id on every later request and stores no record of this Mac at all. There
/// is no account, no user table, and so nothing to leak, and losing this file
/// costs an enrolment rather than a recovery flow.
///
/// ## What is sent
///
/// Nothing that identifies anybody. No phone number, no hash of one, no name.
/// That is deliberate and it is the reason enrolment is anonymous: a central
/// server holding a list of who owns an appliance is exactly the thing this
/// product promises not to be, and hashing a phone number would have been the
/// appearance of privacy rather than privacy — the number space is small enough
/// to walk in seconds.
///
/// The relay rate limits per address in place of identifying anyone, which is
/// the trade being made and is worth naming rather than burying.
///
/// ## Two files, not one
///
/// The secret keeps the path and the exact format it already had, so a Mac
/// provisioned by hand before any of this keeps working untouched and the call
/// endpoint's own reader did not have to change. The id goes beside it. An id
/// with no secret is meaningless and a secret with no id is a hand-provisioned
/// appliance, so the pair degrades in the only direction that matters.
public enum CallEnrolment {

    /// What happened, in terms the caller can log or show.
    ///
    /// Never thrown. This runs off the end of linking a phone, and an appliance
    /// that refused to finish linking because an optional extra could not reach
    /// a server would be trading the feature the owner asked for against the one
    /// they were in the middle of setting up.
    public enum Outcome: Equatable, Sendable {
        /// Already had a secret. Enrolment is once in an appliance's life.
        case alreadyEnrolled
        case enrolled(id: String)
        /// The relay is reachable and does not offer minting — an older
        /// deployment, or one started without a root key.
        case relayCannotMint
        case couldNotReach(String)
        case refused(status: Int)

        public var isReady: Bool {
            switch self {
            case .alreadyEnrolled, .enrolled: return true
            case .relayCannotMint, .couldNotReach, .refused: return false
            }
        }

        /// One line for `bridge.log`. No URLs and no secrets: this is written to
        /// a file that has already had to have the owner's phone number scrubbed
        /// out of it once.
        public var logLine: String {
            switch self {
            case .alreadyEnrolled: return "calls: this Mac already has a relay identity"
            case .enrolled(let id): return "calls: enrolled with the relay as \(id.prefix(8))…"
            case .relayCannotMint: return "calls: the relay does not offer enrolment"
            case .couldNotReach(let why): return "calls: could not reach the relay (\(why))"
            case .refused(let status): return "calls: the relay refused enrolment (\(status))"
            }
        }
    }

    /// Where the minted identity lives, beside the secret it belongs to.
    public static func defaultIdentity(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent(".sage/call-relay.id")
    }

    /// Mints a credential if this Mac has none.
    ///
    /// Idempotent on the secret rather than on the id, because the secret is what
    /// `CallHost.isSetUpForCalls` and the endpoint both read. A Mac carrying a
    /// hand-provisioned secret and no id is already set up and must not be given
    /// a second identity on top of it.
    @discardableResult
    public static func enrolIfNeeded(
        relayURL: String = CallHost.defaultRelay,
        secretURL: URL = CallHost.defaultSecret(),
        identityURL: URL = CallEnrolment.defaultIdentity(),
        fileManager: FileManager = .default,
        transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) async -> Outcome {
        if fileManager.isReadableFile(atPath: secretURL.path) {
            return .alreadyEnrolled
        }

        guard let endpoint = URL(string: relayURL.trimmingSuffix("/") + "/appliance/enrol") else {
            return .couldNotReach("the relay address is not a URL")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Short. This runs behind the owner finishing setup, and a minute spent
        // waiting on a relay that is not answering is a minute of a progress
        // spinner on a step they did not ask for.
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            return .couldNotReach(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 on an older relay, 501 on one started without a root key. Both mean
        // "this deployment cannot mint", which is an operator's problem and not
        // something to retry at the owner.
        if status == 404 || status == 501 { return .relayCannotMint }
        guard status == 200 else { return .refused(status: status) }

        struct Minted: Decodable {
            let id: String
            let secret: String
        }
        guard let minted = try? JSONDecoder().decode(Minted.self, from: data),
              !minted.id.isEmpty,
              !minted.secret.isEmpty else {
            return .refused(status: status)
        }

        do {
            try fileManager.createDirectory(
                at: secretURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Secret first. A crash between the two writes leaves a secret with
            // no id, which the relay still accepts by scanning — where an id
            // with no secret is an appliance that believes it is set up and
            // cannot authenticate.
            try OwnerOnlyFileSecurity.write(
                Data(minted.secret.utf8), to: secretURL, fileManager: fileManager
            )
            try OwnerOnlyFileSecurity.write(
                Data(minted.id.utf8), to: identityURL, fileManager: fileManager
            )
        } catch {
            return .couldNotReach("could not save the credential: \(error.localizedDescription)")
        }
        return .enrolled(id: minted.id)
    }

    /// This Mac's minted identity, or nil when it carries a hand-provisioned
    /// secret instead. Passed to the endpoint as `-appliance-id`.
    public static func identity(
        at url: URL = CallEnrolment.defaultIdentity(),
        fileManager: FileManager = .default
    ) -> String? {
        guard let data = fileManager.contents(atPath: url.path),
              let id = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
