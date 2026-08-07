import Foundation

/// Turns "this one message is finished" into the watermark the bridge speaks.
///
/// **Why this is a type and not four lines inside `WhatsAppClient`.** It was
/// four lines inside `WhatsAppClient`, and they were wrong in a way no test
/// could see, because reaching them needed a live socket. An audit found it by
/// running the bridge; the fifteen tests over the transport all passed.
///
/// The mismatch it exists to absorb: the bridge understands exactly one
/// message, `{"ack":N}`, meaning *everything up to and including N is dealt
/// with*. That is right for the spool — compaction becomes a truncation. But
/// messages do not finish in the order they arrive. A stranger's message is
/// refused in microseconds; the owner's takes a minute of thinking. So the
/// moment the transport said "2 is done" by sending `{"ack":2}`, it also said
/// "1 is done", and the owner's in-flight message was dropped from the spool
/// and lost on the next crash — by the code written to stop precisely that.
///
/// So a sequence is only *expressible* as a watermark once every sequence below
/// it is also finished. Anything settled early waits here until the gap under
/// it closes.
struct WhatsAppAcknowledgementLedger: Equatable {

    /// What to send. Never moves past something still outstanding.
    private(set) var watermark = 0

    /// Handed to the consumer, not yet finished. These hold the watermark down.
    private var outstanding: Set<Int> = []

    /// Finished, but with something unfinished below it, so not yet sayable.
    /// Bounded by the size of the gap, which the spool bounds in turn.
    private var settled: Set<Int> = []

    private var hasObservedASequence = false

    /// Handed to the consumer. Until it is settled, the watermark cannot pass it.
    mutating func deliver(_ sequence: Int) {
        observe(sequence)
        guard sequence > watermark else { return }
        outstanding.insert(sequence)
    }

    /// Finished: answered, refused by the allowlist, or unreadable. Advances the
    /// watermark across whatever contiguous run that completes, and no further.
    mutating func settle(_ sequence: Int) {
        observe(sequence)
        guard sequence > watermark else { return }   // already covered; idempotent
        outstanding.remove(sequence)
        settled.insert(sequence)

        while settled.remove(watermark + 1) != nil {
            watermark += 1
        }
    }

    /// Where the watermark starts, which is not zero.
    ///
    /// After a Mynah restart this ledger is empty but the bridge's spool is not:
    /// it replays from *its* mark, so the first sequence ever seen here may be
    /// 4,312. Counting contiguity up from 0 would leave the watermark stuck
    /// below messages nobody will ever send again — the spool would grow to its
    /// limit and inbound WhatsApp would stop for good.
    ///
    /// Anything below the first sequence seen was retired by the bridge before
    /// we connected; that is the only reason it is replaying from there. So this
    /// states a fact rather than assuming one.
    private mutating func observe(_ sequence: Int) {
        guard !hasObservedASequence else { return }
        hasObservedASequence = true
        watermark = max(watermark, sequence - 1)
    }

    /// Diagnostics. `blocking` is the message the watermark is waiting on, which
    /// is the only useful thing to print when acknowledgement appears stuck.
    var blocking: Int? { outstanding.min() }
    var outstandingCount: Int { outstanding.count }
    var settledAheadCount: Int { settled.count }
}
