// **The module's one platform header.**
//
// Every syscall in this package used to be written `Darwin.read(...)`. That
// spelling is not a style choice — it was load-bearing, because `read`, `write`,
// `close` and `connect` are also method names on the types that call them, and
// Swift's unqualified lookup stops at the first scope that has the name rather
// than continuing outward to find an overload that matches the arguments. So
// `close(descriptor)` inside a class with a `close()` method is a compile error,
// not a call to `close(2)`.
//
// `Darwin.` fixes that on a Mac and is a hard error everywhere else: there is no
// `Darwin` module on Linux. The fix is the same trick under a portable name.
// Each wrapper below is a thin, inlined forward to whichever libc this machine
// actually has, and it carries its own qualification, so a caller writes
// `posixClose(descriptor)` and gets `close(2)` on every platform without a
// single `#if` at the call site.
//
// The three differences that are *not* just naming — the type of `SOCK_STREAM`,
// `sun_len`, and how you stop a write to a dead peer from killing the process —
// are also handled here, for the same reason: once, in one auditable place,
// rather than at every call site.
//
// ---
//
// **Windows is the third arm, and it is not a fourth libc.**
//
// The first two arms differ only in spelling: the same call, under a different
// module, occasionally with a different integer type. Windows differs in what
// exists. Three concepts this file used to hand out unconditionally have no
// Windows counterpart at all, and the difference between a *no-op* and an
// *unavailable* declaration below is deliberate every time:
//
//   * `chmod`. ucrt has `_chmod`, and it toggles the read-only attribute. It
//     cannot deny read access to anyone, and it has no notion of owner versus
//     other. Every caller of `posixChangeMode` means `0600` as *deny everyone
//     else*, so forwarding to `_chmod` would return 0, look like success, and
//     leave the credential readable. It is declared `unavailable` here, and the
//     message names `OwnerOnlyFileSecurity` — the Windows ACL is the equivalent,
//     not a mode bit.
//   * `dup(2)` on a socket. `SignalLineSocket` takes a private duplicate under
//     its lock so the read pump cannot close the descriptor out from under a
//     blocking write; the comment there records that the alternative injected
//     JSON-RPC bytes into an unrelated file. `WSADuplicateSocketW` is a
//     different mechanism with different lifetime rules, and `DuplicateHandle`
//     on a `SOCKET` is not blessed by Microsoft. `posixDuplicateSocket` is
//     `unavailable` on Windows and its message names the refcount that gives
//     the identical guarantee.
//   * `SIGPIPE`. This one genuinely *is* a no-op, because Windows already makes
//     the promise: a send to a closed socket returns `WSAECONNRESET` as an error
//     rather than raising a signal that terminates the process. A no-op here
//     means "the guarantee already holds", never "we gave up on it".
//
// The other Windows difference is a type, and it is the dangerous one. A POSIX
// descriptor is a signed `int` where -1 means failure; a Windows `SOCKET` is an
// unsigned `UINT_PTR` where the failure value is `~0`. `PlatformDescriptor` and
// `PlatformSocket` are therefore two typealiases, identical on POSIX and
// different on Windows, so that a call site which conflates a file with a socket
// compiles here and fails to compile there. See `posixSocketIsValid(_:)` for the
// idiom that has to replace `>= 0`, and why.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
// `os(Windows)` rather than `canImport(WinSDK)`, deliberately, so that this
// condition and the one selecting the Windows arm below are the same condition.
// If they could disagree, a missing `WinSDK` would silently skip the imports and
// then fail forty lines later with "cannot find type 'SOCKET' in scope" — a
// misleading error a long way from its cause. Written this way, the failure is
// "no such module 'WinSDK'", which names the actual problem.
import WinSDK
// The Universal CRT arrives as its own overlay rather than through `WinSDK`, and
// this file needs both halves: Win32 for handles, sockets and ACL-adjacent work,
// ucrt for the descriptor-numbered `_read`/`_write`/`_close` that `_open_osfhandle`
// hands back. Guarded because the overlay has been spelled both ways.
#if canImport(CRT)
import CRT
#elseif canImport(ucrt)
import ucrt
#endif
#endif

// MARK: - Paths

/// The two path conventions that differ between platforms.
///
/// Everything else about paths goes through `URL`, which already knows. These
/// two do not appear in `URL` at all: they are the separators inside an
/// environment variable, which is a plain string.
enum PlatformPath {

    /// The character that separates entries in `PATH`.
    ///
    /// A colon on every UNIX; a semicolon on Windows, where the colon is the
    /// second character of `C:\Program Files\...`. Splitting a Windows `PATH` on
    /// `:` produces a list of broken halves, and the lookup then reports "not
    /// installed" for a binary sitting right there — the worst kind of wrong
    /// answer, because it looks like a finding rather than a bug.
    #if os(Windows)
    static let searchPathSeparator: Character = ";"
    #else
    static let searchPathSeparator: Character = ":"
    #endif
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

// MARK: - Handle types

/// An open file, as the kernel numbers it.
///
/// One `int` on every UNIX, and the same `int` on Windows, because
/// `posixOpenPrivate(_:)` deliberately hands its `HANDLE` to `_open_osfhandle`
/// on the way out. Keeping files on a single type across all three platforms is
/// what lets `SingleInstance` stay one code path.
typealias PlatformDescriptor = Int32

/// The value `posixOpenPrivate(_:)` returns when it could not open the file.
let platformInvalidDescriptor: PlatformDescriptor = -1

@inline(__always)
func posixDescriptorIsValid(_ descriptor: PlatformDescriptor) -> Bool {
    descriptor >= 0
}

/// An open socket, as the kernel numbers it.
///
/// The same `int` as a file descriptor here, and *not* the same type on Windows.
/// The two aliases exist so that code which reads a socket with the file call —
/// which is correct on UNIX and wrong on Windows, where a socket is not in the
/// CRT descriptor table at all — is a compile error rather than a runtime
/// surprise on the platform that cannot be tested from this machine.
typealias PlatformSocket = Int32

/// The value `posixSocket(_:_:_:)` returns when it could not open the socket.
let platformInvalidSocket: PlatformSocket = -1

/// Whether `posixSocket(_:_:_:)` or `posixAccept(_:_:_:)` succeeded.
///
/// On UNIX this is the familiar `>= 0` and nothing more. It exists as a function
/// only so that the call sites are already spelled the portable way — see the
/// Windows arm, where writing `>= 0` compiles, is always true, and lets a failed
/// `socket()` through.
@inline(__always)
func posixSocketIsValid(_ socket: PlatformSocket) -> Bool {
    socket >= 0
}

/// Starts the platform's socket library, once per process.
///
/// Nothing to start on a UNIX, so this is a no-op that reports success and lets
/// the caller keep one connect path. On Windows it is `WSAStartup`, and every
/// socket call made before it — including `getaddrinfo` — fails.
@inline(__always)
@discardableResult
func ensureWinsockStarted() -> Bool {
    true
}

// MARK: - Constants that changed type

/// `SOCK_STREAM` as the `Int32` that `socket(2)` and `addrinfo.ai_socktype`
/// want.
///
/// glibc declares the socket types as `enum __socket_type`, and a *tagged* C
/// enum is imported into Swift as a struct with a `rawValue` — not as an
/// integer. So `socket(AF_UNIX, SOCK_STREAM, 0)` compiles on a Mac and fails on
/// Linux with a type mismatch. Darwin and musl both spell it as a plain macro
/// and need no conversion.
#if canImport(Glibc)
let posixSocketStream = Int32(SOCK_STREAM.rawValue)
#else
let posixSocketStream = SOCK_STREAM
#endif

/// `IPPROTO_TCP` as the `Int32` that `addrinfo.ai_protocol` wants.
///
/// The same problem one layer down. glibc collects the protocol numbers in an
/// *anonymous* C enum, and Swift imports the members of an anonymous enum as
/// `Int` — while Darwin and musl leave them as plain macros that arrive as
/// `Int32`. So `hints.ai_protocol = IPPROTO_TCP` compiles on a Mac and fails on
/// Linux. The conversion is spelled once, here, where the value is a small
/// positive constant and the narrowing provably cannot lose anything.
#if canImport(Glibc)
let posixProtocolTCP = Int32(IPPROTO_TCP)
#else
let posixProtocolTCP = IPPROTO_TCP
#endif

// MARK: - Reading and writing

@inline(__always)
@discardableResult
func posixRead(_ descriptor: PlatformDescriptor, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}

@inline(__always)
@discardableResult
func posixWrite(_ descriptor: PlatformDescriptor, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(descriptor, buffer, count)
}

/// `read(2)` from a socket.
///
/// The same call as `posixRead` here, and a different one on Windows, where a
/// socket is not a CRT file descriptor and `_read` cannot see it. Both spellings
/// exist on both platforms so a caller picks the honest one once and never needs
/// an `#if`.
@inline(__always)
@discardableResult
func posixReadFromSocket(_ socket: PlatformSocket, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(socket, buffer, count)
}

/// `write(2)` to a socket, without the process dying if the peer has gone.
///
/// A write to a closed socket raises SIGPIPE, whose default disposition is to
/// terminate the process — so a signal-cli that restarts at the wrong moment
/// would take the appliance down with it rather than surfacing as the write
/// error the caller is already handling.
///
/// The two platforms suppress it in different places. Darwin has the
/// `SO_NOSIGPIPE` socket option, set once at connect time by
/// `posixSuppressSIGPIPE(on:)`, so an ordinary `write` is already safe. Linux
/// has no such option; the flag lives on the call instead, which means the write
/// has to go through `send(2)` to carry it. Same guarantee, different syscall,
/// and neither one changes the bytes on the wire. Windows makes the guarantee
/// natively and needs neither.
@inline(__always)
@discardableResult
func posixWriteToSocket(_ socket: PlatformSocket, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    return write(socket, buffer, count)
    #else
    return send(socket, buffer, count, Int32(MSG_NOSIGNAL))
    #endif
}

// MARK: - Descriptors

@inline(__always)
@discardableResult
func posixClose(_ descriptor: PlatformDescriptor) -> Int32 {
    close(descriptor)
}

/// `close(2)` on a socket.
///
/// Identical to `posixClose` here. Windows has a separate `closesocket`, and
/// calling `_close` on a socket there fails with `EBADF` while leaking the
/// socket — so the two are separate names on every platform.
@inline(__always)
@discardableResult
func posixCloseSocket(_ socket: PlatformSocket) -> Int32 {
    close(socket)
}

@inline(__always)
func posixDuplicate(_ descriptor: PlatformDescriptor) -> PlatformDescriptor {
    dup(descriptor)
}

/// `dup(2)` on a socket.
///
/// Used by `SignalLineSocket.writeSynchronously` to pin a descriptor number for
/// the duration of a blocking write, so the read pump cannot close it and let
/// the number be recycled underneath. See the Windows arm: there is no honest
/// equivalent there, and the declaration says so rather than substituting one.
@inline(__always)
func posixDuplicateSocket(_ socket: PlatformSocket) -> PlatformSocket {
    dup(socket)
}

@inline(__always)
@discardableResult
func posixUnlink(_ path: String) -> Int32 {
    unlink(path)
}

@inline(__always)
@discardableResult
func posixChangeMode(_ path: String, _ mode: mode_t) -> Int32 {
    chmod(path, mode)
}

/// Opens (creating if needed) a file readable and writable by its owner alone.
///
/// The private half is the point: this is the lock file and anything else that
/// wants to exist before `OwnerOnlyFileSecurity` has had a chance to run. `0600`
/// expresses it directly here. On Windows there are no mode bits and the
/// protection is inherited from the directory, which is why that arm is written
/// the way it is.
@inline(__always)
func posixOpenPrivate(_ path: String) -> PlatformDescriptor {
    open(path, O_CREAT | O_RDWR, 0o600)
}

/// `flock(2)`, exclusive, failing immediately rather than queueing.
///
/// A whole-file kernel lock, not a POSIX record lock: a record lock is released
/// when *any* descriptor on the file is closed anywhere in the process, which
/// would hand the lock away the first time some unrelated code opened and closed
/// the same path. `flock` belongs to the open file description and is released
/// only when the holder exits, however it exits.
@inline(__always)
func posixLockExclusiveNonBlocking(_ descriptor: PlatformDescriptor) -> Int32 {
    flock(descriptor, LOCK_EX | LOCK_NB)
}

// MARK: - Sockets

@inline(__always)
func posixSocket(_ domain: Int32, _ type: Int32, _ networkProtocol: Int32) -> PlatformSocket {
    socket(domain, type, networkProtocol)
}

@inline(__always)
func posixConnect(_ socket: PlatformSocket, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(socket, address, length)
}

@inline(__always)
func posixBind(_ socket: PlatformSocket, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    bind(socket, address, length)
}

@inline(__always)
func posixListen(_ socket: PlatformSocket, _ backlog: Int32) -> Int32 {
    listen(socket, backlog)
}

@inline(__always)
func posixAccept(
    _ socket: PlatformSocket,
    _ address: UnsafeMutablePointer<sockaddr>?,
    _ length: UnsafeMutablePointer<socklen_t>?
) -> PlatformSocket {
    accept(socket, address, length)
}

/// `shutdown(2)` in both directions.
///
/// `SHUT_RDWR` lives in another anonymous glibc enum, so it too arrives as `Int`
/// where Darwin and musl hand over an `Int32`, and `shutdown(2)` takes an `int`
/// on all three. Converted here rather than at the call site, for the same
/// reason as everything else in this file. The value is 2 everywhere this
/// builds; the conversion cannot change it, and the `Int32` the kernel returns
/// is passed back untouched, so a -1 still reads as -1.
@inline(__always)
@discardableResult
func posixShutdownReadAndWrite(_ socket: PlatformSocket) -> Int32 {
    #if canImport(Glibc)
    return shutdown(socket, Int32(SHUT_RDWR))
    #else
    return shutdown(socket, SHUT_RDWR)
    #endif
}

/// Stamps the BSD length byte into a UNIX-domain address, where there is one.
///
/// `sockaddr_un.sun_len` is a 4.4BSD field that Darwin kept and Linux never had,
/// so referring to it off-Darwin is a compile error rather than a portability
/// wart. Nothing is lost by skipping it: the length is passed to `connect(2)`
/// separately on both platforms, and Linux's kernel reads it from there.
@inline(__always)
func posixSetUNIXAddressLength(_ address: inout sockaddr_un) {
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
}

/// Asks the kernel never to raise SIGPIPE for this socket.
///
/// Darwin only — see `posixWriteToSocket(_:_:_:)` for how Linux gets the same
/// promise. Deliberately a no-op rather than an error off-Darwin, so the caller
/// keeps one connect path.
@inline(__always)
func posixSuppressSIGPIPE(on socket: PlatformSocket) {
    #if canImport(Darwin)
    var enabled: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

/// Turns on TCP keepalive, so a wedged daemon eventually surfaces as a read
/// error rather than a pump that waits forever.
///
/// Here only to keep `setsockopt` itself out of the transport. Windows declares
/// the option value as `const char *` with an `int` length, where POSIX takes a
/// `const void *` and a `socklen_t` — so the identical call needs a different
/// spelling, which is precisely the kind of difference this file exists to
/// absorb once instead of at each call site.
@inline(__always)
func posixEnableKeepAlive(on socket: PlatformSocket) {
    var enabled: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_KEEPALIVE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

// MARK: - Processes

@inline(__always)
@discardableResult
func posixKill(_ pid: pid_t, _ signalNumber: Int32) -> Int32 {
    kill(pid, signalNumber)
}

/// Stops a process now, with no chance to clean up.
///
/// `SIGKILL` here; `TerminateProcess` on Windows, which has no signals at all.
/// The portable spelling exists because the *polite* half of the pair —
/// `Process.terminate()` — is already portable, and only the escalation needed a
/// name. Returns whether the request was delivered, not whether the process has
/// finished dying; every caller then waits and re-checks `isRunning`.
///
/// Non-positive pids are refused rather than passed through, and that guard is
/// not defensive padding: `kill(0, SIGKILL)` signals *every process in the
/// caller's process group* and `kill(-1, SIGKILL)` signals every process the
/// user owns. `Process.processIdentifier` returns 0 for a process that never
/// launched, so the dangerous argument is the one a failed spawn hands over. The
/// call sites happen to check today; a shared helper that can take down the
/// owner's whole session must not depend on all of them continuing to.
@inline(__always)
@discardableResult
func posixTerminateProcess(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid_t(pid), SIGKILL) == 0
}

@inline(__always)
func posixSleep(microseconds: UInt32) {
    _ = usleep(microseconds)
}

// MARK: - Errors

/// `strerror(errno)` as a Swift `String`.
///
/// Every failing syscall in this package reports itself this way, and the two
/// libcs agree on both halves, so this exists only to keep the spelling in one
/// place.
@inline(__always)
func posixErrorDescription() -> String {
    String(cString: strerror(errno))
}

/// Why the last *socket* call failed.
///
/// The same `errno` here, and a different error channel on Windows, where socket
/// failures land in `WSAGetLastError()` and `errno` holds whatever unrelated CRT
/// call touched it last. Reading `errno` after a socket call on Windows reports a
/// stale, confident, wrong reason — so socket paths get their own accessor on
/// every platform.
@inline(__always)
func posixSocketErrorDescription() -> String {
    posixErrorDescription()
}

/// Whether the last socket call failed only because a signal interrupted it,
/// meaning the caller should retry rather than give up.
@inline(__always)
func posixSocketErrorIsInterrupted() -> Bool {
    errno == EINTR
}

#elseif os(Windows)

// **The Windows arm.**
//
// Written from the documented Win32 and ucrt surfaces, and *not* compiled on the
// machine it was written on — there is no Windows toolchain reachable from a
// Mac, and cross-compiling is not merely unavailable but wrong here, because
// `Package.swift` decides the package graph from the host it is loaded on. The
// only compiler this project can reach for Windows is GitHub Actions
// `windows-latest`. So the parts below that depend on how the Swift importer
// spells a particular Windows declaration are called out in comments as they
// arise; each is a one-line fix once the first red run exists, and none of them
// changes the shape of the code around it.
//
// One structural dependency is *not* a one-line fix and is recorded here so it
// is found rather than rediscovered: `sockaddr_un` lives in `afunix.h`, and
// whether that header is reachable through the `WinSDK` module map is the single
// question this file cannot answer and cannot work around from inside itself.
// If it is not, the fix is a small header-only C target (`CWinShim`) declared in
// `Package.swift` that includes `winsock2.h` **before** `windows.h` — that order
// is not a preference, it is the difference between building and several hundred
// redefinition errors — and then `ws2tcpip.h` and `afunix.h`. `Package.swift` is
// not this file's to edit. `posixSetUNIXAddressLength` below is written so that
// it does not need the type either way.

// MARK: - Handle types

/// An open file, as the CRT numbers it.
///
/// Deliberately the same `Int32` as on POSIX. Win32 opens files as a `HANDLE`,
/// but `posixOpenPrivate(_:)` passes that handle through `_open_osfhandle` on
/// the way out, so callers hold one type on all three platforms and
/// `SingleInstance` needs no `#if` in its body. `windowsHandle(for:)` recovers
/// the `HANDLE` for the two places that genuinely need Win32.
typealias PlatformDescriptor = Int32

let platformInvalidDescriptor: PlatformDescriptor = -1

@inline(__always)
func posixDescriptorIsValid(_ descriptor: PlatformDescriptor) -> Bool {
    descriptor >= 0
}

/// An open socket, as WinSock numbers it.
///
/// **This is unsigned.** `SOCKET` is a `UINT_PTR`, and the failure value is
/// `INVALID_SOCKET`, which is `(SOCKET)(~0)` — the largest representable value,
/// not a negative one.
typealias PlatformSocket = SOCKET

let platformInvalidSocket: PlatformSocket = ~0

/// Whether `posixSocket(_:_:_:)` or `posixAccept(_:_:_:)` succeeded.
///
/// **Use this. Never `>= 0`.**
///
/// `guard descriptor >= 0` is the idiom every POSIX socket call site in this
/// package was written with, and on Windows it is *vacuously true*: an unsigned
/// value is never negative, so a failed `socket()` returning `~0` walks straight
/// through the guard and is then handed to `connect`, `send` and `closesocket`
/// as if it were real. That is a silent wrong answer rather than a compile
/// error — the typealias change above will not flag it, because `~0 >= 0` is
/// perfectly well-typed — which makes it the one defect in this port that a
/// green build actively hides. Every `>= 0` on a socket becomes a call to this.
@inline(__always)
func posixSocketIsValid(_ socket: PlatformSocket) -> Bool {
    socket != platformInvalidSocket
}

// MARK: - The socket library

/// WinSock, started exactly once, the first time anybody asks.
///
/// There is no UNIX counterpart to this and therefore nothing anywhere in this
/// package calls it today. Every WinSock function — including `getaddrinfo`,
/// which the SSRF guard in `WebPageReader` resolves through before it will fetch
/// a URL — fails with `WSANOTINITIALISED` until it has run, and that surfaces as
/// an unexplained `socket()` failure a long way from the cause.
///
/// `WSACleanup` is deliberately never called. The matching teardown belongs at
/// process exit, where it buys nothing, and calling it early would break every
/// socket still open elsewhere in the appliance.
private let winsockStarted: Bool = {
    var data = WSADATA()
    // MAKEWORD(2, 2) — WinSock 2.2, the only version anything has shipped
    // against for twenty-five years. Spelled as the literal because MAKEWORD is
    // a function-like macro and does not survive the Swift importer.
    return WSAStartup(0x0202, &data) == 0
}()

@inline(__always)
@discardableResult
func ensureWinsockStarted() -> Bool {
    winsockStarted
}

// MARK: - Constants that changed type

/// `SOCK_STREAM` as the `Int32` that `socket()` and `addrinfo.ai_socktype` want.
///
/// A plain `#define` in `winsock2.h`, so it arrives as `Int32` already, the same
/// as Darwin and musl and unlike glibc.
let posixSocketStream = SOCK_STREAM

/// `IPPROTO_TCP` as the `Int32` that `addrinfo.ai_protocol` wants.
///
/// Windows collects the protocol numbers in a *typedef'd* enum (`IPPROTO` in
/// `ws2def.h`), which the Swift importer turns into a struct with a `rawValue` —
/// a third spelling, different from both the anonymous glibc enum and the Darwin
/// macro. If the first Windows build disagrees, the alternative is
/// `Int32(IPPROTO_TCP)`; the value is 6 either way.
let posixProtocolTCP = Int32(IPPROTO_TCP.rawValue)

// MARK: - Reading and writing

@inline(__always)
@discardableResult
func posixRead(_ descriptor: PlatformDescriptor, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    // `_read` takes and returns `int`, not `ssize_t`. Clamping rather than
    // truncating: a short read is the caller's normal case and is already
    // handled, whereas a wrapped length would be a buffer overrun.
    Int(_read(descriptor, buffer, UInt32(clamping: count)))
}

@inline(__always)
@discardableResult
func posixWrite(_ descriptor: PlatformDescriptor, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    Int(_write(descriptor, buffer, UInt32(clamping: count)))
}

/// `recv` from a socket.
///
/// Not `_read`. A WinSock socket is not in the CRT descriptor table at all, so
/// `_read` on one fails with `EBADF` — which is why the socket and file
/// spellings are separate names on every platform rather than only on this one.
@inline(__always)
@discardableResult
func posixReadFromSocket(_ socket: PlatformSocket, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    Int(recv(socket, buffer?.assumingMemoryBound(to: CChar.self), Int32(clamping: count), 0))
}

/// `send` to a socket.
///
/// No `MSG_NOSIGNAL`, because there is no SIGPIPE to suppress: Windows reports a
/// write to a departed peer as `WSAECONNRESET` from this call, which is exactly
/// the error the caller is already handling. Same guarantee as the other two
/// platforms, reached by not needing anything.
@inline(__always)
@discardableResult
func posixWriteToSocket(_ socket: PlatformSocket, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    Int(send(socket, buffer?.assumingMemoryBound(to: CChar.self), Int32(clamping: count), 0))
}

// MARK: - Descriptors

@inline(__always)
@discardableResult
func posixClose(_ descriptor: PlatformDescriptor) -> Int32 {
    // Closes the underlying `HANDLE` too, for descriptors that came from
    // `_open_osfhandle` — which is all of ours. Calling `CloseHandle` as well
    // would be a double close.
    _close(descriptor)
}

@inline(__always)
@discardableResult
func posixCloseSocket(_ socket: PlatformSocket) -> Int32 {
    closesocket(socket)
}

@inline(__always)
func posixDuplicate(_ descriptor: PlatformDescriptor) -> PlatformDescriptor {
    _dup(descriptor)
}

/// **Unavailable on Windows.**
///
/// `SignalLineSocket.writeSynchronously` duplicates its socket under the lock so
/// the read pump cannot close the original while a blocking write is in flight;
/// the comment there records that the fd number was otherwise recycled and the
/// write injected JSON-RPC bytes into an unrelated file. Windows offers no honest
/// equivalent: `WSADuplicateSocketW` builds a protocol-info blob intended for
/// handing a socket to *another process* and is far too heavy to run per write,
/// and `DuplicateHandle` on a `SOCKET` is explicitly not supported.
///
/// Faking it — returning the same socket unchanged — would compile, and would
/// reintroduce exactly the bug the duplicate was added to fix, on the one
/// platform nobody here can test. So the call does not exist, and the fix is
/// named instead of guessed.
@available(
    *,
    unavailable,
    message: """
        Windows has no dup(2) for sockets. Do not reuse the socket. Instead keep \
        a `writersInFlight` count and a `closeDeferred` flag beside the existing \
        lock, and have the close path defer the real `closesocket` until the last \
        writer has left — that is the same guarantee the duplicate was providing.
        """
)
func posixDuplicateSocket(_ socket: PlatformSocket) -> PlatformSocket {
    fatalError("posixDuplicateSocket is unavailable on Windows")
}

@inline(__always)
@discardableResult
func posixUnlink(_ path: String) -> Int32 {
    // `DeleteFileW` rather than `_unlink`, because `_unlink` takes a narrow
    // string in the active code page and would fail on any path containing a
    // character it cannot represent. Reported in `unlink(2)`'s shape — 0 for
    // success, -1 for failure — so the call sites do not care which it was.
    let removed = path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
    return removed == false ? -1 : 0
}

/// **Unavailable on Windows.**
///
/// NTFS has no mode bits. ucrt's `_chmod` accepts one and maps it onto the
/// read-only *attribute*, which cannot deny read access to anybody and has no
/// notion of owner versus everyone else — so it would return 0, report success,
/// and leave a credential world-readable.
///
/// Every caller of this function is asking for `0600` or `0700` and means "only
/// the owner". On Windows that is an ACL, not a mode, and it is
/// `OwnerOnlyFileSecurity`'s job.
@available(
    *,
    unavailable,
    message: """
        NTFS has no mode bits and _chmod only toggles the read-only attribute, so \
        this cannot deny access to anyone. Use OwnerOnlyFileSecurity.write / \
        .protectFile / .prepareDirectory, which apply a protected owner-only DACL.
        """
)
func posixChangeMode(_ path: String, _ mode: UInt16) -> Int32 {
    fatalError("posixChangeMode is unavailable on Windows")
}

/// Opens (creating if needed) a file for the lock and its kin.
///
/// Three deliberate choices, all of which the POSIX arm gets for free from
/// `0600`:
///
/// * `GENERIC_WRITE` alone, not `GENERIC_READ | GENERIC_WRITE`. Write access is
///   what `LockFileEx` requires for an exclusive lock, and `GENERIC_READ` is
///   `0x80000000`, which the Swift importer may hand over as a *negative*
///   `Int32` — `DWORD(GENERIC_READ)` would then trap at runtime. Asking for
///   less avoids a whole class of sign-conversion noise.
/// * `FILE_SHARE_READ | FILE_SHARE_WRITE`, not share-mode zero. Share-mode zero
///   would also exclude a second instance, but it would do it *at open time*,
///   and `SingleInstance` would then report "could not open the lock file"
///   instead of "another bridge is already running" — a true statement that
///   tells the owner nothing. Letting the open succeed and the lock fail keeps
///   the useful error.
/// * The handle is converted to a CRT descriptor before it leaves, so the return
///   type matches POSIX and `posixClose` works on it unchanged.
///
/// There are no owner-only bits here. The protection comes from the directory:
/// `OwnerOnlyFileSecurity.prepareDirectory` applies an inheritable protected
/// DACL, and a file created inside it inherits that and nothing else.
@inline(__always)
func posixOpenPrivate(_ path: String) -> PlatformDescriptor {
    let handle: UnsafeMutableRawPointer? = path.withCString(encodedAs: UTF16.self) { wide in
        CreateFileW(
            wide,
            DWORD(GENERIC_WRITE),
            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
            nil,
            DWORD(OPEN_ALWAYS),
            DWORD(FILE_ATTRIBUTE_NORMAL),
            nil
        )
    }
    // `INVALID_HANDLE_VALUE` is `(HANDLE)-1`, which is a perfectly ordinary
    // non-nil pointer, so the nil check alone is not enough.
    guard let handle, Int(bitPattern: handle) != -1 else {
        return platformInvalidDescriptor
    }
    let descriptor = _open_osfhandle(Int(bitPattern: handle), 0)
    if descriptor < 0 {
        // Ownership never transferred, so this is ours to release.
        CloseHandle(handle)
        return platformInvalidDescriptor
    }
    return descriptor
}

/// An exclusive whole-file lock that fails immediately rather than queueing.
///
/// `LockFileEx`, not `flock(2)`, which Windows does not have — but it keeps the
/// one property `flock` was chosen for over a POSIX record lock. A record lock
/// is released when *any* descriptor on the file is closed anywhere in the
/// process; `LockFileEx` belongs to the handle, and Windows releases it when the
/// handle closes or the holder exits, *however* it exits. A bridge that is
/// killed, panics or loses power does not leave a lock behind, which is exactly
/// what the POSIX comment argues for.
///
/// `LOCKFILE_FAIL_IMMEDIATELY` is the `LOCK_NB` half: fail fast and say why,
/// rather than queue behind an appliance that may run for weeks.
///
/// The whole 64-bit range is locked, including the region past end-of-file — the
/// lock file is empty, and locking beyond EOF is both legal and the normal way
/// to use this API as a mutex. Reported in `flock(2)`'s shape, 0 or -1.
@inline(__always)
func posixLockExclusiveNonBlocking(_ descriptor: PlatformDescriptor) -> Int32 {
    guard let handle = windowsHandle(for: descriptor) else { return -1 }
    // Synchronous, because `LOCKFILE_FAIL_IMMEDIATELY` on a non-overlapped
    // handle returns before this call does — so a stack `OVERLAPPED` cannot
    // outlive its use. It may not be omitted: `LockFileEx` requires it non-null.
    var overlapped = OVERLAPPED()
    let locked = LockFileEx(
        handle,
        DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY),
        0,
        DWORD.max,
        DWORD.max,
        &overlapped
    )
    return locked == false ? -1 : 0
}

/// The Win32 handle behind a CRT descriptor.
///
/// `_get_osfhandle` reports failure as -1 (not a descriptor) or -2 (a descriptor
/// with no handle, which is what the standard streams look like in a GUI
/// process), and both would otherwise become plausible-looking pointers.
@inline(__always)
private func windowsHandle(for descriptor: PlatformDescriptor) -> UnsafeMutableRawPointer? {
    let raw = _get_osfhandle(descriptor)
    guard raw != -1, raw != -2 else { return nil }
    return UnsafeMutableRawPointer(bitPattern: raw)
}

// MARK: - Sockets

@inline(__always)
func posixSocket(_ domain: Int32, _ type: Int32, _ networkProtocol: Int32) -> PlatformSocket {
    // Started here because almost every WinSock call in the package is
    // downstream of a socket, so one gate covers nearly all of them.
    //
    // `getaddrinfo` is the exception, and it is not covered: both callers —
    // `SignalLineSocket.connectTCP` and `WebPageReader`'s SSRF guard — resolve a
    // name *before* they create any socket, so they reach WinSock first and must
    // call `ensureWinsockStarted()` themselves. Neither of those files is this
    // one's to edit; the requirement is recorded here and in that function's own
    // documentation so it is not discovered as an unexplained resolver failure.
    guard ensureWinsockStarted() else { return platformInvalidSocket }
    return socket(domain, type, networkProtocol)
}

@inline(__always)
func posixConnect(_ socket: PlatformSocket, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    // Windows spells the address length `int`, where POSIX has a `socklen_t`
    // that is unsigned on Darwin and Linux. The conversion is a no-op when
    // `ws2tcpip.h`'s own `socklen_t` is already in scope and a narrowing that
    // provably cannot lose a sockaddr-sized value when it is not.
    connect(socket, address, Int32(length))
}

@inline(__always)
func posixBind(_ socket: PlatformSocket, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    bind(socket, address, Int32(length))
}

@inline(__always)
func posixListen(_ socket: PlatformSocket, _ backlog: Int32) -> Int32 {
    listen(socket, backlog)
}

@inline(__always)
func posixAccept(
    _ socket: PlatformSocket,
    _ address: UnsafeMutablePointer<sockaddr>?,
    _ length: UnsafeMutablePointer<socklen_t>?
) -> PlatformSocket {
    accept(socket, address, length)
}

/// `shutdown` in both directions.
///
/// `SD_BOTH` rather than `SHUT_RDWR`; the value is 2 on all three platforms and
/// only the spelling differs.
@inline(__always)
@discardableResult
func posixShutdownReadAndWrite(_ socket: PlatformSocket) -> Int32 {
    shutdown(socket, SD_BOTH)
}

/// Stamps the BSD length byte into a UNIX-domain address — of which Windows, like
/// Linux, has none.
///
/// Generic rather than typed on `sockaddr_un` deliberately. `sockaddr_un` comes
/// from `afunix.h`, and whether that header is reachable through the `WinSDK`
/// module map is exactly the question this file cannot settle from a Mac (see the
/// note at the top of this arm). Writing the no-op generically means this file
/// compiles either way, and the answer only decides whether the *transport* needs
/// a C shim — it does not hold up the rest of the port.
///
/// Nothing is lost by the no-op: the length is passed to `connect` separately on
/// every platform, and only 4.4BSD ever read it from the struct.
@inline(__always)
func posixSetUNIXAddressLength<Address>(_ address: inout Address) {
}

/// Asks the kernel never to raise SIGPIPE for this socket.
///
/// A genuine no-op, and worth separating from the unavailable declarations
/// elsewhere in this arm: Windows has no signals, so there is no SIGPIPE to
/// suppress, and `send` to a departed peer already returns `WSAECONNRESET` as the
/// ordinary error the caller handles. The promise this function makes on Darwin
/// — "a dead peer cannot kill the process" — holds here without asking for it.
/// Nothing has been skipped or downgraded.
@inline(__always)
func posixSuppressSIGPIPE(on socket: PlatformSocket) {
}

/// Turns on TCP keepalive, so a wedged daemon eventually surfaces as a read
/// error rather than a pump that waits forever.
///
/// The same option, spelled the way WinSock declares `setsockopt`: the value is
/// a `const char *` and the length an `int`, where POSIX takes a `const void *`
/// and a `socklen_t`.
@inline(__always)
func posixEnableKeepAlive(on socket: PlatformSocket) {
    var enabled: Int32 = 1
    withUnsafeBytes(of: &enabled) { raw in
        _ = setsockopt(
            socket,
            SOL_SOCKET,
            SO_KEEPALIVE,
            raw.baseAddress?.assumingMemoryBound(to: CChar.self),
            Int32(raw.count)
        )
    }
}

// MARK: - Processes

/// **Unavailable on Windows.**
///
/// Windows has no signals. ucrt's `signal()` recognises a handful of names —
/// SIGINT, SIGILL, SIGFPE, SIGSEGV, SIGTERM, SIGBREAK, SIGABRT — but they are
/// raised in-process by the CRT itself; there is no way to deliver one to another
/// process, and there is no `SIGKILL` at all.
@available(
    *,
    unavailable,
    message: "Windows has no signals and no way to send one to another process. Use posixTerminateProcess(_:)."
)
func posixKill(_ pid: Int32, _ signalNumber: Int32) -> Int32 {
    fatalError("posixKill is unavailable on Windows")
}

/// Stops a process now, with no chance to clean up.
///
/// `TerminateProcess`, the counterpart to SIGKILL, and the reason a portable name
/// exists at all.
///
/// Worth stating rather than leaving to be rediscovered: Foundation's
/// `Process.terminate()` on Windows *also* maps to `TerminateProcess`. The
/// polite-then-forceful escalation that SIGTERM-then-SIGKILL gives on POSIX
/// therefore does not exist here — both halves are the same abrupt stop. The
/// grace period the callers wait out is still correct, because a process may
/// already be exiting on its own; it simply is not the process being asked
/// nicely first.
@inline(__always)
@discardableResult
func posixTerminateProcess(_ pid: Int32) -> Bool {
    // Refused for the same reason as the POSIX arm, and additionally because
    // `DWORD(pid)` would trap outright on a negative value.
    guard pid > 0 else { return false }
    guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else {
        // Already gone, or not ours to touch. Either way there is nothing to
        // kill, which is the same answer POSIX gives with ESRCH.
        return false
    }
    defer { CloseHandle(handle) }
    return TerminateProcess(handle, 1) != false
}

@inline(__always)
func posixSleep(microseconds: UInt32) {
    // `Sleep` is millisecond-resolution and there is no finer portable wait, so
    // this rounds *up*: a caller asking for a short pause always gets one, where
    // a truncated `Sleep(0)` would merely yield the timeslice and turn the
    // callers' poll loops into spins. Widened to 64 bits first, because
    // `microseconds + 999` would overflow and trap for the top thousand `UInt32`
    // values — a strange way for a sleep to fail.
    Sleep(DWORD((UInt64(microseconds) + 999) / 1000))
}

// MARK: - Errors

/// `strerror(errno)` as a Swift `String`.
///
/// The CRT half only. Use `posixSocketErrorDescription()` after anything that
/// touched a socket.
@inline(__always)
func posixErrorDescription() -> String {
    String(cString: strerror(errno))
}

/// Why the last socket call failed.
///
/// WinSock keeps its errors in `WSAGetLastError()` and does not touch `errno` at
/// all — so reading `errno` after a failed `send` reports whatever unrelated CRT
/// call last set it: a stale reason, stated confidently, in the log line the
/// owner is shown when their messages stop arriving. That is worse than no
/// reason, which is why the socket accessor exists on all three platforms and
/// not only on this one.
@inline(__always)
func posixSocketErrorDescription() -> String {
    windowsErrorMessage(DWORD(bitPattern: WSAGetLastError()))
}

/// Whether the last socket call failed only because it was interrupted, meaning
/// the caller should retry rather than give up.
@inline(__always)
func posixSocketErrorIsInterrupted() -> Bool {
    WSAGetLastError() == WSAEINTR
}

/// A Win32 error code as the sentence Windows would print for it.
private func windowsErrorMessage(_ code: DWORD) -> String {
    var buffer: UnsafeMutablePointer<WCHAR>?
    // `FORMAT_MESSAGE_ALLOCATE_BUFFER` makes the fifth parameter a pointer *to*
    // the output pointer, while the prototype still declares it as the pointer
    // itself — hence the rebind. Windows allocates, we free.
    let length = withUnsafeMutablePointer(to: &buffer) { slot in
        slot.withMemoryRebound(to: WCHAR.self, capacity: 1) { reinterpreted in
            FormatMessageW(
                DWORD(
                    FORMAT_MESSAGE_ALLOCATE_BUFFER
                        | FORMAT_MESSAGE_FROM_SYSTEM
                        | FORMAT_MESSAGE_IGNORE_INSERTS
                ),
                nil,
                code,
                0,
                reinterpreted,
                0,
                nil
            )
        }
    }
    guard length > 0, let message = buffer else {
        return "Windows error \(code)"
    }
    defer { LocalFree(message) }
    var text = String(decodingCString: message, as: UTF16.self)
    // Windows ends these with ".\r\n", which reads badly mid-sentence in a log
    // line that is already going to say where it happened.
    while let last = text.last, last == "\r" || last == "\n" || last == " " || last == "." {
        text.removeLast()
    }
    return text.isEmpty ? "Windows error \(code)" : text
}

#else

#error("""
    SageVoiceCore has no syscall shim for this platform.

    POSIXShim.swift covers Darwin, Glibc, Musl and Windows. Everything in this \
    package that touches a socket, a lock file or a child process goes through \
    it, so a platform that reaches this line has no transports, no \
    single-instance guard and no process supervision — it would not work, it \
    would merely fail to say so.

    This is a deliberate stop, and it replaces an earlier silent one: the file \
    used to end its POSIX section with a bare #endif, so an unrecognised \
    platform got an empty shim and roughly twenty "cannot find 'posixRead' in \
    scope" errors scattered across four unrelated transport files, with nothing \
    naming the actual cause.

    To add a platform, add an arm above with the same symbol names — start from \
    the Windows arm rather than the POSIX one, because it is the arm that had to \
    decide what to do when a POSIX concept has no counterpart, and the answer is \
    an @available(*, unavailable) declaration whose message names the \
    replacement, never a no-op that reports success.
    """)

#endif
