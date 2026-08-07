import Foundation

/// Joins messages the owner sent as one thought into one turn.
///
/// The daemon reads Signal with a bare `for await` and answers each message in
/// order, which is correct for two separate questions and wrong for the way
/// people actually type:
///
///     "look up xyz and make me a list"
///     "oh and add abc to it as well"
///
/// Answered separately, the first turn spends up to five minutes building a list
/// of xyz, and the second arrives to a finished list and either rebuilds it or
/// starts a second one. Answered together it is one list, first time. The owner
/// has not changed their mind — they finished their sentence late, which is what
/// a chat thread is for.
///
/// ## Why a quiet window rather than something cleverer
///
/// The alternative is to start immediately and cancel when a follow-up lands.
/// That was rejected: a cancelled turn has already paid for a model call worth
/// tens of seconds, and on Ollama it leaves the prompt cache holding a prefix
/// nothing will reuse. Waiting a couple of seconds before starting costs the
/// same couple of seconds on every turn and never throws work away.
///
/// The window is small against the thing it protects. A turn runs 30–300 s; two
/// seconds is under 1% of the bad case and is invisible next to the model.
public struct MessageCoalescer: Sendable {

    /// How long to wait for the rest of a thought.
    ///
    /// 2.5 s is a typing pause, not a thinking pause. Long enough for "oh and
    /// also…" — which arrives within a second or two of the first message
    /// because it was already half-typed — and short enough that a single
    /// message does not feel like it was ignored. Deliberately not tuned upward:
    /// past about three seconds this stops feeling like the appliance is
    /// listening and starts feeling like it is slow.
    public static let defaultQuietWindow: Duration = .milliseconds(2_500)

    /// Most messages one turn will absorb.
    ///
    /// A guard against a pathological burst becoming one enormous prompt, not a
    /// number anyone is expected to reach. Beyond this the extra messages are
    /// handled as their own turn, which is the old behaviour and is fine.
    public static let maximumMerged = 5

    /// Joins transcripts into one turn's text.
    ///
    /// Newline-separated rather than concatenated with ". " so the model can see
    /// two utterances rather than one run-on sentence — "make me a list. oh and
    /// add abc" parses worse than the same thing on two lines, and the second
    /// line being an afterthought is information, not noise.
    ///
    /// Order is arrival order and is never sorted. A later message qualifies an
    /// earlier one ("actually make it Bangkok"), so reordering them inverts the
    /// correction.
    public static func merge(_ transcripts: [String]) -> String {
        transcripts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Whether `next` belongs to the same turn as the batch so far.
    ///
    /// Same thread only. Two different people writing at the same moment are two
    /// conversations, and merging them would put one owner's words into the
    /// other's turn — the same isolation the per-thread history already keeps.
    public static func belongsTogether(
        batch: [ChannelMessage],
        next: ChannelMessage
    ) -> Bool {
        guard batch.count < maximumMerged else { return false }
        guard let first = batch.first else { return true }
        // `ChannelRecipient` carries its channel, so this is a same-thread test
        // and a same-channel one at once. Comparing addresses alone would let a
        // WhatsApp JID and a Signal group id that happened to match merge two
        // strangers' messages into one turn.
        return first.recipient == next.recipient
    }
}

/// Holds arriving messages so the answering loop can take them in batches.
///
/// Exists because `for await` cannot look ahead: to know whether a second
/// message is coming, something has to already be reading. The reader task fills
/// this; the answering loop drains it.
///
/// The separation has a second benefit worth naming. Before it, a message sent
/// while a turn was running stayed unread in the channel's stream for the whole
/// turn — survivable at 30 seconds, not at the 300-second ceiling the deadline
/// now allows.
actor MessageInbox {
    private var pending: [ChannelMessage] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var closed = false

    func append(_ message: ChannelMessage) {
        pending.append(message)
        wake()
    }

    func close() {
        closed = true
        wake()
    }

    var isClosed: Bool { closed && pending.isEmpty }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }

    /// Suspends until something arrives or the stream ends.
    func waitForArrival() async {
        guard pending.isEmpty, !closed else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// The next turn's messages: everything already queued for one thread, plus
    /// anything that arrives during a quiet window.
    ///
    /// The window restarts each time something new lands, so "look up xyz", "oh
    /// and abc", "and def" become one turn rather than tailing off into three.
    /// It stops at `MessageCoalescer.maximumMerged`, and messages for other
    /// threads are left queued rather than dropped.
    func takeBatch(quietWindow: Duration) async -> [ChannelMessage] {
        guard !pending.isEmpty else { return [] }

        var batch: [ChannelMessage] = []
        var deferred: [ChannelMessage] = []
        for message in pending {
            if MessageCoalescer.belongsTogether(batch: batch, next: message) {
                batch.append(message)
            } else {
                deferred.append(message)
            }
        }
        pending = deferred

        while batch.count < MessageCoalescer.maximumMerged {
            let sizeBeforeWaiting = batch.count
            try? await Task.sleep(for: quietWindow)
            guard !pending.isEmpty else { break }

            var stillDeferred: [ChannelMessage] = []
            for message in pending {
                if MessageCoalescer.belongsTogether(batch: batch, next: message) {
                    batch.append(message)
                } else {
                    stillDeferred.append(message)
                }
            }
            pending = stillDeferred
            // Only *this batch* growing earns another window.
            //
            // The condition used to count everything queued, so a second thread
            // typing steadily kept restarting the window for the first one:
            // measured at 1.86 s for a one-message batch that should have left
            // after 0.1 s. The owner's turn was being delayed by someone else's
            // typing — and on Note-to-Self, by their own other conversation.
            if batch.count == sizeBeforeWaiting { break }
        }
        return batch
    }
}
