import Foundation

// `open(2)`, `O_CREAT` and `O_RDWR` come from libc, not from Foundation, and on
// Linux nothing re-exports them — the lock, and everything else here, goes
// through `POSIXShim.swift`.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Ensures one appliance per machine.
///
/// Two daemons on one machine both read the same Signal socket and both answer, so
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
                // The instruction has to be one the owner can actually carry
                // out, and `launchctl` does not exist off a Mac: telling a Linux
                // owner to run it is a dead end with no door out of it. The
                // rest of the message is deliberately identical, because the
                // problem it describes is.
                #if os(macOS)
                return """
                Another Mynah appliance is already running on this Mac.
                Two of them answer every message twice.
                  stop the other:  launchctl bootout gui/$UID/local.sage.voicebridge
                  or find it:      pgrep -fl "sage-voiced daemon"
                (lock: \(path))
                """
                #else
                return """
                Another Mynah appliance is already running on this machine.
                Two of them answer every message twice.
                  find the other:  pgrep -fl "sage-voiced daemon"
                  then stop it:    kill <pid>, or stop whatever supervises it
                (lock: \(path))
                """
                #endif
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
        #if os(macOS)
        return homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("appliance.lock", isDirectory: false)
        #else
        // `~/Library/Application Support` is a Mac directory, and creating it on
        // a Linux box would leave a stray `Library` folder in the owner's home
        // that nothing else on the system understands. `$XDG_DATA_HOME`
        // (`~/.local/share` when unset) is the per-user equivalent, and it is
        // where `.applicationSupportDirectory` already puts the memory store and
        // the vendored node — so the appliance keeps all of its state in one
        // place on both platforms.
        //
        // Spelled out rather than asked of `FileManager`, because the caller can
        // pass a home directory and a test that does so must not be answered
        // with the real one.
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        return dataHome
            .appendingPathComponent("SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("appliance.lock", isDirectory: false)
        #endif
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
        guard posixLockExclusiveNonBlocking(descriptor) == 0 else {
            posixClose(descriptor)
            throw Failure.alreadyRunning(fileURL.path)
        }
        return descriptor
    }
}
