import Foundation

/// The model Mynah picks for each provider — one list, so nothing can drift.
///
/// **This type exists because the two lists it replaces disagreed, under a
/// comment asserting that they agreed.**
///
/// `BrainFactory.defaultModelName` carried the note *"the same defaults the CLI
/// harness uses, so a brain set up in the app and one set up from a terminal
/// answer with the same model"* — and DeepSeek was `deepseek-v4-flash` in the
/// daemon and `deepseek-chat` in the app. The daemon had been corrected when
/// that alias stopped resolving; the app had not, and the comment is what made
/// it look like it had. A sentence claiming two things match is not a mechanism
/// that keeps them matching, and the owner running the app got the dead alias.
///
/// So the reasoning lives in `docs/MODEL-CHOICES.md`, and the strings live here
/// once. There is no second place to update and therefore no second place to
/// forget.
///
/// ## Why these names are allowed to be wrong
///
/// Every id below will eventually be retired by its vendor. That is not a risk
/// to be managed away, it is the guaranteed end state of any hardcoded model
/// name, and three names in this repo had already expired before anyone looked.
///
/// The design accepts it instead: when a pick goes stale, the owner is told at
/// the moment they connect the provider — `BrainAvailability.modelNotOffered`
/// establishes it from the account's own `/v1/models`, and
/// `BrainKeyValidator.Verdict.modelGone` says it plainly and offers another
/// provider rather than a retry that cannot work. Being wrong here costs an
/// explanation, not an outage.
public enum CloudBrainModelCatalog {

    /// What Mynah picks, keyed by `BrainBackend.identifier`.
    ///
    /// Speed first, tool-calling second, price third — see
    /// `docs/MODEL-CHOICES.md` for why that order and what each pick cost.
    /// Being in this table is **not** the same as being offered in setup: a
    /// provider must also have been measured. `BrainSetupPlanner` decides that;
    /// this only decides what to ask for once something has decided to connect.
    private static let picks: [String: String] = [
        // Fast tier, full tool use, $1/$5 against Sonnet 5's $3/$15.
        "anthropic": "claude-haiku-4-5",
        // Cost-optimised tier of the current frontier family, $1/$6.
        "openai": "gpt-5.6-luna",
        // $0.14/$0.28 uncached and an order of magnitude cheaper than the rest.
        // Not "deepseek-chat": that alias stopped resolving, which is the drift
        // this type was written to make impossible.
        "deepseek": "deepseek-v4-flash",
        // Named but NOT offered in setup — 560 tok/s is Groq's claim, not our
        // measurement. Present so that a stored choice still builds.
        "groq": "llama-3.1-8b-instant",

        // Below here: providers not offered in setup, kept only so an owner's
        // stored choice from an older build still resolves to something rather
        // than to nothing. Removing an offer is not removing an identity.
        //
        // These are the repo's historical values, deliberately left as they
        // were. `kimi-k2-0905-preview` is deprecated upstream and there is no
        // confident replacement yet — a conversational pick for Kimi is still
        // open, and guessing one here would put an unverified string next to
        // four verified ones with nothing to tell them apart.
        "moonshot": "kimi-k2-0905-preview",
        "gemini": "gemini-3.6-flash"
    ]

    /// The pick for a provider, or `nil` when this product has not chosen one.
    ///
    /// `nil` rather than a plausible fallback on purpose. A default string here
    /// would be sent to a real provider on the owner's real key and fail as a
    /// model that does not exist — which is indistinguishable, from the outside,
    /// from the appliance being broken. Not choosing is a state worth
    /// representing.
    public static func model(forProvider identifier: String) -> String? {
        picks[identifier]
    }

    /// Providers this product has a pick for. Sorted so it is stable to assert on.
    public static var providersWithAPick: [String] {
        picks.keys.sorted()
    }
}
