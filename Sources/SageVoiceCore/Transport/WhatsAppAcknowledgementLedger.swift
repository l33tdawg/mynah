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

    /// Which run of the spool's numbering these sequences belong to.
    ///
    /// `nil` until a bridge tells us, and a bridge that never does leaves every
    /// sequence in one nameless epoch — which is exactly the behaviour that
    /// shipped before this existed, and the right thing to degrade to.
    private(set) var epoch: String?

    /// How many times the spool has been recreated under us. Diagnostics only:
    /// this should be 0 on a healthy install, and a number that climbs is worth
    /// noticing.
    private(set) var rebaselines = 0

    /// Handed to the consumer. Until it is settled, the watermark cannot pass it.
    mutating func deliver(_ sequence: Int, epoch: String? = nil) {
        observe(sequence, epoch: epoch)
        guard sequence > watermark else { return }
        // **The stale `settled` entry has to go, and leaving it walked the
        // watermark over a live message.**
        //
        // Redelivery is ordinary here, not exotic: the bridge replays everything
        // above ITS mark, and its mark is the last watermark we managed to send
        // — which by construction is below anything sitting in `settled`. So a
        // sequence settled early, before the gap under it closed, comes back on
        // the next reconnect and is delivered again.
        //
        // Without this line it is in `outstanding` and in `settled` at once, and
        // when the gap finally closes the contiguous run below strides straight
        // through it. That is the original defect this whole type was written to
        // end, reached by a second route.
        settled.remove(sequence)
        outstanding.insert(sequence)
    }

    /// Finished: answered, refused by the allowlist, or unreadable. Advances the
    /// watermark across whatever contiguous run that completes, and no further.
    mutating func settle(_ sequence: Int, epoch: String? = nil) {
        // **A settle from a spool that no longer exists is dropped, and this is
        // not hypothetical tidiness.** A turn takes up to a minute. If the spool
        // is recreated inside that window, the answer comes back carrying a
        // sequence from the old numbering — and against the new baseline it
        // would be parked in `settled`, then walked over as the new spool's
        // sequences closed the gap beneath it. The watermark would acknowledge a
        // message of the new spool that had not arrived, which is the loss this
        // whole type exists to prevent, reached by a third route.
        //
        // Dropping it costs nothing: the message it refers to is gone with its
        // spool, and nothing can ever ask about it again.
        if let epoch, let current = self.epoch, epoch != current { return }
        observe(sequence, epoch: epoch)
        // **Removed before the guard, and no test can currently tell.** Said
        // plainly because the alternative is a line that reads as a fix.
        //
        // An audit reported that a `settle` below the watermark returned without
        // clearing `outstanding`, leaving a retired sequence named for ever by
        // `blocking` — the diagnostic somebody reads when acknowledgement looks
        // stuck. True of the code as it stood. But the only route into that
        // state was the redelivery bug fixed in `deliver` above: with that
        // closed, the watermark can no longer pass anything that is in
        // `outstanding`, because the contiguous run walks `settled` and `deliver`
        // now takes a sequence out of `settled` when it comes back. Moving this
        // line back below the guard leaves every test in the suite green.
        //
        // Kept anyway, and not as superstition: "a settled sequence is not
        // outstanding" is unconditionally true, and stating it here does not
        // depend on a second function continuing to behave. The fix that makes
        // this unreachable lives ten lines away and could be undone by somebody
        // who has not read this paragraph.
        outstanding.remove(sequence)
        guard sequence > watermark else { return }   // already covered; idempotent
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
    private mutating func observe(_ sequence: Int, epoch: String?) {
        if let epoch, epoch != self.epoch {
            // **A different spool, stated by the spool rather than guessed.**
            //
            // The numbering restarted, so every sequence held here names a
            // message that no longer exists — and the watermark, stranded above
            // all of them, can never advance again. What that costs is not one
            // message: nothing is ever acknowledged, the spool never compacts,
            // it fills to its bound and refuses inbound WhatsApp for good.
            // Reachable by following the repair `readAck` prints.
            //
            // Inference was not an option. A sequence below the watermark is
            // ambiguous — the ordinary case is our last acknowledgement failing
            // to land and the bridge legitimately replaying — so re-baselining
            // on that would re-answer messages already dealt with, every time
            // the socket dropped at the wrong moment.
            if self.epoch != nil {
                watermark = 0
                outstanding.removeAll()
                settled.removeAll()
                hasObservedASequence = false
                rebaselines += 1
            }
            self.epoch = epoch
        }
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
