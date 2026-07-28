import Foundation

/// Ensures one appliance per machine.
///
/// Two daemons on one Mac both read the same Signal socket and both answer, so
/// the owner gets every reply twice. It is easy to reach by accident: a
/// `nohup`'d daemon from before launchd took over, or a second terminal.
/// `install-daemon.sh` kills strays before bootstrapping, but that only helps
/// when the install script is what started it.
///
/// `flock` rather than a pid file. A pid file is a lie waiting to happen — the
/// process dies, the file survives, and the next start refuses because a number
/// in a file matches something unrelated. A kernel lock is released when the
/// holder exits *however* it exits, including SIGKILL, which is exactly the case
/// a pid file gets wrong.
public struct SingleInstance {

    public enum Failure: LocalizedError {
        case alreadyRunning(String)
        case couldNotOpen(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning(let path):
                return """
                Another Mynah appliance is already running on this Mac.
                Two of them answer every message twice.
                  stop the other:  launchctl bootout gui/$UID/local.sage.voicebridge
                  or find it:      pgrep -fl "sage-voiced daemon"
                (lock: \(path))
                """
            case .couldNotOpen(let path):
                return "Could not open the single-instance lock at \(path)"
            }
        }
    }

    private let fileURL: URL

    public init(fileURL: URL = SingleInstance.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("appliance.lock", isDirectory: false)
    }

    /// Takes the lock for the lifetime of this process.
    ///
    /// The descriptor is deliberately never closed: the lock lives as long as
    /// the process does, and closing it is the only way to lose it early.
    /// Returned so a caller that wants to release explicitly can, and ignored by
    /// everyone else.
    @discardableResult
    public func acquire() throws -> Int32 {
        try? OwnerOnlyFileSecurity.prepareDirectory(fileURL.deletingLastPathComponent())

        let descriptor = open(fileURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw Failure.couldNotOpen(fileURL.path)
        }
        // Non-blocking: the point is to fail fast and say why, not to queue
        // behind an appliance that may run for weeks.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Failure.alreadyRunning(fileURL.path)
        }
        return descriptor
    }
}
