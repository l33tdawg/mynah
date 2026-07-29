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

    /// Supplies remembered text. Returns empty when Mynah cannot read its own
    /// memories, which is the state on the owner's machine today.
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

    /// Applies the profile's repairs to a transcript.
    ///
    /// The whole feature, from the caller's side. With no memories this is the
    /// identity function — same latency, same output, no error — which is the
    /// state on the owner's machine today and has to stay boring.
    public func repair(_ transcript: String) async -> String {
        let profile = await profile()
        guard !profile.vocabulary.isEmpty || !profile.confusions.isEmpty else { return transcript }
        return CorrectionEngine(profile: profile).apply(to: transcript)
    }
}
