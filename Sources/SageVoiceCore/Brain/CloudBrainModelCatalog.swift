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
        // Cost-optimised and frontier: $0.20/$1.20 against $10/$50. Read off
        // the model pages on 2026-09-13, both listing `text, image` as their
        // input modalities.
        //
        // **The pro end moved from `gpt-5.6-sol` to `gpt-6-astra`** when the
        // 2026-09-13 sweep of every provider's own catalogue found a newer
        // frontier model. Astra is "our most capable model, built for the
        // hardest end-to-end work", which is the sentence the Careful row
        // exists to offer. Sol is kept in `visionModels` below rather than
        // deleted, because an owner stored on it should keep their eyes.
        //
        // `gpt-5.6-terra` ($2/$12) sits between them and is still left out — a
        // third option is the choice the owner cannot make.
        "openai": Pick(fast: "gpt-5.6-luna", pro: "gpt-6-astra"),
        // $0.14/$0.28 uncached against $0.435/$0.87, an order of magnitude
        // cheaper than the rest at both ends. Not "deepseek-chat": that alias
        // was retired on 2026-07-24, which is the drift this type was written
        // to make impossible.
        //
        // **`deepseek-flash` is the name, and the difference from
        // `deepseek-v4-flash` is not cosmetic.** DeepSeek's own Models & Pricing
        // page, read 2026-09-13, lists exactly two models — `deepseek-flash`
        // (DeepSeek-V4.1-Flash) and `deepseek-v4-pro` — and prints one feature
        // row that separates them for this product: **Vision ✓ for the flash
        // model, "Not supported" for the pro one.** The retired
        // `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` names still
        // resolve, and both are served by the current Flash model, which is why
        // they stay in `visionModels` below rather than being deleted: an owner
        // whose stored choice names one of them should get vision, not a
        // migration prompt.
        //
        // The consequence is stated rather than hidden: **on DeepSeek, Careful
        // cannot see a picture.** That is the vendor's split, not ours.
        "deepseek": Pick(fast: "deepseek-flash", pro: "deepseek-v4-pro"),

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
        // fast one. Do not "fix" this to a `-pro` from the 3.x family either:
        // Google's models page marks *Gemini 3.1 Pro* as a preview, and a
        // preview id has no business in a shipped appliance — which is why the
        // pro row is still the last stable Pro, `gemini-2.5-pro`.
        //
        // The fast row moved from `gemini-3.6-flash` to `gemini-3.8-flash` in
        // the 2026-09-13 sweep: "Our most intelligent Flash model… New Stable",
        // with 3.7 and 3.6 described as previous-generation. Nothing about this
        // appliance was wrong on 3.6; it was simply two releases behind.
        "gemini": Pick(fast: "gemini-3.8-flash", pro: "gemini-2.5-pro")
    ]

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

    // MARK: - Which of these models can be sent a picture

    /// The models that accept an image on the wire, by provider.
    ///
    /// ## Why this is a table and not a guess
    ///
    /// `BrainCapabilities.hosted.mayCarryImages` says a hosted brain *may* be
    /// sent one. It cannot say which. That distinction is a fact about a model,
    /// and it is not uniform even inside one provider: DeepSeek's flash model
    /// takes images and its pro model does not, so "DeepSeek supports vision" is
    /// false the moment the owner switches tier.
    ///
    /// **A model that is not in this table reads as blind**, which is the
    /// direction the whole attachment path is built around — see
    /// `BrainBackend.seesImages`. Being wrong here in the pessimistic direction
    /// costs the owner a sentence ("kept it but can't look at it"); being wrong
    /// in the optimistic direction puts an image block on the wire for a model
    /// that cannot parse it, and the turn dies as a 400 or, worse, succeeds with
    /// a model that never looked.
    ///
    /// ## Provenance, all read on 2026-09-13
    ///
    /// - **DeepSeek** — Models & Pricing carries a `Vision` row: ✓ for
    ///   `deepseek-flash`, "Not supported" for `deepseek-v4-pro`. The Vision
    ///   guide names the accepted formats (JPEG, PNG, GIF, WebP) and the
    ///   `image_url` shape this backend already speaks.
    /// - **Anthropic** — every current model (Fable 5.1, Opus 5, Sonnet 5,
    ///   Haiku 4.5) takes images; the docs have a dedicated *Images and vision*
    ///   section.
    /// - **OpenAI** — the model pages for `gpt-5.6-luna`, `gpt-5.6-sol` and
    ///   `gpt-6-astra` each list `Input modalities: text, image`, and image
    ///   input is a first-class guide under *Multimodal*.
    /// - **Google** — every Gemini model takes image input; the models page
    ///   lists `gemini-3.8-flash` and `gemini-2.5-pro`.
    /// - **Moonshot** — the Chat Completions reference documents multimodal
    ///   `content` with `image_url` and `video_url` parts for Kimi.
    /// - **Groq** — absent on purpose. Its two picks are LLaMA 3.1 and 3.3 text
    ///   models, and it is not offered in setup anyway.
    ///
    /// The retired DeepSeek aliases stay listed because DeepSeek still accepts
    /// them and serves them from the current Flash model. Deleting them would
    /// take vision away from every owner who set their brain up before this
    /// release, which is the one group the table is here to serve.
    private static let visionModels: [String: Set<String>] = [
        "anthropic": ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5"],
        // `gpt-5.6-sol` stays listed though it is no longer offered: an owner
        // stored on it when it was the Careful row must not lose the ability to
        // send a photo as the side effect of a catalogue refresh.
        "openai": ["gpt-5.6-luna", "gpt-6-astra", "gpt-5.6-sol"],
        "gemini": ["gemini-3.8-flash", "gemini-2.5-pro"],
        "moonshot": ["kimi-k2.6", "kimi-k3"],
        "deepseek": [
            "deepseek-flash",
            // Retired, still accepted, served by the model above.
            "deepseek-v4-flash",
            "deepseek-v4-flash-vision-exp"
        ]
    ]

    /// Whether `model` can be sent an image by `identifier`'s backend.
    ///
    /// `false` for anything unknown, including a provider that is not in the
    /// table at all. See `visionModels` for why the default is the pessimistic
    /// one.
    public static func seesImages(model: String, forProvider identifier: String) -> Bool {
        visionModels[identifier]?.contains(model) ?? false
    }

    /// Whether either of a provider's two picks can see.
    ///
    /// For the screens that have to say something before a model is chosen —
    /// "so it can read a picture you send it" is a reason to pick one provider
    /// over another, and it is invisible in a list of ids.
    public static func anyModelSeesImages(forProvider identifier: String) -> Bool {
        guard let pick = picks[identifier] else { return false }
        return pick.both.contains { seesImages(model: $0, forProvider: identifier) }
    }

    /// Whether one tier of one provider can be sent a picture.
    public static func tierSeesImages(
        forProvider identifier: String,
        tier: Tier
    ) -> Bool {
        guard let pick = picks[identifier] else { return false }
        return seesImages(model: pick.model(tier), forProvider: identifier)
    }

    /// Providers whose *default* pick — the Quick one, what an owner gets
    /// without choosing — accepts an image. Sorted.
    public static var providersWhoseQuickModelSeesImages: [String] {
        providersWithAPick.filter { tierSeesImages(forProvider: $0, tier: defaultTier) }
    }

    /// One line for a model picker row saying whether this model can look at a
    /// picture the owner sends it, or `nil` where there is nothing to add.
    ///
    /// **Exists because the two rows can differ about this, and DeepSeek's now
    /// do.** Its Quick model takes images and its Careful model does not, so an
    /// owner who reaches for the better answer loses a capability they had a
    /// minute ago — silently, until the next time they send a photograph of
    /// something and are told it was kept but not looked at. Two rows that
    /// differ in exactly one way and say nothing about it is the shape of
    /// surprise this product keeps paying for.
    ///
    /// `nil` when neither of a provider's models can see: a provider-wide
    /// absence is a fact about DeepSeek on the pro tier only, and printing
    /// "cannot read pictures" on both rows of a provider whose whole line is
    /// blind would be true twice and useful never.
    public static func pictureNote(forProvider identifier: String, tier: Tier) -> String? {
        guard anyModelSeesImages(forProvider: identifier) else { return nil }
        return tierSeesImages(forProvider: identifier, tier: tier)
            ? "Can read a picture you send it."
            : "Can't read pictures — Quick can."
    }
}
