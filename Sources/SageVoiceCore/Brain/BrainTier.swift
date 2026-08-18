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
/// **`mayCarryImages` is now the live example of that AND, and it is worth
/// reading before touching it.** The 1.7.2 audit found it inert, because it was
/// `false` on `.hosted` and nothing read it. Both halves have since landed. The
/// field is `true` on both tiers today, and every backend computes its own
/// `seesImages` as
///
///     brain.mayCarryImages && <this model can see>
///
/// where the right-hand side is `CloudBrainModelCatalog.seesImages(model:)` for
/// a hosted backend and `LocalVisionModels.sees(_:)` for a local one, each
/// defaulting to blind for a model it does not recognise.
///
/// So flipping this to `true` did **not** grant any brain vision, and flipping
/// it back to `false` *would* take vision away from every brain in that tier at
/// once. It is a ceiling in both directions: it can only ever subtract. A
/// reader who skims this field and concludes "hosted brains see now" has read
/// half the sentence — the per-model table is the half that decides.
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
    /// **A ceiling, never a grant**, and now that both tiers say `true` that
    /// sentence is carrying real weight rather than describing an inert field.
    /// It was `false` on `.hosted` because the word "image" did not appear in
    /// `AnthropicBackend.swift` or `OpenAICompatBackend.swift` — a statement
    /// about this repository, not about the vendors. Both encoders have landed,
    /// so the statement stopped being true and the field followed it.
    ///
    /// What decides whether a photo actually goes out is the AND on each
    /// backend's `seesImages`: this ceiling, and then
    /// `CloudBrainModelCatalog.seesImages(model:)` or
    /// `LocalVisionModels.sees(_:)` for the one model that instance is bound to.
    /// A model missing from either table reads as blind, which is the direction
    /// that costs a description rather than the direction that invents one.
    ///
    /// Setting this `false` for a tier is still meaningful and still supported:
    /// it turns off pictures for every brain in that tier regardless of model,
    /// which is what a ceiling is for.
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
    /// Measured on this Mac with `scripts/measure-tool-routing.py`: 14 tools
    /// scored 12/12 on routing; 27 added ~9.5 KB of schema, cost 3.4 s per turn
    /// on qwen3.5:4b and dropped a 26B model to 5–6/12. The published curve has
    /// the same shape — 78% at 10 falling to 13.62% past 100 — and the research
    /// on progressive disclosure says plainly that it "buys context, not
    /// intelligence" and is redundant when the agent is already strong, which is
    /// the owner's sentence arrived at from the other side.
    ///
    /// 20 on device is **what ships**: `ApplianceCatalogue.conversation` composes
    /// exactly twenty today — fifteen curated SAGE tools, four note tools and
    /// `web_search`. It sits between the two measurements and has not itself
    /// been measured, so one of this number's jobs is to be a ratchet: a
    /// twenty-first tool turns `BrainTierTests` red and forces the re-run,
    /// rather than letting the catalogue drift past the cliff the way it already
    /// drifted past the "18" its own comment claimed.
    ///
    /// 27 on hosted is a **permission, not a measurement** — the size of SAGE's
    /// full published catalogue. The half of the 27-tool result that forbids it,
    /// the accuracy drop, was taken on local models only; the latency half is
    /// somebody else's hardware here.
    ///
    /// **This is read at runtime now, and the sentence that used to be here is
    /// what changed.** It said: *"Read by `BrainTierTests` and by nothing at
    /// runtime … the ratchet is the whole of its current job. How many tools a
    /// skill loader may expose is a tier field, not a global constant — which
    /// is what this becomes when that loader is written."* The loader is being
    /// written, and this is that promise cashed in.
    ///
    /// `ToolLoop.availableTools()` counts the composed catalogue against this
    /// number and **refuses** past it — `ToolLoopError.catalogueOverTierCeiling`,
    /// which names the tier, the count, the tools past the line and the two
    /// ways out. It does not truncate to fit. Truncating would hand the model
    /// twenty schemas while the owner believes twenty-one are live, which is a
    /// feature lying about having worked.
    ///
    /// A hosted brain is no longer offered exactly what a local one is: the
    /// same catalogue is composed for both, and this is the only thing that
    /// differs. What that buys today is headroom rather than tools — 20 is
    /// exactly what ships, so the local tier has none — and what it buys
    /// tomorrow is that a skill the owner enables can be refused on the small
    /// brain and offered on the large one, by the same arithmetic, with no
    /// second constant to keep in step.
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
        maxRoutableTools: 20
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
        // **The 1.7.2 finding, resolved rather than reversed.** This was `false`
        // because no hosted encoder existed; both now do, so the ceiling stops
        // contradicting the code. It is not a grant — see the field's comment
        // and `CloudBrainModelCatalog.sighted`, which is what actually decides.
        mayCarryImages: true,
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
