import Foundation

/// **The one place that decides which sources make up a catalogue.**
///
/// There were three of these, written out longhand: `makeToolSource` and
/// `makeCallToolSource` in `sage-voiced/main.swift`, and a third inline in
/// `ConversationModel`. They agreed by somebody remembering to change all
/// three, and they had already stopped agreeing — the window declared its
/// memory source should publish `["sage_recall", "sage_remember"]`, a
/// hand-guessed two-name literal that matched neither of the other two SAGE
/// declarations, which each derived a different set by hand-written subtraction
/// from `BrainPrompts`.
///
/// Collapsing them here is not tidiness. It is what makes the composed
/// catalogue *testable*: the golden-set test in `ApplianceCatalogueTests`
/// asserts the exact twenty names a Signal message is offered and the exact
/// seventeen a call is offered, against the same function production calls. A
/// golden set asserted against a copy of the wiring proves nothing about the
/// wiring.
///
/// Providers are passed in rather than built here on purpose. The daemon and
/// the window construct their `WebSearchToolSource` differently (one has a
/// browser engine, both want their own log sink) and the notes source is held
/// by its caller because the caller has to ask it afterwards what it wrote.
/// What this type owns is the *shape*: which sources, in which order, curated
/// or self-declaring, required or optional.
public enum ApplianceCatalogue {

    /// What a Signal message, a voice note or the Mac window may reach.
    ///
    /// **Twenty tools on device, twenty-one on a hosted brain.** Fifteen or
    /// sixteen curated from SAGE — see `BrainPrompts.sageToolCuration(for:)` —
    /// plus four notes tools and `web_search`. Neither count is written down as
    /// a constant; both emerge from these registrations, and
    /// `ToolLoop.availableTools()` refuses to offer a catalogue larger than
    /// `BrainCapabilities.maxRoutableTools`, which is 20 on device and 27
    /// hosted.
    ///
    /// On device that is deliberately zero headroom: the twenty-first tool is a
    /// refusal the owner can read, not a silent drift past the routing cliff
    /// the way the catalogue already once drifted past the "18" its own comment
    /// claimed. Hosted has six spare, and they are not there to be spent
    /// casually — every name still has to earn its slot on the same test, and
    /// two candidates were turned down in the same change that added the
    /// sixteenth.
    ///
    /// Order is load-bearing in one direction only: memory first, so a memory
    /// tool can never be shadowed by a source registered later. Everything
    /// after it publishes names nothing else claims.
    /// - Parameter brain: which brain will be offered this catalogue. **No
    ///   default, deliberately.** A default would be a fourth place that
    ///   decides tool curation by omission, and curation-by-omission is the
    ///   defect this whole type was collapsed to end. It also cannot be
    ///   defaulted safely in either direction: `.onDevice` silently withholds a
    ///   tool from a brain that can route it — the bug the owner hit — and
    ///   `.hosted` silently hands the local brain a twenty-first tool, which
    ///   `ToolLoop.availableTools()` answers by refusing the turn outright.
    public static func conversation(
        memory: ToolProviding,
        notes: ToolProviding,
        web: ToolProviding?,
        brain: BrainTier,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> CompositeToolSource {
        var sources: [CompositeToolSource.Source] = [
            // Curated, because SAGE is somebody else's program. It published
            // 27 tools when this was written and publishes 33 today — it grows
            // between releases, and a curated list that is never re-checked
            // against the node is a list that silently stops matching it. The
            // names, and the ~250 lines saying why the rest are out, live in
            // `BrainPrompts.sageToolCuration(for:)`.
            //
            // Tier-dependent, and that is the point: the local brain gets the
            // measured fifteen and the hosted one gets sixteen. See that
            // function for why a single set sized for the 4B was the bug.
            .external(
                label: "SAGE memory",
                provider: memory,
                isRequired: true,
                curated: BrainPrompts.sageToolCuration(for: brain)
            ),
            // Required, and self-declaring. Unlike search, this has no network
            // to be down and no credential to expire — if it cannot list its
            // four tools something is wrong with the appliance itself, and
            // degrading quietly would hide it.
            .inProcess(label: "notes", provider: notes, isRequired: true)
        ]
        if let web {
            // Not required. The owner's phone is a long way from this Mac, and
            // "the internet lookup is down" must not read as "Mynah is down".
            sources.append(.inProcess(label: "web search", provider: web, isRequired: false))
        }
        return CompositeToolSource(sources: sources, log: log)
    }

    /// What a phone call may reach: no notes source at all, and a queue instead.
    ///
    /// **Not registering the source is the whole mechanism**, and that is
    /// stronger than the name filter it replaced. `CompositeToolSource` builds
    /// its name→provider table from what each source publishes, so a notes
    /// source left registered would still route `send_file` for a model that
    /// produced the name anyway — put the owner's file into the daemon's shared
    /// `outgoing` buffer, and have it arrive stapled to some unrelated later
    /// reply. Unregistered, the name comes back as `Failure.unknownTool`.
    ///
    /// Seventeen tools on device and eighteen hosted: the same SAGE curation a
    /// conversation gets, `after_the_call`, and `web_search`. Strictly smaller
    /// than a conversation on both tiers, never larger — the subtraction is the
    /// notes source, which is not registered here at all.
    public static func call(
        memory: ToolProviding,
        afterTheCall: ToolProviding,
        web: ToolProviding?,
        brain: BrainTier,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> CompositeToolSource {
        var sources: [CompositeToolSource.Source] = [
            // Same curation as a conversation, tier and all. "Did they read it
            // yet?" is as answerable on a call as in a thread, and a call that
            // knew less than a message about the same question would be a
            // difference the owner would have to learn rather than one he could
            // predict.
            .external(
                label: "SAGE memory",
                provider: memory,
                isRequired: true,
                curated: BrainPrompts.sageToolCuration(for: brain)
            ),
            // Required for the same reason the notes source is on a
            // conversation: it is in-process and has nothing to be down, so a
            // failure to publish means something is wrong with the appliance
            // rather than with the network.
            .inProcess(label: "after the call", provider: afterTheCall, isRequired: true)
        ]
        if let web {
            sources.append(.inProcess(label: "web search", provider: web, isRequired: false))
        }
        return CompositeToolSource(sources: sources, log: log)
    }
}
