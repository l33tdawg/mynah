import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if !canImport(Darwin)
import Dispatch
#endif

// MARK: - Why this file exists

/// A response body read **as it arrives**, on every platform this ships to.
///
/// ## The hole it fills
///
/// `URLSession.bytes(for:)` is Darwin-only. It does not exist on
/// swift-corelibs-foundation, so the two places that hold a connection open and
/// react to it as it dribbles in — the SAGE wake bus and Ollama's model pull —
/// have nothing to call off a Mac. The tempting substitute, `data(for:)`, is
/// not a substitute at all: it *completes* the request and hands back the whole
/// body. For a pull that means a progress bar that sits at zero for four
/// minutes and then jumps to done, and for the wake bus — a stream the node
/// deliberately never closes — it means a call that returns, at the earliest,
/// when the process is shutting down. Both features would compile, link, and be
/// silently inert. That is the same shape of failure as the `.lines` defect
/// recorded in `MessageWakeLineSplitter`, and it is worth naming twice.
///
/// ## What it does
///
/// On Darwin it *is* `URLSession.bytes(for:)`, wrapped in a struct that forwards
/// every call. `lines` hands back Foundation's own `AsyncLineSequence` over
/// Foundation's own `AsyncBytes`. Nothing about the shipped Mac build changes:
/// same session, same task, same iterator, same errors, same cancellation.
///
/// Off Darwin it is a `URLSessionDataDelegate` — `didReceive data:` — bridged
/// into an `AsyncThrowingStream` of chunks and flattened to bytes. Delegate
/// delivery is corelibs' one incremental path; the completion-handler and
/// `async` conveniences all accumulate first.
///
/// ## Three things the off-Darwin path has to get right
///
/// 1. **It must not invent a session.** The caller's session carries the
///    configuration that matters — `protocolClasses` (the whole test suite
///    stubs the wake stream through a `URLProtocol`), cookie policy, timeouts.
///    So the configuration is copied from the session it was handed, and only
///    the timeout fields are touched, for the reason in (2).
/// 2. **Idleness is enforced here, not delegated.** The wake bus asks for
///    "thirty seconds of silence against a fifteen-second heartbeat", and on
///    Darwin `timeoutIntervalForRequest` means exactly that: an *idle* timer,
///    reset by every byte. corelibs hands the number to libcurl, and this code
///    should not be betting the feature on which curl option it lands in — a
///    total-transfer reading of the same number would tear down a healthy wake
///    stream every thirty seconds, forever, and look like a flaky node. So the
///    copied configuration is given an effectively unbounded request timeout
///    and a watchdog here re-arms on every chunk. Same rule, same numbers,
///    enforced where it can be reasoned about.
/// 3. **Redirects are refused.** `LoopbackSecurity.makeStreamingSession`
///    installs a redirect blocker on the session it builds; a session built here
///    would not inherit it, and both callers dial loopback. So this delegate
///    refuses redirection itself, the same way and for the same reason: the 3xx
///    is surfaced to the caller rather than followed off the machine.
public struct PortableByteStream: AsyncSequence, @unchecked Sendable {

    public typealias Element = UInt8

    #if canImport(Darwin)

    // MARK: Darwin — Foundation's own, untouched

    private let base: URLSession.AsyncBytes

    private init(base: URLSession.AsyncBytes) {
        self.base = base
    }

    /// Sends `request` on `session` and returns the response head plus a body
    /// that arrives incrementally.
    public static func open(
        _ request: URLRequest,
        on session: URLSession
    ) async throws -> (PortableByteStream, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        return (PortableByteStream(base: bytes), response)
    }

    /// Foundation's line sequence over Foundation's bytes.
    ///
    /// Deliberately the real thing rather than a reimplementation: a caller that
    /// is happy with `.lines` today keeps its exact behaviour on the Mac,
    /// including the blank-line elision that makes it wrong for SSE. Anything
    /// that cares about blank lines must read bytes and split them itself — see
    /// `MessageWakeLineSplitter`, which is what the wake bus does on every
    /// platform.
    public var lines: AsyncLineSequence<URLSession.AsyncBytes> { base.lines }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var base: URLSession.AsyncBytes.AsyncIterator

        public mutating func next() async throws -> UInt8? {
            try await base.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }

    #else

    // MARK: Elsewhere — a delegate, bridged

    private let chunks: AsyncThrowingStream<[UInt8], Error>

    fileprivate init(chunks: AsyncThrowingStream<[UInt8], Error>) {
        self.chunks = chunks
    }

    /// Sends `request` on a session configured like `session` and returns the
    /// response head plus a body that arrives incrementally.
    ///
    /// The await returns as soon as the response *head* is in, which is what
    /// makes a status check possible on a body that will never end.
    public static func open(
        _ request: URLRequest,
        on session: URLSession
    ) async throws -> (PortableByteStream, URLResponse) {
        let reader = PortableStreamReader(request: request, modelledOn: session)
        let (chunks, response) = try await reader.start()
        return (PortableByteStream(chunks: chunks), response)
    }

    /// Lines, for callers that were using `AsyncBytes.lines`.
    ///
    /// Splits on `\n` and `\r\n`, and yields a trailing unterminated line at end
    /// of stream. It does *not* drop blank lines the way Foundation's
    /// `AsyncLineSequence` does — a superset, and the one caller filters empties
    /// itself, so the two agree on every input either sees. A caller that needs
    /// blank lines to be load-bearing should still be reading bytes.
    public var lines: PortableLineSequence { PortableLineSequence(bytes: self) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var chunks: AsyncThrowingStream<[UInt8], Error>.AsyncIterator
        fileprivate var current: [UInt8] = []
        fileprivate var offset = 0

        public mutating func next() async throws -> UInt8? {
            // `while`, not `if`: a zero-length chunk is legal and must not be
            // mistaken for the end of the body.
            while offset == current.count {
                guard let chunk = try await chunks.next() else { return nil }
                current = chunk
                offset = 0
            }
            defer { offset += 1 }
            return current[offset]
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator())
    }

    #endif
}

#if !canImport(Darwin)

// MARK: - Lines, off Darwin

/// `AsyncLineSequence`'s job, for platforms that have no `AsyncBytes` to hang it
/// off. A lone `\r` does not end a line: the two producers this reads are an
/// SSE stream and Ollama's newline-delimited JSON, and inventing a terminator
/// neither of them sends is how a JSON object gets cut in half.
public struct PortableLineSequence: AsyncSequence {

    public typealias Element = String

    private let bytes: PortableByteStream

    fileprivate init(bytes: PortableByteStream) {
        self.bytes = bytes
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var bytes: PortableByteStream.AsyncIterator
        fileprivate var buffer: [UInt8] = []

        public mutating func next() async throws -> String? {
            while let byte = try await bytes.next() {
                guard byte == 0x0A else {
                    buffer.append(byte)
                    continue
                }
                if buffer.last == 0x0D { buffer.removeLast() }
                return take()
            }
            // End of stream with bytes still buffered: the producer stopped
            // mid-line. Yield it rather than dropping it — an NDJSON body whose
            // last line has no trailing newline is otherwise silently truncated.
            return buffer.isEmpty ? nil : take()
        }

        private mutating func take() -> String {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            return line
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes.makeAsyncIterator())
    }
}

// MARK: - The delegate behind it

/// One request, read through `URLSessionDataDelegate` and published as chunks.
///
/// Owns the session it creates and invalidates it exactly once, from `close()`
/// — a session holds its delegate strongly until it is invalidated, so a reader
/// that forgets leaks itself and its socket. Every path out (a clean end, an
/// error, an idle timeout, a consumer that walked away) funnels through the
/// same `close()`.
private final class PortableStreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// A year. Stands in for "no limit" where a real infinity would be handed to
    /// libcurl as an integer, which is not a conversion worth finding out about
    /// in production.
    private static let unbounded: TimeInterval = 60 * 60 * 24 * 365

    private let request: URLRequest
    private let configuration: URLSessionConfiguration

    /// Silence this long ends the read. `nil` means the caller asked for no
    /// limit on either the request or the configuration.
    private let idleTimeout: TimeInterval?

    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "org.mynah.portable-byte-stream")

    private var head: CheckedContinuation<URLResponse, Error>?
    private var headSettled = false
    private var pendingHeadFailure: Error?
    private var body: AsyncThrowingStream<[UInt8], Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var watchdog: DispatchSourceTimer?
    private var closed = false

    init(request: URLRequest, modelledOn template: URLSession) {
        let source = template.configuration
        // Copied, not rebuilt: `protocolClasses`, cookie policy and the rest are
        // what the caller chose, and the test suite's stubbed wake stream is one
        // of them.
        let configuration = (source.copy() as? URLSessionConfiguration) ?? source

        // Read the caller's intent *before* neutering the field it lives in. The
        // tighter of the two is the one that would have fired on Darwin.
        let asked = [request.timeoutInterval, source.timeoutIntervalForRequest]
            .filter { $0.isFinite && $0 > 0 }
        self.idleTimeout = asked.min()

        // See (2) in the type comment: idleness is this class's job now.
        configuration.timeoutIntervalForRequest = Self.unbounded
        if !configuration.timeoutIntervalForResource.isFinite
            || configuration.timeoutIntervalForResource > Self.unbounded {
            configuration.timeoutIntervalForResource = Self.unbounded
        }
        self.configuration = configuration

        var request = request
        request.timeoutInterval = Self.unbounded
        self.request = request

        super.init()
    }

    /// Starts the request and returns once the response head is in.
    func start() async throws -> (AsyncThrowingStream<[UInt8], Error>, URLResponse) {
        let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        // Through synchronous helpers rather than `lock.lock()` inline: taking
        // an `NSLock` in the body of an `async` function is an error in the
        // Swift 6 language mode, and this class must survive that switch.
        adopt(body: continuation)
        // Fires on finish *and* on a consumer that stops iterating or is
        // cancelled, which is the only signal that the socket is no longer
        // wanted.
        continuation.onTermination = { [weak self] _ in self?.close() }

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        adopt(session: session, task: task)

        do {
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, Error>) in
                    lock.lock()
                    // A cancellation or failure that beat the continuation into
                    // place is parked in `pendingHeadFailure`; without this the
                    // await would hang until the watchdog.
                    if let waiting = pendingHeadFailure {
                        pendingHeadFailure = nil
                        headSettled = true
                        lock.unlock()
                        continuation.resume(throwing: waiting)
                        return
                    }
                    head = continuation
                    lock.unlock()
                    armWatchdog()
                    task.resume()
                }
            } onCancel: {
                self.fail(with: CancellationError())
            }
            return (stream, response)
        } catch {
            finishBody(throwing: error)
            close()
            throw error
        }
    }

    // MARK: Delegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        resetWatchdog()
        settleHead(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        resetWatchdog()
        guard !data.isEmpty else { return }
        lock.lock()
        let body = self.body
        lock.unlock()
        body?.yield([UInt8](data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            settleHead(.failure(error))
            finishBody(throwing: error)
        } else {
            // A body that ended before any head arrived is not a clean end of
            // stream, it is a request that never happened.
            settleHead(.failure(URLError(.badServerResponse)))
            finishBody(throwing: nil)
        }
        close()
    }

    /// Refuses every HTTP redirect, the same way `LoopbackSecurity` does on the
    /// session it builds. `nil` => do not follow; the 3xx reaches the caller.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    // MARK: Plumbing

    private func adopt(body continuation: AsyncThrowingStream<[UInt8], Error>.Continuation) {
        lock.lock()
        body = continuation
        lock.unlock()
    }

    private func adopt(session: URLSession, task: URLSessionDataTask) {
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
    }

    private func settleHead(_ result: Result<URLResponse, Error>) {
        lock.lock()
        if let continuation = head {
            head = nil
            headSettled = true
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if !headSettled, case .failure(let error) = result {
            pendingHeadFailure = error
        }
        lock.unlock()
    }

    private func finishBody(throwing error: Error?) {
        lock.lock()
        let continuation = body
        body = nil
        lock.unlock()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    /// Ends the read now, for a reason that is nobody's fault but is not a
    /// clean end either: a cancellation, or silence past the idle limit.
    private func fail(with error: Error) {
        settleHead(.failure(error))
        finishBody(throwing: error)
        close()
    }

    private func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let watchdog = self.watchdog
        let task = self.task
        let session = self.session
        self.watchdog = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        watchdog?.cancel()
        task?.cancel()
        // Releases the strong reference this session holds on `self`.
        session?.invalidateAndCancel()
    }

    private func armWatchdog() {
        guard let idleTimeout else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.setEventHandler { [weak self] in
            self?.fail(with: URLError(.timedOut))
        }
        timer.schedule(deadline: .now() + idleTimeout, repeating: .never)
        lock.lock()
        let alreadyClosed = closed
        if !alreadyClosed { watchdog = timer }
        lock.unlock()
        // Resumed even when the read is already over, and cancelled after:
        // libdispatch traps on the release of a source that was never resumed,
        // so "arm it and immediately tear it down" is the only safe way to drop
        // one. This is the cancelled-before-the-first-byte race, which is rare
        // and would otherwise crash the process rather than end a stream.
        timer.resume()
        if alreadyClosed { timer.cancel() }
    }

    /// Every byte is a sign of life, so every byte pushes the deadline out.
    private func resetWatchdog() {
        guard let idleTimeout else { return }
        lock.lock()
        let timer = watchdog
        lock.unlock()
        timer?.schedule(deadline: .now() + idleTimeout, repeating: .never)
    }
}

#endif
