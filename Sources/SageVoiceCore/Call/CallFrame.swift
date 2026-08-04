import Foundation

/// One message between the call endpoint and the appliance.
///
/// The mirror of `internal/callaudio/frame.go`. Two implementations of one wire
/// format is a thing that drifts, so both are deliberately tiny and the meanings
/// live here, next to the side that has to act on them.
public enum CallFrame: Sendable, Equatable {

    /// The caller, having finished a sentence. A WAV at 16 kHz, ready for
    /// recognition without conversion.
    case utterance(Data)

    /// Part of the answer: 48 kHz mono signed 16-bit samples, little-endian and
    /// headerless — the rate Opus wants, so the endpoint encodes without
    /// touching it.
    ///
    /// Sent in pieces. The first sentence should be playing while the rest is
    /// still being synthesised; that is most of the difference between a call
    /// that feels responsive and one that does not.
    case replyAudio(Data)

    /// The caller started talking while the appliance was. Everything the turn
    /// is doing stops — the model included, or the rest of the abandoned answer
    /// arrives seconds later and is spoken over the new question.
    case interrupted

    /// That was the whole answer.
    case replyEnd

    /// Nothing to say, and why.
    case turnFailed(String)

    /// Hang up.
    ///
    /// Has to be said rather than signalled by going away: the endpoint redials
    /// a closed socket on purpose, so that a call survives the appliance being
    /// restarted, which means closing it no longer means anything.
    case endCall

    var kind: UInt8 {
        switch self {
        case .utterance: return 1
        case .replyAudio: return 2
        case .interrupted: return 3
        case .replyEnd: return 4
        case .turnFailed: return 5
        case .endCall: return 6
        }
    }

    var payload: Data {
        switch self {
        case .utterance(let data), .replyAudio(let data):
            return data
        case .interrupted, .replyEnd, .endCall:
            return Data()
        case .turnFailed(let reason):
            return Data(reason.utf8)
        }
    }

    /// Thirty seconds of 48 kHz mono is under 3 MB. The limit exists so a
    /// confused peer cannot ask this side to allocate without bound.
    static let maximumPayload = 8 << 20

    public var encoded: Data {
        let body = payload
        var frame = Data(capacity: 5 + body.count)
        frame.append(kind)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    public static func decode(kind: UInt8, payload: Data) -> CallFrame? {
        switch kind {
        case 1: return .utterance(payload)
        case 2: return .replyAudio(payload)
        case 3: return .interrupted
        case 4: return .replyEnd
        case 5: return .turnFailed(String(decoding: payload, as: UTF8.self))
        case 6: return .endCall
        default: return nil
        }
    }
}

/// Reads frames off a file descriptor.
///
/// Blocking reads on a dedicated thread rather than async I/O. The descriptor is
/// a local socket carrying one call, the reader has nothing else to do, and a
/// blocking read is the version of this with no states to get wrong.
public struct CallFrameReader {
    private let descriptor: Int32

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public enum Failure: Error, Equatable {
        /// The far side closed cleanly, between frames.
        case closed
        /// It closed mid-frame — a crash, not a hang-up. Distinguished because
        /// treating them alike files a crash as a normal ending.
        case truncated
        case oversized(Int)
    }

    public func next() throws -> CallFrame {
        let header = try read(exactly: 5, allowCleanClose: true)
        let length = header[1...4].withUnsafeBytes {
            Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        guard length <= CallFrame.maximumPayload else {
            throw Failure.oversized(length)
        }
        let payload = length == 0 ? Data() : try read(exactly: length, allowCleanClose: false)
        guard let frame = CallFrame.decode(kind: header[0], payload: payload) else {
            // An unknown kind is skipped rather than fatal: a newer endpoint
            // against an older appliance should lose a feature, not the call.
            return try next()
        }
        return frame
    }

    private func read(exactly count: Int, allowCleanClose: Bool) throws -> Data {
        var buffer = Data(count: count)
        var filled = 0
        while filled < count {
            let got: Int = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress!.advanced(by: filled), count - filled)
            }
            if got == 0 {
                throw (filled == 0 && allowCleanClose) ? Failure.closed : Failure.truncated
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw Failure.truncated
            }
            filled += got
        }
        return buffer
    }
}

/// One call's write end, and the authority on whether it is still that call.
///
/// ## Why a descriptor number is not an identity
///
/// A turn runs in its own task and holds whatever it needs to speak. When the
/// caller hangs up mid-answer that task is cancelled, but cancellation in Swift
/// is cooperative: the task keeps running until it next checks, and a turn
/// waiting on the model or the synthesiser can be seconds from its next check.
/// Meanwhile the call ends and the descriptor is closed.
///
/// POSIX then hands the *lowest available* number to the next `accept()` —
/// which is the number just freed. Verified on this Mac with a C probe:
/// listening socket on fd 3, first call accepted on fd 5, closed, second call
/// accepted on fd 5 again. So the abandoned turn wakes up holding a live
/// descriptor that now belongs to somebody else's call, and speaks the previous
/// caller's answer into the new caller's ear.
///
/// Nothing about that is visible in a log: the write succeeds, the endpoint
/// plays what it is given, and the transcript of the new call simply contains a
/// sentence nobody asked for.
///
/// So writers no longer hold a number, they hold *this* — an object that is
/// retired exactly once, when its call ends. A retired connection refuses to
/// write no matter what the descriptor number is now doing.
///
/// The lock is held across the whole write, which buys two more things:
///
///  - **Frames stay whole.** Two tasks writing at once could interleave partial
///    writes and hand the endpoint a spliced frame. Nothing serialised them
///    before.
///  - **`retire()` waits for a write in flight,** so `close()` afterwards
///    cannot free the descriptor out from under one. That is the ordering the
///    whole fix rests on, and it is why `retire()` is called before the close
///    rather than beside it.
public final class CallConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var usable = true

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Ends this connection's writing life. Idempotent.
    ///
    /// Does not close the descriptor — whoever opened it closes it, and doing
    /// both here would mean two owners of one number, which is the class of bug
    /// this type exists to end.
    public func retire() {
        lock.lock()
        usable = false
        lock.unlock()
    }

    public var isUsable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usable
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard usable else { throw CallFrameWriter.Failure.callEnded }

        var sent = 0
        while sent < data.count {
            let wrote: Int = data.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if wrote <= 0 {
                if errno == EINTR { continue }
                // A frame that stopped part-way leaves the reader waiting on a
                // length it will never be given, so every later frame lands
                // inside the corpse of this one. There is no recovering the
                // stream: the connection is finished, and saying so here stops
                // the next `try?` writing more into the wreck.
                usable = false
                throw CallFrameReader.Failure.truncated
            }
            sent += wrote
        }
    }
}

/// Writes frames to one call.
public struct CallFrameWriter {
    private let connection: CallConnection

    public enum Failure: Error, Equatable {
        /// The call this writer belongs to is over. Raised instead of writing,
        /// because the descriptor may well belong to the *next* call by now.
        case callEnded
    }

    public init(_ connection: CallConnection) {
        self.connection = connection
    }

    /// For a descriptor whose life is managed elsewhere — the caller side of a
    /// test, and nothing in the appliance.
    public init(descriptor: Int32) {
        self.init(CallConnection(descriptor: descriptor))
    }

    public func send(_ frame: CallFrame) throws {
        try connection.write(frame.encoded)
    }
}
