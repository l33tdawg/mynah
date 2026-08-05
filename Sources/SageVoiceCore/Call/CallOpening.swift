import Foundation

/// What the appliance says to a caller before it starts thinking.
///
/// **The defect this exists to fix, #47.** The call surface read
/// `WorkingReply.opening`, whose catch-all pool — the one that carries every
/// request naming nothing in particular, which is most of them — says things
/// like *"On it — give me a couple of minutes and I'll come back when it's all
/// done."* On Signal that is true, and is exactly what the owner asked for:
/// there is a thread to come back to, and 1.7.3 made the promise durable.
///
/// On a call it is a promise nothing can keep. The line drops, and there is no
/// thread the answer belongs to. The caller was told to expect a delivery that
/// was never going to arrive, on a surface where Mynah is *already present and
/// about to speak* — so the sentence is not merely unkeepable, it describes the
/// wrong situation entirely.
///
/// The owner's ruling, 5 August 2026: **the call gets its own opener pool, whose
/// lines never promise a later delivery. Signal's pool is untouched.** He chose
/// that over stripping promises from one shared pool, and the reason is worth
/// keeping: that would have deleted a true statement from the surface where it
/// is true.
///
/// ## Why this overrides rather than copies
///
/// Only `.anything` is written out below. `.backlog`, `.earlier`, `.document`
/// and `.lookup` come straight from `WorkingReply`, because those lines are
/// already present-tense and promise nothing — *"Let me check your backlog."*
/// is as right on a call as in a thread.
///
/// Copying them here to make the pool look self-contained would create two sets
/// of strings that have to be kept in step, which is the single defect family
/// this codebase keeps paying for: a rule fixed at one call site while the
/// identical one goes unwatched. The guarantee does not depend on where the
/// strings live — `CallOpeningPromisesNothingTests` walks every
/// `RequestKind` and checks whatever `lines(for:)` returns, inherited or not.
/// If somebody later adds a promise to Signal's `.lookup` pool, that test fails
/// on the call's behalf.
enum CallOpening {

    /// The call's line pool for a classification.
    ///
    /// The classification itself is `WorkingReply.kind(forRequest:)` and is
    /// deliberately shared: a request Signal reads as a lookup is a lookup on a
    /// call too, and two keyword lists would be two things to keep in step.
    static func lines(for kind: WorkingReply.RequestKind) -> [String] {
        switch kind {
        case .anything:
            return catchAllOptions
        case .backlog, .earlier, .document, .lookup:
            // Present-tense already, and true on either surface. See the note
            // above on why these are not copied.
            return WorkingReply.lines(for: kind)
        }
    }

    /// The call's catch-all: what it says when the request named nothing.
    ///
    /// The shape the owner agreed — *"One moment — let me look that up." /
    /// "Checking that now." / "Give me a second, I'm pulling it up."* — is the
    /// first three. Each describes only what is happening now, which is the
    /// whole property: on a call Mynah is about to speak, so an opener has no
    /// business describing anything later.
    ///
    /// **Six, matching Signal's count, and for a stronger reason.** The owner
    /// asked for five or six there so the line he *reads* most often would not
    /// feel robotic. On a call this pool is heard on nearly every turn of every
    /// conversation, out loud, where repetition is far more obvious than it is
    /// in text — a voice saying the identical six words each time is the single
    /// clearest signal that nobody is home.
    ///
    /// They also vary in opening word, all six of them, for the same reason
    /// Signal's do: a pool where every line starts the same way is one sentence
    /// with six spellings.
    ///
    /// Like Signal's catch-all these name nothing — no tool, no source, no claim
    /// beyond having heard the question. Nothing has decided anything yet at the
    /// moment this is spoken, so anything more specific would be a guess said
    /// out loud.
    static let catchAllOptions = [
        "One moment — let me look that up.",
        "Checking that now.",
        "Give me a second, I'm pulling it up.",
        "Right, let me see.",
        "On it — one sec.",
        "Let me have a look at that."
    ]

    /// The opener for a turn nobody cut off.
    static func opening(
        forRequest request: String,
        previous: String? = nil,
        chooser: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> WorkingReply.Opening? {
        WorkingReply.opening(forRequest: request, previous: previous, chooser: chooser, from: lines(for:))
    }

    /// The opener for a turn that cut another one off.
    ///
    /// **Being interrupted is a different event from being asked**, and it used
    /// to produce the same sentence. The owner: *"if user starts speaking half
    /// way, we have the agent say something when they end that acknowledges the
    /// new ask before actually doing it."*
    ///
    /// This lives here rather than in `WorkingReply` because interruption is a
    /// call-only event — Signal has no barge-in, and `CallTurnServer` was its
    /// only call site in the tree even while it sat on the shared type.
    ///
    /// Cutting in stops the audio instantly: the endpoint drops what is queued
    /// locally, so from the caller's side the appliance goes abruptly silent,
    /// and the next thing they hear decides whether it *heard* them or merely
    /// *stopped*. So the line leads with the turn — the old answer is being
    /// dropped, on purpose, in favour of what was just said.
    static func interruptedOpening(
        forRequest request: String,
        previous: String? = nil,
        chooser: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> WorkingReply.Opening? {
        let turn = acknowledgements[
            min(max(chooser(acknowledgements.count), 0), acknowledgements.count - 1)
        ]

        // A specific opener names what is about to happen, so the two halves
        // read as one sentence: "Right — looking into that now."
        if let specific = opening(forRequest: request, previous: previous, chooser: chooser),
           specific.isSpecific {
            return WorkingReply.Opening(line: joined(turn, specific.line), isSpecific: true)
        }
        // Nothing specific to name. Say only the true part: the previous answer
        // is abandoned and this one is heard. Inventing a subject here would be
        // the appliance guessing out loud on the one turn where the caller has
        // just demonstrated it was heading the wrong way.
        return WorkingReply.Opening(line: "\(turn) \(whenNothingIsNamed)", isSpecific: false)
    }

    /// How a cut-in is acknowledged before the opener it prefixes.
    static let acknowledgements = ["Right —", "Okay —", "Sure —"]

    /// The tail of a cut-in that had nothing specific to name.
    static let whenNothingIsNamed = "let me get that instead."

    /// One sentence rather than two bolted together: the opener's own capital
    /// would read as a full stop where the dash is.
    static func joined(_ acknowledgement: String, _ opener: String) -> String {
        "\(acknowledgement) \(opener.prefix(1).lowercased() + opener.dropFirst())"
    }

    /// **Every sentence the call can speak as an opener.**
    ///
    /// The reason this is derived rather than written down: the property #47
    /// asks for is about what a caller can *hear*, and the only honest way to
    /// check that is to enumerate it from the same code the caller reaches. The
    /// 1.7.3 review found this exact guard wrong twice — a hand-written list of
    /// probe requests missed ten of sixteen pools, and the sentinel meant to
    /// catch that was then calibrated to what the probes happened to return.
    ///
    /// Walking `RequestKind.allCases` cannot go stale that way. A new kind is a
    /// compile error in `lines(for:)`, and it appears here the moment it exists
    /// without anybody remembering to add a probe.
    ///
    /// Includes the cut-in compositions, mirroring `interruptedOpening`
    /// exactly — the prefixed form is only reachable for a *specific* opener,
    /// and the bare acknowledgement plus `whenNothingIsNamed` for the rest.
    static var everySpokenLine: [String] {
        var spoken: [String] = []
        for kind in WorkingReply.RequestKind.allCases {
            let pool = lines(for: kind)
            spoken.append(contentsOf: pool)
            // `.anything` is not specific, so it is never prefixed.
            guard kind != .anything else { continue }
            for turn in acknowledgements {
                spoken.append(contentsOf: pool.map { joined(turn, $0) })
            }
        }
        for turn in acknowledgements {
            spoken.append("\(turn) \(whenNothingIsNamed)")
        }
        return spoken
    }
}
