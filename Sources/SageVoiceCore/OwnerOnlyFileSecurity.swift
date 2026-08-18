import Foundation

// **The Windows arm of this file is Win32 ACLs, not mode bits, and that is not a
// preference — it is the difference between protecting the owner's credentials
// and only appearing to.**
//
// `FileManager.setAttributes([.posixPermissions:])` is a *valid* call in
// swift-corelibs-foundation on Windows. It compiles, it does not throw, and it
// returns having done approximately nothing: NTFS has no mode bits, so the most
// a Windows implementation can do is toggle `FILE_ATTRIBUTE_READONLY`, which
// cannot deny read access to anybody and has no notion of owner versus other.
// The failure mode on Windows is therefore neither a build error nor an
// exception — it is every credential this appliance holds landing on disk with
// whatever DACL it inherited from the user profile, while this code reports
// success.
//
// That is why the Windows arm is written against `SetNamedSecurityInfoW` with a
// PROTECTED DACL, and why `writeSecret` and `requireProtected` exist at all: for
// a secret, the platform's word that it succeeded is not good enough. The
// protection is read back, and what could not be protected is not published.
//
// **DPAPI is the tempting wrong answer, so the rule is written down here.**
// Encrypting these files at rest with `CryptProtectData` would be a
// per-user-per-machine secret, which sounds strictly better. For the file that
// matters most it is catastrophic: `MynahIdentity.applianceKeyURL()` is handed
// to the SAGE node as a *path* (`SAGE_VENDORED_AGENT_KEY_FILE`) and a foreign
// process parses those 32 Ed25519 seed bytes itself. Encrypt it and the node
// cannot read it, so it mints a *new* key — a new agent id, an appliance with no
// memories and no grant. So: DPAPI is permitted only for files whose sole reader
// is this Swift process; it is forbidden for the appliance key, the WhatsApp
// api-token and anything under signal-cli's data directory; and it is a separate
// change from this one regardless. The ACL is the load-bearing mechanism.

#if os(Windows)
import WinSDK
// `sddl.h` and `aclapi.h` are not reliably surfaced by the WinSDK overlay, so
// `ConvertStringSecurityDescriptorToSecurityDescriptorW` and the named-security
// -info calls arrive through the C shim target instead.
import CWinShim
#endif

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
        /// The platform would not say which account this process is, which is
        /// the prerequisite for protecting anything at all.
        case couldNotDetermineOwner(reason: String)

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
            case .couldNotDetermineOwner(let reason):
                return """
                Could not work out which account Mynah is running as, so nothing can be
                written owner-only. \(reason)
                  check the account:  whoami /user
                  then try again; if it persists, sign out and back in — this is a broken
                  logon token, not a Mynah setting.
                """
            }
        }
    }

    /// The command that fixes it, spelled the way the owner's own shell spells
    /// it. `chmod` does not exist on Windows and `icacls` does not exist
    /// anywhere else, so a message naming the wrong one is a dead end with no
    /// door out of it.
    static func remedy(for path: String) -> String {
        #if os(Windows)
        return """
          make it owner-only:  icacls "\(path)" /inheritance:r /grant:r "%USERNAME%:F"
          then check it:       icacls "\(path)"
        """
        #else
        return """
          make it owner-only:  chmod 600 "\(path)"
          then check it:       ls -l "\(path)"
        """
        #endif
    }

    public static func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        #if os(Windows)
        // Only the leaf is protected, which matches the POSIX arm exactly: there
        // too the intermediates are created under the prevailing umask and only
        // this directory is chmod'ed. The difference is that the Windows grant
        // is *inheritable*, so everything created inside it afterwards is
        // owner-only without a second call — which is what the Signal AF_UNIX
        // socket and the WhatsApp session files depend on, since neither of
        // those is written through this type.
        try applyOwnerOnlyDACL(to: url.path, isDirectory: true)
        #else
        try fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: url.path)
        #endif
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
    /// control flow rather than a comment because on Windows the call that does
    /// the protecting reports success either way.
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
        #if os(Windows)
        try applyOwnerOnlyDACL(to: url.path, isDirectory: false)
        #else
        try fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
        #endif
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
        #if os(Windows)
        return windowsIsProtected(url.path)
        #else
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
        #endif
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
        #if os(Windows)
        try windowsCreateStagingFile(at: staging, contents: data)
        #else
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
        #endif

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

        #if os(Windows)
        // `MoveFileExW`, deliberately not `ReplaceFileW`: `ReplaceFile` is
        // documented to preserve the *replaced* file's security descriptor, so
        // overwriting a file that had been left unprotected would quietly hand
        // that file's DACL to the new contents. A move within one volume keeps
        // the source's DACL, which is the one just built.
        try windowsPublish(staging: staging.path, to: url.path)
        #elseif canImport(Darwin)
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

#if os(Windows)

// MARK: - Windows

// **Two importer spellings in this section are inferred rather than compiled,
// and they are the first thing to check on the first CI run.** Nothing in this
// project has ever been built for Windows, so how the Clang importer spells
// Win32's `BOOL` — `WindowsBool`, `Bool` or plain `Int32` — is answered by the
// compiler and by nothing else. Every use goes through the `succeeded(_:)`
// overloads or the `Win32BOOL` alias below, so the answer is a one-line change
// in one place rather than forty call sites.
//
// Win32 constants are converted with `truncatingIfNeeded` throughout, never with
// a plain `UInt32(_:)`. `PROTECTED_DACL_SECURITY_INFORMATION` is 0x80000000 and
// may arrive as a negative `Int32`; a plain conversion would trap at run time on
// precisely the flag that makes this file do its job.
extension OwnerOnlyFileSecurity {

    /// Whatever `BOOL` turned out to be, for the out-parameters that need a
    /// declared variable rather than a return value.
    fileprivate typealias Win32BOOL = WindowsBool

    /// Three overloads, so this compiles whichever of the three the importer
    /// chose. Exactly one of them is ever selected.
    fileprivate static func succeeded(_ result: Bool) -> Bool { result }
    fileprivate static func succeeded(_ result: WindowsBool) -> Bool { result.boolValue }
    fileprivate static func succeeded(_ result: Int32) -> Bool { result != 0 }

    /// This process's own SID and the two security descriptors built from it.
    ///
    /// Resolved once and cached, failure included. The token buffer and both
    /// descriptors are allocated and **never freed**, deliberately:
    /// `TOKEN_USER.User.Sid` points *into* the token buffer, and
    /// `ownerOnlySecurityAttributes()` hands the descriptor pointer to callers
    /// who keep it for the life of a named pipe. One fixed allocation for the
    /// life of the process is the right shape; a `defer { free }` would leave
    /// every consumer holding a dangling pointer.
    fileprivate struct OwnerIdentity {
        let sid: PSID
        let fileDescriptor: PSECURITY_DESCRIPTOR
        let fileDACL: UnsafeMutablePointer<ACL>
        let directoryDACL: UnsafeMutablePointer<ACL>
    }

    /// Not `Result`: `String` is not an `Error`, and the reason wants to stay a
    /// plain sentence so both the throwing and the non-throwing caller can use
    /// it without one of them having to unwrap an error it will discard.
    fileprivate enum OwnerIdentityResolution {
        case resolved(OwnerIdentity)
        case unavailable(String)
    }

    fileprivate static let ownerIdentity: OwnerIdentityResolution = resolveOwnerIdentity()

    fileprivate static func resolvedIdentity() throws -> OwnerIdentity {
        switch ownerIdentity {
        case .resolved(let identity):
            return identity
        case .unavailable(let reason):
            throw Failure.couldNotDetermineOwner(reason: reason)
        }
    }

    // MARK: Applying the DACL

    static func applyOwnerOnlyDACL(to path: String, isDirectory: Bool) throws {
        let owner = try resolvedIdentity()
        let dacl = isDirectory ? owner.directoryDACL : owner.fileDACL

        let information =
            SECURITY_INFORMATION(truncatingIfNeeded: DACL_SECURITY_INFORMATION)
            | SECURITY_INFORMATION(truncatingIfNeeded: PROTECTED_DACL_SECURITY_INFORMATION)
            | SECURITY_INFORMATION(truncatingIfNeeded: OWNER_SECURITY_INFORMATION)

        let status = withMutableWideString(path) { name in
            SetNamedSecurityInfoW(name, SE_FILE_OBJECT, information, owner.sid, nil, dacl, nil)
        }
        guard status == DWORD(truncatingIfNeeded: ERROR_SUCCESS) else {
            throw Failure.couldNotProtect(
                path: path,
                reason: "Setting the owner-only ACL failed: \(windowsErrorText(status))."
            )
        }
    }

    // MARK: Writing

    /// `CREATE_NEW` is required, not merely preferred: `SECURITY_ATTRIBUTES` is
    /// ignored when `CreateFileW` opens a file that already exists, so any other
    /// disposition would write the secret into whatever DACL was already sitting
    /// on that name. The share mode is 0 for the same reason the POSIX arm
    /// writes to a staging name — nothing else may hold this open while it is
    /// being filled.
    static func windowsCreateStagingFile(at url: URL, contents: Data) throws {
        var attributes = try ownerOnlySecurityAttributes()
        let handle = withUnsafeMutablePointer(to: &attributes) { security in
            withMutableWideString(url.path) { path in
                CreateFileW(
                    path,
                    DWORD(truncatingIfNeeded: GENERIC_WRITE),
                    0,
                    security,
                    DWORD(truncatingIfNeeded: CREATE_NEW),
                    DWORD(truncatingIfNeeded: FILE_ATTRIBUTE_NORMAL),
                    nil
                )
            }
        }
        // `CreateFileW`'s documented failure value is INVALID_HANDLE_VALUE. It
        // does not return NULL.
        guard handle != INVALID_HANDLE_VALUE else {
            throw Failure.couldNotProtect(
                path: url.path,
                reason: "Creating the protected staging file failed: \(windowsErrorText(GetLastError()))."
            )
        }
        let written: Bool = contents.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                // An empty file is a legitimate write — `PauseState` makes one.
                return true
            }
            var offset = 0
            while offset < buffer.count {
                var thisTime: DWORD = 0
                let remaining = DWORD(truncatingIfNeeded: min(buffer.count - offset, Int(DWORD.max)))
                guard
                    succeeded(WriteFile(handle, base.advanced(by: offset), remaining, &thisTime, nil)),
                    thisTime > 0
                else {
                    return false
                }
                offset += Int(thisTime)
            }
            return true
        }
        // The error code first, because `CloseHandle` overwrites it — and the
        // close before the delete, because this handle was opened with share
        // mode 0 and a file nothing may share cannot be deleted while it is
        // still open. A `defer` here would leave the staging file behind on
        // every failed write.
        let reason = written ? "" : windowsErrorText(GetLastError())
        CloseHandle(handle)
        guard written else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.couldNotProtect(path: url.path, reason: "Writing the staging file failed: \(reason).")
        }
    }

    static func windowsPublish(staging: String, to destination: String) throws {
        let flags = DWORD(truncatingIfNeeded: MOVEFILE_REPLACE_EXISTING)
            | DWORD(truncatingIfNeeded: MOVEFILE_WRITE_THROUGH)
        let moved = withMutableWideString(staging) { from in
            withMutableWideString(destination) { to in
                succeeded(MoveFileExW(from, to, flags))
            }
        }
        guard moved else {
            let reason = windowsErrorText(GetLastError())
            try? FileManager.default.removeItem(atPath: staging)
            throw Failure.couldNotProtect(path: destination, reason: "Publishing the file failed: \(reason).")
        }
    }

    // MARK: Reading the protection back

    /// True only if the DACL is PROTECTED *and* every ACE on it is an allow ACE
    /// for this account.
    ///
    /// Both halves are needed. A DACL that grants only the owner but still
    /// inherits from the profile picks up Administrators again the next time the
    /// profile's ACL changes; a protected DACL that also names SYSTEM is not
    /// owner-only. A NULL DACL is the worst case of the three — it grants
    /// everyone full access — and is reported unprotected here rather than read
    /// as "no restrictions found".
    static func windowsIsProtected(_ path: String) -> Bool {
        guard case .resolved(let owner) = ownerIdentity else {
            return false
        }

        var descriptor: PSECURITY_DESCRIPTOR?
        var dacl: UnsafeMutablePointer<ACL>?
        let status = withMutableWideString(path) { name in
            GetNamedSecurityInfoW(
                name,
                SE_FILE_OBJECT,
                SECURITY_INFORMATION(truncatingIfNeeded: DACL_SECURITY_INFORMATION),
                nil,
                nil,
                &dacl,
                nil,
                &descriptor
            )
        }
        guard status == DWORD(truncatingIfNeeded: ERROR_SUCCESS), let descriptor else {
            return false
        }
        defer { LocalFree(descriptor) }

        var control: SECURITY_DESCRIPTOR_CONTROL = 0
        var revision: DWORD = 0
        guard succeeded(GetSecurityDescriptorControl(descriptor, &control, &revision)) else {
            return false
        }
        let protectedBit = SECURITY_DESCRIPTOR_CONTROL(truncatingIfNeeded: SE_DACL_PROTECTED)
        guard control & protectedBit == protectedBit else {
            return false
        }

        guard let dacl else {
            return false
        }
        let aceCount = Int(dacl.pointee.AceCount)
        guard aceCount > 0 else {
            return false
        }
        // An ACE is a header, then the access mask, then the SID laid out
        // inline. The offset is spelled out rather than taken from a key path
        // because `SidStart` is the C idiom for "the variable-length tail starts
        // here" and its declared type is a single DWORD, not the SID it stands
        // for.
        let sidOffset = MemoryLayout<ACE_HEADER>.size + MemoryLayout<DWORD>.size
        let allowedType = UInt8(truncatingIfNeeded: ACCESS_ALLOWED_ACE_TYPE)
        for index in 0..<aceCount {
            var entry: UnsafeMutableRawPointer?
            guard succeeded(GetAce(dacl, DWORD(index), &entry)), let entry else {
                return false
            }
            guard entry.assumingMemoryBound(to: ACE_HEADER.self).pointee.AceType == allowedType else {
                return false
            }
            guard succeeded(EqualSid(entry.advanced(by: sidOffset), owner.sid)) else {
                return false
            }
        }
        return true
    }

    // MARK: The contract the transports use

    /// The owner-only descriptor as `SECURITY_ATTRIBUTES`, for callers that
    /// create a kernel object rather than a file.
    ///
    /// The WhatsApp named pipe is the one that matters. `CreateNamedPipeW` with
    /// NULL security attributes gets a default descriptor that grants read
    /// access to Everyone and to Anonymous, and Node — the peer — offers no way
    /// to pass a descriptor at all. Handing this out is what lets the Swift side
    /// be the listener and keep the 0600 property that AF_UNIX gave us for free
    /// on the other two platforms.
    ///
    /// The descriptor behind it lives as long as the process, so the returned
    /// struct may be held and reused.
    public static func ownerOnlySecurityAttributes() throws -> SECURITY_ATTRIBUTES {
        let owner = try resolvedIdentity()
        var attributes = SECURITY_ATTRIBUTES()
        attributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        attributes.lpSecurityDescriptor = owner.fileDescriptor
        // Zero-initialised, so `bInheritHandle` is already FALSE — which is what
        // is wanted: a child process must not inherit a handle to the owner's
        // credentials.
        return attributes
    }

    // MARK: Plumbing

    /// `SetNamedSecurityInfoW` takes a *mutable* `LPWSTR`, so the wide buffer has
    /// to be one this side owns. `GetNamedSecurityInfoW` takes a const one and
    /// accepts the same pointer.
    fileprivate static func withMutableWideString<T>(
        _ value: String,
        _ body: (UnsafeMutablePointer<WCHAR>) -> T
    ) -> T {
        var buffer = Array(value.utf16)
        buffer.append(0)
        return buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    fileprivate static func windowsErrorText(_ code: DWORD) -> String {
        // A fixed buffer rather than FORMAT_MESSAGE_ALLOCATE_BUFFER: the
        // allocating form wants a pointer-to-pointer cast to LPWSTR, which is
        // ugly and easy to get wrong in Swift, and this is an error message.
        var buffer = [WCHAR](repeating: 0, count: 512)
        let flags = DWORD(truncatingIfNeeded: FORMAT_MESSAGE_FROM_SYSTEM)
            | DWORD(truncatingIfNeeded: FORMAT_MESSAGE_IGNORE_INSERTS)
        let length = buffer.withUnsafeMutableBufferPointer { output in
            FormatMessageW(flags, nil, code, 0, output.baseAddress, DWORD(output.count), nil)
        }
        guard length > 0 else {
            return "Windows error \(code)"
        }
        let text = String(decoding: buffer[0..<Int(length)], as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Windows error \(code)" : "\(text) (\(code))"
    }

    private static func resolveOwnerIdentity() -> OwnerIdentityResolution {
        var token: HANDLE?
        guard
            succeeded(OpenProcessToken(GetCurrentProcess(), DWORD(truncatingIfNeeded: TOKEN_QUERY), &token)),
            let token
        else {
            return .unavailable("This process could not open its own access token (\(windowsErrorText(GetLastError()))).")
        }
        defer { CloseHandle(token) }

        var size: DWORD = 0
        // Documented to fail with ERROR_INSUFFICIENT_BUFFER and fill in `size`.
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard size > 0 else {
            return .unavailable("The access token reported no user information.")
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<TOKEN_USER>.alignment
        )
        guard succeeded(GetTokenInformation(token, TokenUser, storage, size, &size)) else {
            storage.deallocate()
            return .unavailable("The access token would not yield this account's SID (\(windowsErrorText(GetLastError()))).")
        }
        guard let sid = storage.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid else {
            storage.deallocate()
            return .unavailable("The access token yielded no SID for this account.")
        }

        var stringSID: LPWSTR?
        guard succeeded(ConvertSidToStringSidW(sid, &stringSID)), let stringSID else {
            storage.deallocate()
            return .unavailable("This account's SID could not be written out in text form.")
        }
        let sidText = String(decodingCString: stringSID, as: UTF16.self)
        LocalFree(stringSID)

        // `P` — protected — is the load-bearing character: it breaks inheritance
        // from the user profile, so Administrators and SYSTEM do not come along
        // underneath our ACE. `FA` is full access. `OICI` on the directory makes
        // the grant inheritable by the files and subdirectories created inside
        // it, which is how the Signal socket and the WhatsApp session files
        // become owner-only without being written through this type.
        func descriptor(_ sddl: String) -> PSECURITY_DESCRIPTOR? {
            var built: PSECURITY_DESCRIPTOR?
            let ok = sddl.withCString(encodedAs: UTF16.self) { text in
                succeeded(
                    ConvertStringSecurityDescriptorToSecurityDescriptorW(
                        text,
                        DWORD(truncatingIfNeeded: SDDL_REVISION_1),
                        &built,
                        nil
                    )
                )
            }
            return ok ? built : nil
        }

        guard
            let fileDescriptor = descriptor("O:\(sidText)G:\(sidText)D:P(A;;FA;;;\(sidText))"),
            let directoryDescriptor = descriptor("O:\(sidText)G:\(sidText)D:P(A;OICI;FA;;;\(sidText))")
        else {
            storage.deallocate()
            return .unavailable("The owner-only security descriptor could not be built for \(sidText).")
        }

        // `SetNamedSecurityInfoW` wants the ACL, not the whole descriptor.
        func dacl(_ descriptor: PSECURITY_DESCRIPTOR) -> UnsafeMutablePointer<ACL>? {
            var present: Win32BOOL = false
            var defaulted: Win32BOOL = false
            var acl: UnsafeMutablePointer<ACL>?
            guard
                succeeded(GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted)),
                succeeded(present)
            else {
                return nil
            }
            return acl
        }

        guard let fileDACL = dacl(fileDescriptor), let directoryDACL = dacl(directoryDescriptor) else {
            storage.deallocate()
            return .unavailable("The owner-only ACL could not be read back out of its security descriptor.")
        }

        return .resolved(
            OwnerIdentity(
                sid: sid,
                fileDescriptor: fileDescriptor,
                fileDACL: fileDACL,
                directoryDACL: directoryDACL
            )
        )
    }
}

#endif
