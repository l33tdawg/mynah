import Foundation

/// What a class of brain is allowed to do — the owner's rule, written once.
///
/// He stated it twice, in these words: *"local model can do up to x - api models
/// can do x + y + z"*. That rule already governed this codebase and was written
/// down nowhere. It was decided independently in nine places, and one of them
/// had no branch at all: `ToolLoop.Configuration.maxToolResultCharacters` was a
/// hardcoded 6,000 applied *after* `VoiceToolBudget` had deliberately granted a
/// hosted brain 32,000 — so the hosted allowance was really 6,000, and had been
/// since the day it shipped. Nobody noticed, because the local content budget is
/// *also* exactly 6,000 and the repo's own regression test calls `fit` directly
/// instead of going through the loop. That is what a rule enforced by folklore
/// costs.
///
/// ## The tier is derived, never declared
///
/// `BrainBackend.isLocal` is the only bit a backend states about itself, and it
/// is stated for a different reason — it answers *where the owner's words go*,
/// which the Settings screen shows him. The tier is computed from it rather than
/// declared beside it, because a backend able to declare both is a backend able
/// to make them disagree, and one place that can be contradicted is not one
/// place.
///
/// ## Ceilings, never abilities
///
/// A tier saying a hosted brain may carry an image does not put an image on the
/// wire.
///
/// Every capability here is AND-ed with what the backend actually implements,
/// and only in that direction — `ToolLoop.backendSeesImages` reads
/// `BrainBackend.seesImages`, and `VoiceBridgeDaemon` passes that to the
/// attachment note.
///
/// **With one exception, named because the 1.7.2 audit went looking for it:**
/// `mayCarryImages` is the tier's half of that AND and nothing reads it yet.
/// The backend half is what decides today, and it defaults to pessimistic — so
/// the behaviour is correct and the field is inert. It flips in one place when
/// the two wire encoders land (#36); until then, changing it changes nothing,
/// and a reader who assumes otherwise will believe they granted vision and will
/// not have.
public enum BrainTier: String, Sendable, Equatable, Hashable, Codable, CaseIterable {

    /// A model running on this Mac, whether through Ollama or an OpenAI-shaped
    /// local server. The owner's words never leave the machine.
    case onDevice

    /// A vendor API behind a key. **Not** `CloudBrainModelCatalog.Tier`, which
    /// is a different axis: that one picks between a provider's two models
    /// (Quick and Careful) once something has already decided to connect.
    case hosted

    public var capabilities: BrainCapabilities { BrainCapabilities(tier: self) }
}

/// The ceilings for one tier.
///
/// Every field is a number or a permission that used to live somewhere else, and
/// the doc comment on each carries the measurement or the owner ruling that set
/// it. Moving them here changed none of those numbers except where a comment
/// says so explicitly.
public struct BrainCapabilities: Sendable, Equatable {

    /// Which tier this describes.
    ///
    /// Stored rather than inferred, because callers legitimately need to ask —
    /// `//call`'s refusal names the tier in the sentence it shows the owner, and
    /// a struct that could not say which tier it was would send them back to the
    /// backend to find out, which is the scattering this type exists to end.
    public let tier: BrainTier

    /// Floor under whatever the caller asked for, in generated tokens.
    ///
    /// **A local model's budget is not a sane cap for a cloud one.** A hosted
    /// reasoning model spends the allowance thinking before it writes anything,
    /// so a small cap does not produce a short answer — it produces
    /// `stop_reason: max_tokens` with nothing in it. Asked to research EDR and
    /// SIEM tools and write a PDF, `deepseek-v4-flash` called `write_note` eight
    /// times in one turn and every call arrived with no `content`, because the
    /// document rides *inside* the tool call and 1,024 tokens cut the JSON off
    /// mid-argument.
    ///
    /// Zero on `.onDevice` is a floor, not a sentinel: `max(n, 0) == n`, so the
    /// local ceiling stays exactly what `ReplyStyle` chose. Raising it would be
    /// actively harmful — with no tools attached and a thin context, qwen3.5:4b
    /// was measured generating 4,069 tokens over 190 s and returning empty
    /// content.
    public let minimumOutputTokens: Int

    /// The most a *directory-shaped* tool result may contribute.
    ///
    /// 2,000 bytes on device is about 0.7 s of prefill at the measured rate
    /// (0.36 ms per byte on qwen3.5:4b, this Mac, 2026-07-29), where the 31,321
    /// bytes `sage_status` returned at the time was ~11 s of silence before the
    /// appliance could speak. **That reply is now 1,055 bytes** — app-v23 made
    /// the caller-scoped status drop `by_domain`, which was 93% of it — so
    /// `sage_status` no longer reaches this ceiling; other directory-shaped
    /// tools still do. See `VoiceToolBudget`. Against a hosted model that
    /// arithmetic does not hold
    /// — the prefill happens on somebody else's hardware, in parallel — so the
    /// ceiling is eight times larger and still cheap.
    public let directoryResultBytes: Int

    /// The most a result that *is* the owner's content may contribute.
    ///
    /// **One number for every tool was wrong, and it showed on his phone.** He
    /// asked what his agents had sent; Codex had written two long messages; the
    /// second was cut at 2 KB and Mynah reported *"the second message got
    /// truncated by the system, so I may have missed its tail end."* Honest, and
    /// useless — the message was the errand. A truncated directory loses 839
    /// subject names nobody could hear read aloud; a truncated message loses the
    /// thing that was asked for. Which tools count, and why, is
    /// `VoiceToolBudget.contentTools`.
    public let contentResultBytes: Int

    /// Whether a brain in this tier can be sent a photo at all.
    ///
    /// A ceiling, never a grant. `false` on `.hosted` states a fact about this
    /// repository rather than about the vendors: the word "image" does not
    /// appear in `AnthropicBackend.swift` or `OpenAICompatBackend.swift`, so a
    /// hosted backend declaring vision today would be claiming to have seen a
    /// picture it dropped on the floor — the exact fabrication
    /// `BrainBackend.seesImages`'s pessimistic default exists to prevent.
    ///
    /// Flips to `true` in this one place when the two wire encoders land, and
    /// `CloudBrainModelCatalog` then narrows it per model — a model missing from
    /// that table must still read as blind.
    public let mayCarryImages: Bool

    /// Whether the prompt cache lives in one slot on this machine.
    ///
    /// One fact behind two behaviours. Ollama holds a single KV cache for the
    /// model, in this Mac's RAM, and drops it when `keep_alive` elapses — so
    /// keep-warm is worth paying for (an appliance is idle for hours and then
    /// wanted *immediately*), and cache anchoring is not optional, because a
    /// checkpoint planted on the wrong prefix does not merely miss: it destroys
    /// the one the last turn left. Measured in `ollama.log` before the fix,
    /// alternating forever:
    ///
    ///     n_past 6137, prompt eval  1.3 s /  439 tokens   ← a real turn
    ///     n_past 3516, prompt eval 12.0 s / 2613 tokens   ← keep-warm
    ///
    /// A hosted provider has no slot to protect: its cache is server-side and
    /// prefix-keyed, and a warm-up against Gemini's ten-per-minute free tier
    /// spends a tenth of the owner's first minute buying nothing — 72 requests a
    /// day before he has said a word.
    ///
    /// **Not the same question as "does this tier support prompt caching".**
    /// Anthropic's `cache_control` is a hosted feature and would be its own
    /// field; this one is about a slot our own timer can evict.
    public let servesOneCacheSlot: Bool

    /// Whether a brain in this tier may hold a phone line.
    ///
    /// **This barrier existed, was deleted on evidence, and came back on better
    /// evidence.** A `backendTooSlow` refusal used to turn away every brain on
    /// this Mac, on a measured 40–60 s floor to first token. It was deleted on
    /// 29 July 2026 when `qwen3.5:4b` answered three questions here in 5, 6 and
    /// 9 seconds, two of them with a SAGE tool call inside — and the comment
    /// left behind said that if a local call ever did turn out to be a dead
    /// line, *the fix is to measure time to first token, not to reinstate the
    /// proxy*, because a slow cloud model would sail past the old check too.
    ///
    /// That is still the right instruction and this field does not pretend
    /// otherwise. What changed is the evidence: on 4 August 2026 a tester spent
    /// a call on `qwen3.5:4b` and reported *"quite slow to think"*, seven filler
    /// lines in a single wait — *"Right let me get that instead… Okay… One
    /// moment… Almost… Still on it, nearly done…"* — a laptop made *"very
    /// laggy"*, and answers lost outright when the model was interrupted
    /// mid-thought. The owner's ruling: *"calling on qwen seems unusable we
    /// should disable //call for local - only api - voice notes local handles
    /// fine but realtime calls is too much"*.
    ///
    /// So this is the tier standing in for time-to-first-token again, knowingly,
    /// with the measurement still owed. Two things would retire it: the call
    /// surface getting the prompt-cache work the daemon already has — it
    /// re-prefills verbatim tool output every turn with no anchor, which is very
    /// likely *why* it is slow — and then a real TTFT number to gate on.
    public let holdsARealtimeCall: Bool

    /// How many tools a brain in this tier may be asked to choose between.
    ///
    /// **Re-measured on 19 Aug 2026, and the number moved because the
    /// measurement said it could.** `scripts/measure-tool-routing.py` against
    /// qwen3.5:4b, the real 8,300-character voice prompt, this Mac, sweeping
    /// catalogue size with the shipped fifteen SAGE names always present so a
    /// miss is a routing failure and never a tool the model was not shown.
    /// "composed" is what this constant bounds — the SAGE slice plus the four
    /// note tools and `web_search`:
    ///
    ///     composed  20  21  22  24  27  32  38
    ///     score      9   9   9   9   9   6   7   (of 12)
    ///
    /// Flat to 27 and identical at every step, then a cliff. So the old "14
    /// scored 12/12, 27 dropped to 5-6/12" is superseded rather than refined,
    /// and it is worth saying why it cannot simply be compared: it was measured
    /// against a tool list that had DRIFTED out of the appliance — it contained
    /// `sage_pipe` and `sage_pipe_result`, both since removed for being misused,
    /// and lacked all three message tools. Whatever it measured, the appliance
    /// never ran it.
    ///
    /// The three misses in the flat region are the same three every time —
    /// `sage_timeline` answered with `sage_backlog`, `sage_forget` with
    /// `sage_recall`, `sage_directory` with `sage_backlog`. Those are collisions
    /// between tool DESCRIPTIONS and they do not move with catalogue size. Past
    /// the cliff the failure changes shape: the model starts choosing
    /// `sage_list`, a tool that is not in the shipped catalogue at all. That is
    /// the size effect — distractors beginning to win — and it is the thing this
    /// ceiling exists to stay clear of.
    ///
    /// 22 on device, chosen by the owner and supported with five composed tools
    /// of margin under the first measured degradation. It is still a ratchet: a
    /// twenty-third tool turns `BrainTierTests` red and forces the re-run,
    /// rather than letting the catalogue drift past the cliff the way it already
    /// drifted past the "18" its own comment claimed. Do not raise it again from
    /// an argument; raise it from a rerun, and paste the table.
    ///
    /// 27 on hosted is a **permission, not a measurement** — the size of SAGE's
    /// full published catalogue. The half of the 27-tool result that forbids it,
    /// the accuracy drop, was taken on local models only; the latency half is
    /// somebody else's hardware here.
    ///
    /// **Read by `BrainTierTests` and by nothing at runtime**, and that is
    /// stated rather than left to be discovered: `ToolLoop.Configuration`
    /// applies `BrainPrompts.voiceToolAllowlist` unconditionally, so a hosted
    /// brain is offered exactly what a local one is — nineteen after the 5 Aug
    /// cuts (`sage_list`, `sage_reflect`) and the messages swap (`sage_pipe` out,
    /// `sage_message_send` and `sage_message_reply` in). One slot of headroom
    /// under the ceiling, deliberately. The ratchet is the
    /// whole of its current job. How many tools a skill loader may expose is a
    /// tier field, not a global constant — which is what this becomes when that
    /// loader is written.
    public let maxRoutableTools: Int

    public init(
        tier: BrainTier,
        minimumOutputTokens: Int,
        directoryResultBytes: Int,
        contentResultBytes: Int,
        mayCarryImages: Bool,
        servesOneCacheSlot: Bool,
        holdsARealtimeCall: Bool,
        maxRoutableTools: Int
    ) {
        self.tier = tier
        self.minimumOutputTokens = minimumOutputTokens
        self.directoryResultBytes = directoryResultBytes
        self.contentResultBytes = contentResultBytes
        self.mayCarryImages = mayCarryImages
        self.servesOneCacheSlot = servesOneCacheSlot
        self.holdsARealtimeCall = holdsARealtimeCall
        self.maxRoutableTools = maxRoutableTools
    }

    public init(tier: BrainTier) {
        switch tier {
        case .onDevice: self = .onDevice
        case .hosted: self = .hosted
        }
    }

    public static let onDevice = BrainCapabilities(
        tier: .onDevice,
        minimumOutputTokens: 0,
        directoryResultBytes: 2_000,
        contentResultBytes: 6_000,
        mayCarryImages: true,
        servesOneCacheSlot: true,
        holdsARealtimeCall: false,
        maxRoutableTools: 22
    )

    public static let hosted = BrainCapabilities(
        tier: .hosted,
        // **16,384 because 4,096 could not emit the document it was sized for.**
        //
        // The arithmetic, which nobody had done end to end. `write_note` accepts
        // 32,000 characters (`NotesToolSource.maximumContentCharacters`) and
        // truncates past it. 32,000 characters is roughly 8,000 tokens. The
        // document travels *inside* the tool call, so the generation budget has
        // to cover the whole JSON argument — and at 4,096 tokens the call is cut
        // at about 16,000 characters, half of what `write_note` would have
        // taken. The ceiling that was supposed to bound the document was
        // instead bounding it below its own limit.
        //
        // Worse on a reasoning model, which is the case this floor exists for:
        // thinking is spent from the same allowance before a single character of
        // the report is written, so the usable share is smaller again.
        //
        // 16,384 leaves the full 32,000-character document (~8,000 tokens),
        // the JSON scaffolding around it, and room to think first.
        //
        // **`.onDevice` is untouched and must stay so.** Its floor is 0, which
        // means `ReplyStyle` keeps deciding the local ceiling exactly as before.
        // Raising it would be actively harmful — qwen3.5:4b was measured
        // generating 4,069 tokens over 190 seconds and returning empty content.
        minimumOutputTokens: 16_384,
        directoryResultBytes: 16_000,
        contentResultBytes: 32_000,
        mayCarryImages: false,
        servesOneCacheSlot: false,
        holdsARealtimeCall: true,
        maxRoutableTools: 27
    )

    /// The loop's last-resort cut, applied after `VoiceToolBudget` has already
    /// fitted the result.
    ///
    /// **This is the number that was hardcoded at 6,000 with no tier branch, and
    /// it silently cancelled the budget above it.** `ToolLoop.execute` applies
    /// `VoiceToolBudget.fit` correctly — 32,000 bytes for an agent's message on
    /// a hosted brain — and then `run` truncated it again at 6,000,
    /// unconditionally. Invisible on this Mac, because the local content budget
    /// is *also* 6,000 and the second cut never bit.
    ///
    /// Deliberately above the largest budget rather than equal to it, and the
    /// headroom is not slack. `fit` appends a sentence saying what it removed —
    /// the one thing that must survive every adjustment to these numbers,
    /// because a model handed a severed answer has to know it was severed. Set
    /// equal, this would cut that sentence off and leave the model reading half
    /// a result as if it were whole: two truncations stacking to produce exactly
    /// the confident wrong answer both of them exist to prevent.
    ///
    /// So after the fit it is **unreachable by design**, and that is the point.
    /// What it still guards is the strings `execute` builds itself — a tool
    /// failure description from a server that answered with a novel — which
    /// `fit` never sees. `ToolLoopTests` pins that it can still fire by passing
    /// an explicit ceiling.
    ///
    /// Counted in `Character`s where the budgets count UTF-8 bytes. A
    /// `Character` is never fewer than one byte, so the inequality only ever
    /// runs the safe way.
    public var toolResultBackstopCharacters: Int {
        max(directoryResultBytes, contentResultBytes) + 512
    }

    /// One question instead of multiplier arithmetic.
    ///
    /// The ×3/×8/×16 chain spread across two files is how the 6,000 coincidence
    /// hid: two numbers that happened to be equal for different reasons, in
    /// different units, in different files.
    public func toolResultBytes(carryingContent: Bool) -> Int {
        carryingContent ? contentResultBytes : directoryResultBytes
    }
}
