import Foundation

/// **The sentence the caller hears when something was queued.**
///
/// The tool result tells the model to say this itself, and usually it will.
/// This is the backstop for when it does not — and the reason there is a
/// backstop at all is that the failure is silent and lands on the owner: they
/// asked for something, heard nothing about it, and a file arrives an hour
/// later with no explanation.
///
/// The same shape `SpokenReply` already uses for the link notice, and for the
/// same reason: a thing the appliance did on the caller's behalf has to be
/// audible in the call, not only visible afterwards.
public enum AfterTheCall {

    static let promise = "I'll take care of that after we hang up."

    /// **What to say instead of a promise nothing will keep.**
    ///
    /// Reached from two places, which is why it lives here rather than in
    /// either of them: `ToolLoop` when a model has promised twice and still not
    /// called the tool, and `CallTurnServer` when the queue itself says nothing
    /// was ever written down on this call.
    ///
    /// It replaces the promise rather than sitting above it. The written
    /// surfaces flag a false claim and keep the original — a correction can lead
    /// and the rest can follow, and the owner reads both. This is spoken down a
    /// phone line, where "I haven't got that written down" followed by "I'll
    /// send it after we hang up" is not a correction, it is a contradiction.
    ///
    /// And it names the next move. A dead end that does not say where the door
    /// is leaves the owner with a thing they asked for, a promise they now know
    /// is worthless, and no idea what to do about it — the Signal thread does
    /// have the tools a call does not, and asking there works in ten seconds.
    static let couldNotQueue = "Actually, hold on — I need to correct that. I haven't got it "
        + "written down, so it won't happen on its own. Message me in the chat once we hang up "
        + "and I'll do it straight away."

    /// **Whether the caller just asked for something to happen after the call.**
    ///
    /// Read off the caller's own sentence, before any model runs, because the
    /// model is exactly what may not get there in time.
    ///
    /// Measured on the owner's call, 8 August 2026 18:11 — the first time this
    /// feature was ever exercised on a real call:
    ///
    ///     18:11:56 heard: ...make a markdown file and then send it back to me
    ///              after this call is done.
    ///     18:11:57 said "On it — let me pull that together." after 3.1s
    ///     18:12:02 the call ended mid-answer; stopping that turn
    ///     18:12:02 cancelled: heard in 1.6s, thought in 6.2s+, spoke in ?
    ///
    /// Nothing was queued. He hung up five seconds after the filler, while the
    /// model was still thinking, so the turn was cancelled before it could emit
    /// `after_the_call` — and the appliance had already said "On it". A promise
    /// followed by permanent silence, which is the failure this whole feature
    /// exists to prevent, reached through the one door it left open.
    ///
    /// **And hanging up there is the normal case, not the exotic one.** People
    /// ring off when they have said the thing they rang to say. A queue that
    /// only fills when the caller waits out the answer is a queue that mostly
    /// does not fill.
    ///
    /// So this is a fail-safe, not a parser. It is allowed to be wrong in the
    /// generous direction: a spurious entry is one item the drain runs through
    /// the ordinary brain and the owner sees the result of, while a missed one
    /// is silence. The model's own `after_the_call` call replaces whatever this
    /// wrote — see `CallActionQueue.enqueue` — so on the calls where the model
    /// does get there, this costs nothing at all.
    ///
    /// Deliberately not a general intent classifier. It matches the shape of
    /// the owner's own ruling — *"you can request to say send me this file
    /// after the call or do xyz"* — which is a time reference to the end of
    /// this call, and nothing else.
    static func asksForSomethingAfterwards(_ heard: String) -> Bool {
        let text = heard.lowercased()
        // "after that" is deliberately absent: it usually refers to a step in
        // what is being discussed rather than to the end of the call.
        let afterwards = [
            "after this call", "after the call", "after our call",
            "after we hang up", "after you hang up", "after we're done",
            "after we are done", "after this is done", "after this",
            "once we hang up", "once we're done", "once we are done",
            "once this call", "when we hang up", "when we're done",
            "when this call is done", "at the end of the call",
            "afterwards", "after the fact"
        ]
        return afterwards.contains { text.contains($0) }
    }

    /// Adds the promise unless the reply already makes it.
    ///
    /// The check is deliberately loose. Over-promising costs a redundant
    /// half-sentence; under-promising is the failure this exists to prevent, so
    /// where the two are in tension this leans towards saying it twice.
    public static func promising(_ reply: String) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alreadyPromises(trimmed) else { return reply }
        guard !trimmed.isEmpty else { return promise }
        let needsStop = !(trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?"))
        return trimmed + (needsStop ? ". " : " ") + promise
    }

    /// Whether the reply commits *this appliance* to doing something once the
    /// call is over.
    ///
    /// **The stricter sibling of `alreadyPromises`, and the strictness is the
    /// whole point.** That one decides whether to *add* a promise, where a false
    /// positive costs a redundant half-sentence. This one decides whether to
    /// *contradict* one, where a false positive means telling the owner a
    /// promise is broken when it is being kept — the appliance crying wolf about
    /// its own reliability, which is its own kind of untrustworthy.
    ///
    /// Three conditions, and each one was earned:
    ///
    /// **An after-the-call phrase**, which is `alreadyPromises`.
    ///
    /// **A first-person commitment.** "What did you want after the call?" is a
    /// question, not a promise.
    ///
    /// **No redirect back to the owner.** This is the one that matters. *"I
    /// can't send files while we're on the line — message me in the chat after
    /// the call and I'll send it over"* has both halves above and is
    /// nevertheless completely honest: it puts the next move in the owner's
    /// hands and commits the appliance to remembering nothing. It is also the
    /// exact sentence `ToolLoop.unqueuedPromiseCorrection` asks for when there
    /// is nothing to queue, so counting it as a broken promise would mean
    /// retrying the model's compliance with the correction, and then replacing a
    /// well-worded answer with a canned one.
    static func commitsToDoingItLater(_ reply: String) -> Bool {
        let lowered = reply.lowercased()
        guard alreadyPromises(lowered) else { return false }

        // Imperatives aimed at the owner, with the appliance as the object. Not
        // "signal" or "the chat" on their own: the reply that caused all of this
        // said it would send the ticket "to your Signal thread", so a bare
        // channel name is present in the failure as well as in the fix.
        let handsItBack = [
            #"\b(message|text|ping|dm|ask|remind|nudge|drop|send|shoot)\s+me\b"#,
            #"\blet me know\b"#
        ]
        guard !handsItBack.contains(where: {
            lowered.range(of: $0, options: .regularExpression) != nil
        }) else { return false }

        let commitments = [
            #"\bi(?:'ll| will)\b"#,
            #"\bwill do\b"#,
            #"\bi(?:'m| am) going to\b"#,
            #"\bconsider it done\b"#,
            #"\bleave it with me\b"#
        ]
        return commitments.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    static func alreadyPromises(_ reply: String) -> Bool {
        let lowered = reply.lowercased()
        // Phrases a model actually produces when it has understood the tool
        // result. Matching on intent rather than on an exact sentence, because
        // the prompt asks for one line in its own words.
        let tells = [
            "after we hang up",
            "after the call",
            "after this call",
            "once we're done",
            "once we are done",
            "when we hang up",
            "once the call"
        ]
        return tells.contains { lowered.contains($0) }
    }
}
