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
// Darwin, Glibc and Musl are the three arms, and they differ only in spelling:
// the same call, under a different module, occasionally with a different integer
// type. A platform that is none of the three does not fall through to an empty
// shim — see the `#error` at the foot of this file.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
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
    /// A colon on every platform this package supports. It stays a named
    /// constant rather than a literal at each call site so that splitting a
    /// `PATH` is one decision in one place.
    static let searchPathSeparator: Character = ":"
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

// MARK: - Handle types

/// An open file, as the kernel numbers it.
///
/// One `int` on every platform this package supports. Named rather than spelled
/// `Int32` at each signature so that a file and a socket read differently at a
/// glance — `SingleInstance` holds one of these, `SignalLineSocket` the other.
typealias PlatformDescriptor = Int32

/// An open socket, as the kernel numbers it.
///
/// The same `int` as a file descriptor, and deliberately a separate name: the
/// two are not interchangeable to a reader even where they are to the compiler.
/// A failed `posixSocket(_:_:_:)` or `posixAccept(_:_:_:)` is the familiar `-1`,
/// so call sites test it with `>= 0` directly.
typealias PlatformSocket = Int32

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
/// and neither one changes the bytes on the wire.
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

@inline(__always)
func posixDuplicate(_ descriptor: PlatformDescriptor) -> PlatformDescriptor {
    dup(descriptor)
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
/// expresses it directly here.
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
/// Here only to keep `setsockopt` itself out of the transport, so the option and
/// its length are spelled once rather than at each call site.
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
/// `SIGKILL`. The portable spelling exists because the *polite* half of the pair —
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

#else

#error("""
    SageVoiceCore has no syscall shim for this platform.

    POSIXShim.swift covers Darwin, Glibc and Musl. Everything in this \
    package that touches a socket, a lock file or a child process goes through \
    it, so a platform that reaches this line has no transports, no \
    single-instance guard and no process supervision — it would not work, it \
    would merely fail to say so.

    This is a deliberate stop, and it replaces an earlier silent one: the file \
    used to end its POSIX section with a bare #endif, so an unrecognised \
    platform got an empty shim and roughly twenty "cannot find 'posixRead' in \
    scope" errors scattered across four unrelated transport files, with nothing \
    naming the actual cause.

    To add a platform, add an arm above with the same symbol names. Where a \
    POSIX concept has no counterpart there, the answer is an @available(*, \
    unavailable) declaration whose message names the replacement — never a \
    no-op that reports success, which is the same silent failure in a new \
    costume.
    """)

#endif
