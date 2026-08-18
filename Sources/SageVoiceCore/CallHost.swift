import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Starts a call on demand and hands back a link.
///
/// The owner types `//call` and taps a link. Everything a call needs is arranged
/// here rather than asked of them.
///
/// ## Why this Mac does not serve the page
///
/// It did, and that is exactly what failed. A Mac on a home network has no name
/// a certificate authority will sign, so serving the page from it meant a
/// self-signed certificate — and browsers do not merely warn about those. They
/// refuse to persist a permission for the origin, and without a persisted media
/// permission Chrome replaces the phone's real ICE candidates with random
/// `.local` names. Phone and Mac end up on the same Wi-Fi, unable to name each
/// other: a page that says *Connected* and carries no audio.
///
/// So the page comes from the relay, which has a real certificate, and this Mac
/// dials out and waits. No port to forward, no certificate to install, no
/// address that has to stay reachable — the same reason natter exists for SAGE.
///
/// The relay is not in the call. It carries the offer and the answer; the
/// candidates inside them describe routes between the phone and this Mac, and on
/// a shared network the audio crosses the room without touching it.
public actor CallHost {

    public enum Failure: Error, CustomStringConvertible {
        case noEndpointBinary(String)
        case noSharedSecret(String)
        case endpointExited(Int32)
        case relayNeverAnswered(String)
        #if !os(macOS)
        /// **Off-Darwin only, and it exists so the refusal has a name.**
        ///
        /// `Package.swift` excludes `Sources/SageVoiceCore/Call/` on Linux and
        /// Windows: the live voice call is a Mac feature and is not ported.
        /// This type stays because `CallEnrolment` and the daemon read its
        /// paths and its readiness check, but `start()` there has no endpoint
        /// to run and no appliance socket to point one at. It says so rather
        /// than starting something that could not carry audio.
        case notOnThisPlatform
        #endif

        /// For the log. Paths and exit statuses belong here and only here.
        public var description: String {
            switch self {
            case .noEndpointBinary(let path):
                return "the call endpoint is not installed at \(path)"
            case .noSharedSecret(let path):
                return "this Mac has no relay secret at \(path)"
            case .endpointExited(let status):
                return "the call endpoint stopped immediately (status \(status))"
            case .relayNeverAnswered(let url):
                return "the relay never listed this call at \(url)"
            #if !os(macOS)
            case .notOnThisPlatform:
                return "calls are not built into this platform's build of the appliance"
            #endif
            }
        }

        /// For the owner, whose phone this arrives on.
        ///
        /// **`description` used to be what he got.** `handleCallRequest` caught
        /// this error and sent `"\(error)"` back over Signal, so asking for a
        /// call on a Mac with no relay secret replied:
        ///
        ///     I couldn't start the call: this Mac has no relay secret at
        ///     /Users/<him>/.sage/call-relay.secret
        ///
        /// A path inside his own home directory, texted to his phone. Verified
        /// on this machine — the file genuinely is absent, so that is the live
        /// message today for anyone who switches to a fast model and tries it.
        ///
        /// Nothing that reaches the owner comes from an exception string. These
        /// are authored per case, the way `Exchange.Failure` and
        /// `ApplianceWriteReadiness` already do it, and they say what he can do
        /// rather than what the process found.
        public var ownerSentence: String {
            switch self {
            case .noEndpointBinary:
                // Actionable, and the action is not his to take at a terminal:
                // the endpoint ships inside the app, so a missing one means the
                // install is wrong rather than something he forgot.
                return "the part of Mynah that handles calls isn't installed. Reinstalling "
                    + "Mynah should put it back."
            case .noSharedSecret:
                // The one setup step that is genuinely outside the app. Named
                // without a path, because a path he has never seen is not a
                // next step — it is a puzzle.
                return "this Mac hasn't been set up for calls yet."
            case .endpointExited, .relayNeverAnswered:
                // Nothing for him to change. A transient, said as one.
                return "something went wrong setting it up. Try again in a moment."
            #if !os(macOS)
            case .notOnThisPlatform:
                // Not a fault and not a transient — this appliance will never
                // do it, so "try again" would be a road ending in a wall. The
                // door is the surface he is already on.
                return "calls only work on the Mac version of Mynah. Keep messaging me here "
                    + "and I'll answer in the chat."
            #endif
            }
        }
    }

    private let endpointURL: URL
    private let relayURL: String
    private let secretURL: URL
    private var running: Process?

    public init(
        endpointURL: URL,
        relayURL: String = CallHost.defaultRelay,
        secretURL: URL = CallHost.defaultSecret()
    ) {
        self.endpointURL = endpointURL
        self.relayURL = relayURL
        self.secretURL = secretURL
    }

    public static let defaultRelay = "https://call.sage.delivery"

    public static func defaultSecret(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent(".sage/call-relay.secret")
    }

    /// Whether this Mac has ever been set up for calls.
    ///
    /// Exists so the refusal can be decided *before* a call is attempted rather
    /// than discovered as a failure during one. The same fact was always
    /// available — `start()` reads this file and throws `noSharedSecret` — but
    /// only after the owner had asked for a call and been told to change his
    /// brain first, which is the wrong order to learn it in.
    public static func isSetUpForCalls(secretURL: URL = CallHost.defaultSecret()) -> Bool {
        FileManager.default.fileExists(atPath: secretURL.path)
    }

    /// Starts an endpoint and returns the link to send.
    ///
    /// Any previous call is stopped first — not merely because two endpoints
    /// would both answer, but because a stale link should stop working the
    /// moment a new one is issued. A call link is a live microphone, and the
    /// owner assumes the last one they were sent is the only one that works.
    #if os(macOS)
    public func start(probe: (String) async -> Bool = CallHost.linkIsLive) async throws -> String {
        stop()

        guard FileManager.default.isExecutableFile(atPath: endpointURL.path) else {
            throw Failure.noEndpointBinary(endpointURL.path)
        }
        guard FileManager.default.isReadableFile(atPath: secretURL.path) else {
            throw Failure.noSharedSecret(secretURL.path)
        }

        let token = CallInvitation.token()
        let process = Process()
        process.executableURL = endpointURL
        var arguments = [
            "-relay", relayURL,
            "-relay-secret-file", secretURL.path,
            "-token", token,
            // Where the brain answers. If nothing is listening the endpoint
            // loops the caller back to themselves rather than dropping the
            // call — which is also how a transport problem gets told apart from
            // an appliance problem, in one call.
            "-appliance", CallTurnServer.defaultSocket().path
        ]
        // Only when this Mac minted its own credential. A hand-provisioned
        // appliance has no id, sends no header, and the relay finds its secret
        // by scanning — which is what every Mac did before minting existed and
        // has to keep working across the deploy that adds it.
        if let id = CallEnrolment.identity() {
            arguments.append(contentsOf: ["-appliance-id", id])
        }
        process.arguments = arguments
        // Inherited, so a failed call is diagnosable from the same log as
        // everything else the appliance did that minute.
        try process.run()
        running = process

        let url = "\(relayURL)/\(token)"

        // The link is not sent until the relay will actually serve it.
        //
        // The endpoint has to reach the relay and register before that path
        // exists, and a link sent a moment early is a 404 in the owner's hand —
        // which reads as a broken appliance rather than as being half a second
        // early. Cheap to wait for, and it turns a race into a guarantee.
        for _ in 0..<20 {
            if !process.isRunning {
                running = nil
                throw Failure.endpointExited(process.terminationStatus)
            }
            if await probe(url) { return url }
            try? await Task.sleep(for: .milliseconds(250))
        }

        stop()
        throw Failure.relayNeverAnswered(relayURL)
    }
    #else
    /// Refuses, by name, everywhere the call is not built.
    ///
    /// The signature is kept so the daemon's `//call` path compiles unchanged
    /// and its existing `catch` turns this into the owner's sentence — the same
    /// route every other `Failure` already takes to his phone. The alternative,
    /// running the endpoint without `-appliance`, would start a call that
    /// reaches no brain; and returning a link that goes nowhere would be the
    /// one thing worse than saying no.
    public func start(probe: (String) async -> Bool = CallHost.linkIsLive) async throws -> String {
        throw Failure.notOnThisPlatform
    }
    #endif

    /// Ends the current call, if any.
    public func stop() {
        guard let process = running, process.isRunning else {
            running = nil
            return
        }
        process.terminate()
        running = nil
    }

    public var isCallActive: Bool {
        running?.isRunning ?? false
    }

    /// Whether the relay is serving this call yet.
    ///
    /// A HEAD, so nothing is fetched and no report is filed against a page the
    /// owner has not opened. The relay answers 404 for a token no appliance is
    /// listening on, which is precisely the question being asked.
    public static func linkIsLive(_ url: String) async -> Bool {
        guard let target = URL(string: url) else { return false }
        var request = URLRequest(url: target)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}
