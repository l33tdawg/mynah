import Foundation

/// The models Mynah offers for each provider — one list, so nothing can drift.
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
/// ## Two per provider, and the same two shapes everywhere
///
/// Each provider offers exactly a `fast` and a `pro`, because that is the only
/// distinction between models an owner can actually hold an opinion about. They
/// cannot rank nine ids by benchmark, and they should not have to; they can
/// absolutely say *"this answer is worth waiting for"* — which is a judgement
/// about the question in front of them, not about the vendor's catalogue.
///
/// **The pair is enforced by the type rather than by care.** `Pick` has no
/// single-model initialiser, so a provider cannot be added half-specified and
/// then quietly offer one option where every other provider offers two. The
/// previous table held one id per provider and grew a second tier nowhere; a
/// table that merely *ought* to stay uniform is the same class of promise as the
/// comment in the first paragraph.
///
/// `fast` is the default and stays the default. This is an appliance somebody
/// talks to, and `docs/MODEL-CHOICES.md` puts conversational latency first for
/// the reason that a reply arriving after twenty seconds is not a reply. `pro`
/// is a thing the owner reaches for, never a thing they are given.
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

    /// Which of a provider's two models — the distinction the owner is asked to
    /// make, phrased as the thing they are choosing between rather than as the
    /// vendor's tier name.
    public enum Tier: String, Sendable, Codable, CaseIterable, Hashable {
        /// What Mynah uses unless told otherwise.
        case fast
        /// Slower, more expensive, better at a hard question.
        case pro

        /// What the owner is offered. Not the vendor's marketing word: "flash",
        /// "turbo", "sol" and "instant" all mean the same thing to four
        /// different companies and nothing at all to the person choosing.
        public var ownerFacingName: String {
            switch self {
            case .fast: return "Quick"
            case .pro:  return "Careful"
            }
        }

        /// One line under the name, written as the trade the owner is making.
        public var ownerFacingDetail: String {
            switch self {
            case .fast:
                return "Answers in a beat. What Mynah uses for everything unless you change it."
            case .pro:
                return "Thinks longer and costs more. Worth it for a question you'd wait for."
            }
        }
    }

    /// A provider's pair.
    ///
    /// Both ids are required. See the type comment: the uniformity the owner
    /// sees is a property of this initialiser, not of anybody remembering.
    public struct Pick: Sendable, Equatable, Hashable {
        public let fast: String
        public let pro: String

        public init(fast: String, pro: String) {
            self.fast = fast
            self.pro = pro
        }

        public func model(_ tier: Tier) -> String {
            switch tier {
            case .fast: return fast
            case .pro:  return pro
            }
        }

        /// Both ids in the order they are shown, quick first.
        public var both: [String] { [fast, pro] }
    }

    /// What Mynah offers, keyed by `BrainBackend.identifier`.
    ///
    /// Speed first, tool-calling second, price third — see
    /// `docs/MODEL-CHOICES.md` for why that order and what each pick cost.
    /// Being in this table is **not** the same as being offered in setup: a
    /// provider must also have been measured. `BrainSetupPlanner` decides that;
    /// this only decides what to ask for once something has decided to connect.
    ///
    /// Every id below was read off the vendor's own current documentation on
    /// 2026-08-01, not recalled. Two were checked precisely because they looked
    /// obvious and were not:
    ///
    /// - **`gemini-3.6-pro` does not exist.** The convention the other five
    ///   providers follow does not hold for Google: the 3.6 family ships Flash,
    ///   and the newest Pro is `gemini-3.1-pro-preview`. A preview id has no
    ///   business in a shipped appliance, so the pro tier here is the current
    ///   stable `gemini-2.5-pro` — deliberately an older family than its own
    ///   fast tier, which looks like a mistake and is not.
    /// - **Moonshot's fast tier was the deprecated `kimi-k2-0905-preview`.** The
    ///   obvious replacement, `kimi-k2.7-code-highspeed`, is a coding specialist
    ///   and the wrong shape for something you hold a conversation with, so the
    ///   general-purpose `kimi-k2.6` takes it.
    private static let picks: [String: Pick] = [
        // $1/$5 against Sonnet 5's $3/$15, both with full tool use.
        "anthropic": Pick(fast: "claude-haiku-4-5", pro: "claude-sonnet-5"),
        // Cost-optimised and frontier ends of the same family: $0.20/$1.20
        // against $5/$30. `gpt-5.6-terra` sits between them at $2/$12 and is
        // left out — a third option is the choice the owner cannot make.
        "openai": Pick(fast: "gpt-5.6-luna", pro: "gpt-5.6-sol"),
        // $0.14/$0.28 uncached against $0.435/$0.87, an order of magnitude
        // cheaper than the rest at both ends. Not "deepseek-chat": that alias
        // was retired on 2026-07-24, which is the drift this type was written
        // to make impossible.
        "deepseek": Pick(fast: "deepseek-v4-flash", pro: "deepseek-v4-pro"),

        // Below here: providers not offered in setup, kept so an owner's stored
        // choice from an older build still resolves to something rather than to
        // nothing. Removing an offer is not removing an identity.
        //
        // 560 tok/s and 280 tok/s are Groq's published claims, not our
        // measurement — which is exactly why Groq is named and not offered.
        "groq": Pick(fast: "llama-3.1-8b-instant", pro: "llama-3.3-70b-versatile"),
        // `kimi-k3` is the flagship at $3/$15 with documented tool calls.
        "moonshot": Pick(fast: "kimi-k2.6", pro: "kimi-k3"),
        // See the note above on why the pro tier is an older family than the
        // fast one. Do not "fix" this to `gemini-3.6-pro`; it 404s.
        "gemini": Pick(fast: "gemini-3.6-flash", pro: "gemini-2.5-pro")
    ]

    /// The models this product will put a photo on the wire for.
    ///
    /// **A model missing from this set reads as blind, and that is the whole
    /// design.** The two errors are not symmetric. Leaving out a model that can
    /// see costs one lost description and an honest sentence saying the picture
    /// was kept but not looked at. Putting in a model that *cannot* see ships
    /// the fabrication this whole feature exists to end — the owner is told
    /// *"You can see it — say what it is, specifically"* about bytes the model
    /// never received, and gets a confident description of a photo nobody read.
    /// So the fallback is `false`, there is no prefix cleverness, and an id
    /// nobody could confirm stays out.
    ///
    /// **Exact-id match, deliberately.** Vision is a property of the specific
    /// model, not of the family: `gpt-5.6-luna` and `gpt-5.6-sol` both take
    /// images, and a future `gpt-5.6-*` might not. Prefix matching would decide
    /// that question by guessing, in the direction that lies.
    ///
    /// Every id below was read off the vendor's own current documentation on
    /// 2026-08-17, one at a time, exactly as `docs/MODEL-CHOICES.md` requires —
    /// and four ids we offer are **not** here because that reading said no or
    /// said nothing:
    ///
    /// - **`deepseek-v4-flash` / `deepseek-v4-pro`.** DeepSeek's chat-completions
    ///   schema documents text content for user messages and no image part; the
    ///   V4 family exposes no image input on the public API. Both are out
    ///   because the vendor says text-only, not because nobody looked.
    /// - **`llama-3.1-8b-instant` / `llama-3.3-70b-versatile`.** Groq's model
    ///   table lists no image modality for either. Vision on Llama lives in the
    ///   3.2-vision and 4 families, which we do not offer.
    /// - **`gemini-2.5-pro`.** Google's current model page does not state its
    ///   input modalities, and the OpenAI-compatibility guide demonstrates image
    ///   understanding with `gemini-3.6-flash` — so the flash tier is confirmed
    ///   through the exact surface `OpenAICompatBackend` speaks and the pro tier
    ///   is not. An owner on Gemini's Careful tier therefore loses picture
    ///   reading and is told plainly that the photo was not looked at. That is
    ///   the safe direction and it is still a regression; the door out is one
    ///   confirmation away, which is why the id is named here rather than
    ///   silently absent.
    private static let sighted: Set<String> = [
        // Anthropic prices image tokens for Haiku 4.5 by name in its own vision
        // guide, and Sonnet 5 is documented as the first Sonnet-tier model with
        // high-resolution image support (2576 px long edge).
        "claude-haiku-4-5",
        "claude-sonnet-5",
        // Both OpenAI model pages state "Input modalities: text, image".
        "gpt-5.6-luna",
        "gpt-5.6-sol",
        // Moonshot's own "Configure Kimi Vision Models" guide lists both ids and
        // shows base64 image input through the `image_url` part — the exact
        // shape `openAIWireObject` emits.
        "kimi-k2.6",
        "kimi-k3",
        // Google's OpenAI-compatibility guide uses this id for its image
        // understanding example, with a `data:image/jpeg;base64,…` URL.
        "gemini-3.6-flash"
    ]

    /// Whether this product will send a photo to a given hosted model.
    ///
    /// Exact match, `false` for anything unlisted — including the empty string.
    /// See `sighted` for why the fallback is the blind one.
    public static func seesImages(model: String) -> Bool {
        sighted.contains(model)
    }

    /// The sighted ids, sorted so a test can assert on them. Every entry must
    /// also be a model some `Pick` offers — otherwise a typo would sit here
    /// matching nothing, looking like coverage that does not exist.
    public static var sightedModels: [String] { sighted.sorted() }

    /// The tier Mynah uses when nothing has said otherwise.
    public static let defaultTier: Tier = .fast

    /// Both models for a provider, or `nil` when this product has not chosen.
    public static func pick(forProvider identifier: String) -> Pick? {
        picks[identifier]
    }

    /// The default model for a provider, or `nil` when this product has not
    /// chosen one.
    ///
    /// `nil` rather than a plausible fallback on purpose. A default string here
    /// would be sent to a real provider on the owner's real key and fail as a
    /// model that does not exist — which is indistinguishable, from the outside,
    /// from the appliance being broken. Not choosing is a state worth
    /// representing.
    public static func model(forProvider identifier: String) -> String? {
        picks[identifier]?.model(defaultTier)
    }

    /// The model for one tier of a provider.
    public static func model(forProvider identifier: String, tier: Tier) -> String? {
        picks[identifier]?.model(tier)
    }

    /// Both models for a provider in the order they are offered, or empty when
    /// there is nothing to offer. Empty rather than `nil` because the caller is
    /// a picker, and a picker with nothing in it is a list of length zero.
    public static func models(forProvider identifier: String) -> [String] {
        picks[identifier]?.both ?? []
    }

    /// Which tier a stored model name belongs to, or `nil` if it is neither —
    /// which is what a name stored by an older build looks like after a vendor
    /// retires it.
    public static func tier(ofModel model: String, forProvider identifier: String) -> Tier? {
        guard let pick = picks[identifier] else { return nil }
        return Tier.allCases.first { pick.model($0) == model }
    }

    /// Providers this product has picks for. Sorted so it is stable to assert on.
    public static var providersWithAPick: [String] {
        picks.keys.sorted()
    }
}
