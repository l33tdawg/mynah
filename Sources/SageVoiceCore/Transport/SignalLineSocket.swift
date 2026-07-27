import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A newline-delimited byte stream over a UNIX-domain or TCP socket.
///
/// signal-cli's JSON-RPC daemon speaks one JSON object per line in both directions, so
/// this is all the transport we need. Foundation + BSD sockets only — no Network.framework,
/// no external packages.
final class SignalLineSocket: @unchecked Sendable {
    /// Guard rail against a peer that never sends a newline.
    static let maximumFrameBytes = 32 * 1024 * 1024

    private let descriptor: Int32
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var isShutDown = false
    private var descriptorClosed = false
    private var readPumpStarted = false

    private init(descriptor: Int32, label: String) {
        self.descriptor = descriptor
        self.readQueue = DispatchQueue(label: "sage.signal.socket.read.\(label)")
        self.writeQueue = DispatchQueue(label: "sage.signal.socket.write.\(label)")
    }

    deinit {
        shutdownSocket()
        closeDescriptorOnce()
    }

    // MARK: Connecting

    /// Connects off the cooperative thread pool. Blocking `connect(2)` against a loopback
    /// or UNIX endpoint either succeeds or fails promptly.
    static func connect(to endpoint: SignalEndpoint) async throws -> SignalLineSocket {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try connectSynchronously(to: endpoint))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func connectSynchronously(to endpoint: SignalEndpoint) throws -> SignalLineSocket {
        switch endpoint {
        case .unixSocket(let path):
            return try connectUnix(path: path)
        case .tcp(let host, let port):
            return try connectTCP(host: host, port: port)
        }
    }

    private static func connectUnix(path: String) throws -> SignalLineSocket {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw SignalTransportError.socketPathTooLong(path)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
                for (offset, byte) in pathBytes.enumerated() {
                    destination[offset] = byte
                }
                destination[pathBytes.count] = 0
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SignalTransportError.connectFailed("socket(AF_UNIX): \(errnoDescription())")
        }
        configure(descriptor: descriptor)

        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let detail = errnoDescription()
            Darwin.close(descriptor)
            throw SignalTransportError.connectFailed("connect(\(path)): \(detail)")
        }
        return SignalLineSocket(descriptor: descriptor, label: "unix")
    }

    private static func connectTCP(host: String, port: Int) throws -> SignalLineSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &results)
        guard status == 0, let head = results else {
            let detail = String(cString: gai_strerror(status))
            throw SignalTransportError.connectFailed("getaddrinfo(\(host):\(port)): \(detail)")
        }
        defer { freeaddrinfo(results) }

        var lastError = "no addresses returned"
        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let info = candidate {
            let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if descriptor >= 0 {
                configure(descriptor: descriptor)
                if Darwin.connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return SignalLineSocket(descriptor: descriptor, label: "tcp")
                }
                lastError = errnoDescription()
                Darwin.close(descriptor)
            } else {
                lastError = errnoDescription()
            }
            candidate = info.pointee.ai_next
        }
        throw SignalTransportError.connectFailed("connect(\(host):\(port)): \(lastError)")
    }

    private static func configure(descriptor: Int32) {
        var enabled: Int32 = 1
        // Never let a dead peer kill the process with SIGPIPE.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        // Keepalive so a wedged daemon eventually surfaces as a read error.
        setsockopt(descriptor, SOL_SOCKET, SO_KEEPALIVE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }

    // MARK: Reading

    /// One element per received line, excluding the newline. The stream finishes on EOF and
    /// throws on a socket error, which is the caller's cue to reconnect.
    func lines() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            let alreadyStarted = readPumpStarted
            readPumpStarted = true
            lock.unlock()

            guard !alreadyStarted else {
                continuation.finish(throwing: SignalTransportError.notConnected)
                return
            }

            readQueue.async { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                self.pump(into: continuation)
                self.closeDescriptorOnce()
            }
        }
    }

    private func pump(into continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = chunk.withUnsafeMutableBytes { buffer -> Int in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }

            if count > 0 {
                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending = Data(pending[pending.index(after: newline)...])
                    if !line.isEmpty {
                        continuation.yield(line)
                    }
                }
                if pending.count > Self.maximumFrameBytes {
                    continuation.finish(throwing: SignalTransportError.oversizedFrame(Self.maximumFrameBytes))
                    return
                }
                continue
            }

            if count == 0 {
                continuation.finish()
                return
            }

            if errno == EINTR {
                continue
            }
            if isClosedByUs {
                continuation.finish()
                return
            }
            continuation.finish(throwing: SignalTransportError.socketReadFailed(Self.errnoDescription()))
            return
        }
    }

    // MARK: Writing

    /// Appends a newline and writes the whole frame, retrying short writes.
    func writeLine(_ payload: Data) async throws {
        var frame = payload
        frame.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SignalTransportError.notConnected)
                    return
                }
                do {
                    try self.writeSynchronously(frame)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeSynchronously(_ frame: Data) throws {
        guard !isClosedByUs else {
            throw SignalTransportError.notConnected
        }
        var offset = 0
        try frame.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR {
                    continue
                }
                throw SignalTransportError.socketWriteFailed(Self.errnoDescription())
            }
        }
    }

    // MARK: Teardown

    var isClosedByUs: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShutDown
    }

    /// Half-closes the socket so a blocked `read(2)` returns. The descriptor itself is
    /// released by the read pump (or `deinit`) so it can never be recycled underneath a
    /// pending read.
    func close() {
        shutdownSocket()
        lock.lock()
        let pumpRunning = readPumpStarted
        lock.unlock()
        if !pumpRunning {
            closeDescriptorOnce()
        }
    }

    private func shutdownSocket() {
        lock.lock()
        let alreadyDown = isShutDown
        isShutDown = true
        lock.unlock()
        guard !alreadyDown else {
            return
        }
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    private func closeDescriptorOnce() {
        lock.lock()
        let alreadyClosed = descriptorClosed
        descriptorClosed = true
        lock.unlock()
        guard !alreadyClosed else {
            return
        }
        Darwin.close(descriptor)
    }
}
