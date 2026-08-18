import Foundation

// **This file is the one place that decides what owner-only means on disk, and
// `writeSecret` is the one call that refuses to publish what it could not
// protect.**
//
// `write` and `writeSecret` differ by exactly one guarantee. `write` sets the
// mode and moves on. `writeSecret` reads the protection back off the staged file
// and deletes it unread if the answer is not "this account alone", so a secret
// this code could not protect never reaches the path anything else looks at.
// Provider API keys, the appliance agent key, OAuth refresh tokens and the
// WhatsApp api-token all go through that second door.
//
// **Encrypting these files at rest is the tempting wrong answer for the one that
// matters most, so the rule is written down here.**
// `MynahIdentity.applianceKeyURL()` is handed to the SAGE node as a *path*
// (`SAGE_VENDORED_AGENT_KEY_FILE`) and a foreign process parses those 32 Ed25519
// seed bytes itself. Encrypt it and the node cannot read it, so it mints a *new*
// key — a new agent id, an appliance with no memories and no grant. So:
// encryption at rest is permitted only for files whose sole reader is this Swift
// process; it is forbidden for the appliance key, the WhatsApp api-token and
// anything under signal-cli's data directory. The 0600 mode is the load-bearing
// mechanism.

public enum OwnerOnlyFileSecurity {
    public static let directoryPermissions: NSNumber = 0o700
    public static let filePermissions: NSNumber = 0o600

    public enum Failure: LocalizedError {
        /// The write was abandoned: the contents could not be given owner-only
        /// protection, so they were never published at `path`.
        case couldNotProtect(path: String, reason: String)
        /// A file that already exists can be read by somebody other than the
        /// owner, so its contents were not used.
        case notProtected(path: String)

        public var errorDescription: String? {
            switch self {
            case .couldNotProtect(let path, let reason):
                return """
                Refused to write a secret this machine cannot keep private.
                \(reason)
                Nothing was left at \(path).
                \(OwnerOnlyFileSecurity.remedy(for: path))
                """
            case .notProtected(let path):
                return """
                \(path) can be read by other accounts on this machine, so it was not used.
                A credential every account signed in here can read is not a credential.
                \(OwnerOnlyFileSecurity.remedy(for: path))
                """
            }
        }
    }

    /// The command that fixes it, spelled the way the owner's own shell spells
    /// it — a refusal that does not name the way out is a dead end.
    static func remedy(for path: String) -> String {
        """
          make it owner-only:  chmod 600 "\(path)"
          then check it:       ls -l "\(path)"
        """
    }

    public static func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: url.path)
    }

    /// Writes owner-only from the first byte.
    ///
    /// `Data.write(to:options:.atomic)` creates a fresh file at 0644 and only
    /// then can it be chmod'ed, so every first write published the contents
    /// world-readable for the moment in between. Measured on this machine: the
    /// intermediate mode really is 0644. It is a small window and it is on the
    /// owner's own conversations and keys, which is exactly the material that
    /// does not get a small window.
    public static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try writeStaged(data, to: url, fileManager: fileManager, mustBeProtected: false)
    }

    /// The same write, for material where "we tried" is not an acceptable
    /// outcome: provider API keys, the appliance agent key, OAuth refresh
    /// tokens, the WhatsApp api-token.
    ///
    /// The difference is one guarantee: **the contents never appear at `url`
    /// unless the platform confirms, on being asked afterwards, that only this
    /// account can read them.** The staging file is checked before it is
    /// published and deleted unread if that check fails, so a secret this code
    /// could not protect never reaches the path anything else looks at. It is
    /// control flow rather than a comment because a secret that is only
    /// *probably* unreadable to other accounts has not been protected at all.
    public static func writeSecret(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try writeStaged(data, to: url, fileManager: fileManager, mustBeProtected: true)
    }

    public static func protectFile(_ url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
    }

    /// Asks the platform whether anybody other than this account can read the
    /// file — reading the protection back rather than trusting the call that set
    /// it.
    ///
    /// Conservative in the one direction that matters: anything it cannot
    /// determine is reported unprotected. A missing file, an unreadable security
    /// descriptor and a genuinely world-readable file all answer `false`,
    /// because every one of them is a reason not to hand the contents out.
    public static func isProtected(_ url: URL, fileManager: FileManager = .default) -> Bool {
        // Group and other must have no bits at all. The owner's own bits are not
        // checked: 0700 on a directory and 0600 on a file both pass, and an
        // owner-only file that happens to also be executable is still
        // owner-only.
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let mode = attributes[.posixPermissions] as? NSNumber
        else {
            return false
        }
        return (mode.intValue & 0o077) == 0
    }

    /// The read side of the same contract, for the credentials this package
    /// reads but does not write — signal-cli and the WhatsApp bridge write their
    /// own. Refusing to *use* a credential the platform reports as readable by
    /// others is the other half of refusing to write one.
    public static func requireProtected(_ url: URL, fileManager: FileManager = .default) throws {
        guard isProtected(url, fileManager: fileManager) else {
            throw Failure.notProtected(path: url.path)
        }
    }

    private static func writeStaged(
        _ data: Data,
        to url: URL,
        fileManager: FileManager,
        mustBeProtected: Bool
    ) throws {
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory, fileManager: fileManager)

        // Same directory, so the replace is a rename rather than a copy across
        // volumes — atomic, and the mode is set before any content exists.
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        guard fileManager.createFile(
            atPath: staging.path,
            contents: nil,
            attributes: [.posixPermissions: filePermissions]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        if mustBeProtected, !isProtected(staging, fileManager: fileManager) {
            // Deleted, not published: the caller gets an error and the disk gets
            // nothing. This branch is the entire difference between `write` and
            // `writeSecret`.
            try? fileManager.removeItem(at: staging)
            throw Failure.couldNotProtect(
                path: url.path,
                reason: "The file could not be made unreadable to other accounts on this machine."
            )
        }

        #if canImport(Darwin)
        _ = try fileManager.replaceItemAt(url, withItemAt: staging)
        #else
        // **`replaceItemAt` cannot create a file off Darwin, and it fails by
        // throwing rather than by writing.**
        //
        // swift-corelibs-foundation implements it as "move the original aside,
        // move the new one in", so with nothing at `url` yet the very first step
        // fails and the call throws `NSCocoaErrorDomain 260 "The file doesn't
        // exist."` — about the *destination* it was asked to create. Measured on
        // swift:6.0-jammy, both architectures.
        //
        // Every owner-only write in this package funnels through here and almost
        // every caller spells it `try?`, so on Linux the *first* write of any
        // file — the appliance status, a kept attachment, a provider key —
        // threw, was swallowed, and the owner was told the work had been done.
        // That is the failure mode this project treats as the worst one there
        // is, and it was one line wide.
        //
        // `rename(2)` is what the comment above always described: same
        // directory, atomic, overwrites, and carries the staging file's mode
        // across, so the contents never exist at `url` unprotected. Darwin keeps
        // `replaceItemAt` untouched.
        let published: Int32 = staging.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return Int32(-1) }
                return rename(source, destination)
            }
        }
        guard published == 0 else {
            try? fileManager.removeItem(at: staging)
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        #endif
        try protectFile(url, fileManager: fileManager)

        if mustBeProtected, !isProtected(url, fileManager: fileManager) {
            // Nearly unreachable — the staging file passed the same check a
            // moment ago. It is here because `replaceItemAt` is documented to
            // carry some of the *destination's* metadata across, which is the
            // one thing that could undo the protection between the two checks.
            // Removing a secret that cannot be protected is better than leaving
            // a readable one, even though it costs the caller a re-auth.
            try? fileManager.removeItem(at: url)
            throw Failure.couldNotProtect(
                path: url.path,
                reason: "Publishing the file left it readable by other accounts, so it was removed again."
            )
        }
    }
}

