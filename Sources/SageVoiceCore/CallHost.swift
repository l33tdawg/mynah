import Foundation

/// Starts a call on demand and hands back a link.
///
/// Everything a call needs is set up here rather than asked of the owner: a
/// certificate is generated the first time, the endpoint is started with a
/// fresh single-use path, and the URL comes back over Signal. The owner types
/// `//call` and taps a link.
///
/// ## Why there is a certificate at all
///
/// `getUserMedia` is refused outside a secure context, and `http://192.168.1.10`
/// is not one. Without HTTPS the page loads, the button works, and the
/// microphone never opens — with an error only a console would show. Localhost
/// is exempt, which is exactly why this would have looked fine on the Mac and
/// failed on the phone.
///
/// A self-signed certificate means the phone shows a warning. That is the honest
/// cost of not routing the owner's voice through somebody else's tunnel, and the
/// invitation says so before they tap rather than leaving them to meet it cold.
public actor CallHost {

    public enum Failure: Error, CustomStringConvertible {
        case noEndpointBinary(String)
        case couldNotGenerateCertificate(String)
        case endpointExited(Int32)

        public var description: String {
            switch self {
            case .noEndpointBinary(let path):
                return "the call endpoint is not installed at \(path)"
            case .couldNotGenerateCertificate(let detail):
                return "could not make a certificate for this Mac: \(detail)"
            case .endpointExited(let status):
                return "the call endpoint stopped immediately (status \(status))"
            }
        }
    }

    private let endpointURL: URL
    private let directory: URL
    private let port: Int
    private var running: Process?

    public init(
        endpointURL: URL,
        directory: URL = CallHost.defaultDirectory(),
        port: Int = 8090
    ) {
        self.endpointURL = endpointURL
        self.directory = directory
        self.port = port
    }

    public static func defaultDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("Calling", isDirectory: true)
    }

    /// Starts an endpoint and returns the link to send.
    ///
    /// Any previous call is stopped first. Two endpoints cannot share the port,
    /// and more importantly a stale link should stop working the moment a new
    /// one is issued — a call link is a live microphone, and the owner assumes
    /// the last one they were sent is the only one that works.
    public func start(
        address: String,
        runner: ProbeCommandRunning = ProbeCommandRunner()
    ) async throws -> String {
        stop()

        guard FileManager.default.isExecutableFile(atPath: endpointURL.path) else {
            throw Failure.noEndpointBinary(endpointURL.path)
        }
        try OwnerOnlyFileSecurity.prepareDirectory(directory)
        let (certificate, key) = try await certificate(for: address, runner: runner)

        let token = CallInvitation.token()
        let process = Process()
        process.executableURL = endpointURL
        process.arguments = [
            "-addr", "0.0.0.0:\(port)",
            "-cert", certificate.path,
            "-key", key.path,
            "-token", token
        ]
        // Inherited, so the endpoint's log lands in the same place as the
        // daemon's and a failed call is diagnosable from one file.
        try process.run()
        running = process

        // A moment to fail. Binding a port that is already taken, or a
        // certificate it cannot read, both exit immediately — and handing the
        // owner a link to a process that is already gone is worse than saying
        // the call could not start.
        try? await Task.sleep(for: .milliseconds(400))
        if !process.isRunning {
            running = nil
            throw Failure.endpointExited(process.terminationStatus)
        }

        return "https://\(address):\(port)/\(token)"
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

    /// This Mac's certificate, generated once and reused.
    ///
    /// Regenerating per call would mean a fresh warning every time and no way
    /// for the owner to ever trust it permanently. Reused, they can install it
    /// on the phone once and never see the warning again.
    ///
    /// The address goes in a subjectAltName because a certificate without one is
    /// rejected outright by modern browsers — the common name has not been
    /// consulted for years, and getting this wrong produces a warning that
    /// cannot be clicked through on iOS rather than one that can.
    private func certificate(
        for address: String,
        runner: ProbeCommandRunning
    ) async throws -> (certificate: URL, key: URL) {
        let certificate = directory.appendingPathComponent("call-cert.pem")
        let key = directory.appendingPathComponent("call-key.pem")

        if FileManager.default.fileExists(atPath: certificate.path),
           FileManager.default.fileExists(atPath: key.path),
           await certificateCovers(address: address, certificate: certificate, runner: runner) {
            return (certificate, key)
        }

        let result = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                "-days", "825",
                "-nodes",
                "-keyout", key.path,
                "-out", certificate.path,
                "-subj", "/CN=Mynah on this Mac",
                "-addext", "subjectAltName=IP:\(address)"
            ],
            timeout: 60
        )
        guard let result, result.exitCode == 0 else {
            throw Failure.couldNotGenerateCertificate(result?.standardError ?? "openssl did not run")
        }
        try? OwnerOnlyFileSecurity.protectFile(key)
        try? OwnerOnlyFileSecurity.protectFile(certificate)
        return (certificate, key)
    }

    /// Whether the existing certificate still names this address.
    ///
    /// A Mac that moved networks has a new address, and a certificate for the
    /// old one produces a warning the owner cannot get past. Cheaper to check
    /// than to explain.
    private func certificateCovers(
        address: String,
        certificate: URL,
        runner: ProbeCommandRunning
    ) async -> Bool {
        let result = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["x509", "-in", certificate.path, "-noout", "-text"],
            timeout: 15
        )
        guard let result, result.exitCode == 0 else { return false }
        return result.standardOutput.contains("IP Address:\(address)")
    }
}
