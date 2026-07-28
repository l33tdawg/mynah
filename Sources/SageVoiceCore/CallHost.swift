import Foundation

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

    /// Starts an endpoint and returns the link to send.
    ///
    /// Any previous call is stopped first — not merely because two endpoints
    /// would both answer, but because a stale link should stop working the
    /// moment a new one is issued. A call link is a live microphone, and the
    /// owner assumes the last one they were sent is the only one that works.
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
        process.arguments = [
            "-relay", relayURL,
            "-relay-secret-file", secretURL.path,
            "-token", token
        ]
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
