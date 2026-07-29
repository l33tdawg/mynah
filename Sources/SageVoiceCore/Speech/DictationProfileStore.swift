import Foundation

/// The one dictation profile, compiled once and shared.
///
/// ## One stack for both ways in
///
/// The window and the daemon must hear with the same vocabulary. Two profiles
/// that drift would be the pause-store bug in a new costume: two stores for one
/// fact, agreeing until they quietly do not, and the symptom being that the
/// same word comes out differently depending on which way the owner spoke it.
///
/// So this is where the profile lives, in `SageVoiceCore`, reachable from both.
///
/// ## Why the profile is not fed to the recogniser as a prompt
///
/// `AudioTranscriptionOptions.initialPrompt` exists, `WhisperKitServerTranscriber`
/// already sends it, and `ASRPromptBuilder` already renders one — and the
/// production path deliberately does not use any of it.
/// `ASRPromptBuilder.productionOptions()` returns `.none`, with the reason
/// recorded on it: prompting *"added material release-to-text latency without
/// changing retained-corpus output"*. Somebody measured it and turned it off.
///
/// That is worth knowing before wiring it back up, because the obvious plan —
/// memories to prompt to recogniser — is the half that was already tried and
/// rejected. What was found to work is the deterministic pass *after* ASR, and
/// that is what this feeds.
///
/// The prompt path is left intact rather than deleted: it costs nothing dormant,
/// and if a future recogniser has different economics the carrier is still
/// there.
public actor DictationProfileStore {

    public static let shared = DictationProfileStore()

    /// Supplies remembered text. Returns empty when there is nothing to mine.
    ///
    /// This said "when Mynah cannot read its own memories, which is the state
    /// on the owner's machine today". It was then rewritten to say the opposite
    /// — that Mynah "reads this node freely" — and **that was the wrong
    /// correction**. Reads are gated per domain just as writes are.
    ///
    /// The original sentence was near enough. What was genuinely wrong with it
    /// is smaller and still worth naming: it conflated *reading* with *having*.
    /// Mynah has stored nothing, so there is nothing of its own to mine — which
    /// is true regardless of what it may read elsewhere, and is the only fact
    /// this source needs.
    public typealias MemorySource = @Sendable () async -> [String]

    private var cached: DictationProfile?
    private var source: MemorySource?

    public init() {}

    /// Sets where remembered text comes from, and drops any cached profile.
    ///
    /// Called once at start-up by whichever process is wiring itself up. The
    /// source is injected rather than reached for so that this type has no
    /// opinion about MCP, recall, or RBAC — it composes text into a profile and
    /// nothing else.
    public func use(source: @escaping MemorySource) {
        self.source = source
        cached = nil
    }

    /// The compiled profile, built at most once until something invalidates it.
    ///
    /// Never rebuilt per utterance. The owner is waiting on the thing that
    /// calls this — a rebuild in the middle of "what did I say about the
    /// pricing page" is latency added to the one moment it is least affordable.
    public func profile() async -> DictationProfile {
        if let cached { return cached }
        let texts = await source?() ?? []
        let built = ProfileMemoryCompiler.enrich(
            DictationProfile(),
            with: SageDictationVocabulary.memories(fromRemembered: texts)
        )
        cached = built
        return built
    }

    /// Throws the cached profile away.
    ///
    /// Deliberately explicit rather than time-based. The profile changes when
    /// the owner's memories change, and the two moments that actually matter
    /// are both events somebody can call this from: a correction being stored,
    /// and Mynah gaining the ability to read its memories at all — which on
    /// this machine has not happened yet and will be the difference between an
    /// empty profile and a full one.
    ///
    /// A timer would be the lazy alternative and would be wrong in both
    /// directions: rebuilding hourly for a corpus that has not changed, and
    /// still being an hour stale after the change that mattered.
    public func invalidate() {
        cached = nil
    }

    /// Applies the profile's repairs to a transcript, **without ever waiting
    /// for one to be built**.
    ///
    /// The whole feature, from the caller's side, and the guarantee matters
    /// more than the repair: the owner is holding a button and waiting on these
    /// words. If the profile is not ready this returns the transcript unchanged
    /// and builds one in the background for next time. A voice note that waits
    /// on a memory query is worse than one that misspells a name — the
    /// misspelling is visible in the composer and fixable in a second, and the
    /// wait is neither.
    ///
    /// With no memories this is the identity function — same latency, same
    /// output, no error — which is the state on the owner's machine today.
    public func repair(_ transcript: String) -> String {
        guard let cached else {
            buildInBackground()
            return transcript
        }
        guard !cached.vocabulary.isEmpty || !cached.confusions.isEmpty else { return transcript }
        return CorrectionEngine(profile: cached).apply(to: transcript)
    }

    /// Builds the profile off the critical path, at most one build at a time.
    ///
    /// Idempotent by design rather than by luck: a second press while the first
    /// build is in flight must not start a second recall. Under mask 30 recall
    /// is refused, so without this guard every utterance would fire a request
    /// that fails — a retry storm generated by the owner speaking.
    public func warmUp() {
        buildInBackground()
    }

    private var building: Task<Void, Never>?

    private func buildInBackground() {
        guard cached == nil, building == nil, source != nil else { return }
        building = Task { [weak self] in
            _ = await self?.profile()
            await self?.finishedBuilding()
        }
    }

    private func finishedBuilding() {
        building = nil
    }
}
