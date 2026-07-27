import Foundation

/// Getting a working API key out of a person who has never seen one.
///
/// This is the shipping default for cloud brains, chosen over one-click Google
/// sign-in for reasons that are policy rather than engineering: `cloud-platform`
/// is a sensitive scope, so an unverified app's refresh tokens expire after
/// exactly 7 days — an appliance that works for a week and then silently stops,
/// on a machine nobody is sitting at. Verification takes weeks. Pasting a key
/// takes two clicks and works the day we ship.
public enum APIKeyOnboarding {

    /// What the owner is told, and where to send them.
    public struct Instructions: Sendable, Equatable {
        public let providerName: String
        /// Deep link straight to the key page, not to a marketing homepage.
        /// Every extra navigation step is somewhere to get lost.
        public let keyPageURL: URL
        public let steps: [String]
        /// Shown under the field, so the owner can tell at a glance whether they
        /// pasted the right kind of string.
        public let looksLikeHint: String
        /// Set when the provider's free tier is the reason we recommend it.
        public let costNote: String?

        public init(
            providerName: String,
            keyPageURL: URL,
            steps: [String],
            looksLikeHint: String,
            costNote: String? = nil
        ) {
            self.providerName = providerName
            self.keyPageURL = keyPageURL
            self.steps = steps
            self.looksLikeHint = looksLikeHint
            self.costNote = costNote
        }
    }

    public static let gemini = Instructions(
        providerName: "Google Gemini",
        keyPageURL: URL(string: "https://aistudio.google.com/apikey")!,
        steps: [
            "Open Google AI Studio. You'll sign in with your normal Google account.",
            "Click “Create API key”.",
            "Copy the key it shows you, and paste it below.",
            "Keep it to yourself — anyone with this key can use your Gemini allowance."
        ],
        looksLikeHint: "It starts with AIza and is about 39 characters long.",
        costNote: "Gemini has a free allowance that's generous for one person. You won't be asked for a card."
    )

    public static let openAI = Instructions(
        providerName: "OpenAI",
        keyPageURL: URL(string: "https://platform.openai.com/api-keys")!,
        steps: [
            "Open the OpenAI API keys page and sign in.",
            "Click “Create new secret key”.",
            "Copy it straight away — OpenAI only shows it once.",
            "Paste it below."
        ],
        looksLikeHint: "It starts with sk- and is a long string of letters and numbers.",
        costNote: "OpenAI charges per use and needs a card on file."
    )

    public static let anthropic = Instructions(
        providerName: "Anthropic",
        keyPageURL: URL(string: "https://console.anthropic.com/settings/keys")!,
        steps: [
            "Open the Anthropic console and sign in.",
            "Go to API keys and create one.",
            "Copy it and paste it below."
        ],
        looksLikeHint: "It starts with sk-ant- and is a long string.",
        costNote: "Anthropic charges per use and needs a card on file."
    )

    public static let deepSeek = Instructions(
        providerName: "DeepSeek",
        keyPageURL: URL(string: "https://platform.deepseek.com/api_keys")!,
        steps: [
            "Open the DeepSeek platform and sign in.",
            "Go to API keys and create one.",
            "Copy it and paste it below — DeepSeek only shows it once."
        ],
        looksLikeHint: "It starts with sk- and is a long string of letters and numbers.",
        costNote: "DeepSeek charges per use and needs credit on the account. It's cheap, but it isn't free."
    )

    public static let groq = Instructions(
        providerName: "Groq",
        keyPageURL: URL(string: "https://console.groq.com/keys")!,
        steps: [
            "Open the Groq console and sign in.",
            "Create an API key.",
            "Copy it and paste it below."
        ],
        looksLikeHint: "It starts with gsk_ and is a long string.",
        costNote: "Groq has a free allowance with tight per-minute limits."
    )

    public static let moonshot = Instructions(
        providerName: "Kimi",
        keyPageURL: URL(string: "https://platform.moonshot.ai/console/api-keys")!,
        steps: [
            "Open the Moonshot console and sign in. Kimi is made by Moonshot AI.",
            "Create an API key.",
            "Copy it and paste it below."
        ],
        looksLikeHint: "It starts with sk- and is a long string.",
        costNote: "Kimi charges per use and needs credit on the account."
    )

    /// Every provider `makeBackend` can build must appear here.
    ///
    /// The gap this closes was silent and user-facing: `deepseek` was a working
    /// backend with no instructions, so the setup command answered "no key
    /// instructions for provider 'deepseek'" for a provider the product
    /// genuinely supports. A test now asserts the two lists agree.
    public static func instructions(forProvider identifier: String) -> Instructions? {
        switch identifier {
        case "gemini":           return gemini
        case "openai":           return openAI
        case "anthropic":        return anthropic
        case "deepseek":         return deepSeek
        case "groq":             return groq
        case "moonshot", "kimi": return moonshot
        default:                 return nil
        }
    }

    /// Providers that need a pasted key, and therefore need instructions.
    /// Local backends are absent on purpose: they need nothing pasted.
    public static let keyedProviders = ["gemini", "openai", "anthropic", "deepseek", "groq", "moonshot"]

    // MARK: - Shape check

    /// A cheap, offline sanity check on what was pasted.
    ///
    /// Not validation — it cannot tell a revoked key from a live one. It exists
    /// to catch the mistakes that happen before the network is involved: a
    /// pasted URL, a whole `export GEMINI_API_KEY=…` line, the placeholder text
    /// from a tutorial, or an OpenAI key in the Gemini field.
    public enum ShapeProblem: Equatable, Sendable {
        case empty
        case looksLikeAnEnvironmentLine
        case looksLikeAURL
        case wrongProvider(guessed: String)

        public var spokenDescription: String {
            switch self {
            case .empty:
                return "That field is empty."
            case .looksLikeAnEnvironmentLine:
                return "That looks like a whole command. Paste just the key — the part after the equals sign."
            case .looksLikeAURL:
                return "That looks like a web address, not a key."
            case .wrongProvider(let guessed):
                return "That looks like \(guessed) key, not this one."
            }
        }
    }

    public static func shapeProblem(of raw: String, expecting provider: String) -> ShapeProblem? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .empty }
        if key.contains("=") && key.uppercased().contains("KEY") { return .looksLikeAnEnvironmentLine }
        if key.hasPrefix("http://") || key.hasPrefix("https://") { return .looksLikeAURL }

        switch provider {
        case "gemini":
            if key.hasPrefix("sk-ant-") { return .wrongProvider(guessed: "an Anthropic") }
            if key.hasPrefix("sk-") { return .wrongProvider(guessed: "an OpenAI") }
        case "openai":
            if key.hasPrefix("AIza") { return .wrongProvider(guessed: "a Google") }
            if key.hasPrefix("sk-ant-") { return .wrongProvider(guessed: "an Anthropic") }
        case "anthropic":
            if key.hasPrefix("AIza") { return .wrongProvider(guessed: "a Google") }
        default:
            break
        }
        return nil
    }

    /// Strips what people actually paste: surrounding quotes, a stray `Bearer`,
    /// and whitespace from a line-wrapped copy.
    public static func normalise(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7))
        }
        if key.count >= 2, let first = key.first, let last = key.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            key = String(key.dropFirst().dropLast())
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Real validation

/// Proves a key works by doing what a real turn does.
///
/// This exists because the obvious cheap check is a trap this codebase already
/// fell into. `AnthropicBackend.isAvailable()` passed while every real turn
/// failed, because availability sent `temperature: nil` and real requests sent
/// `0`, which Opus 4.7+ rejects outright. Setup said "you're all set" and the
/// appliance broke on the owner's first sentence.
///
/// So validation sends a request shaped like the ones that matter: the same
/// temperature, a tool attached, and a reply expected. If tool calling is broken
/// for this key or model, the owner finds out here rather than mid-conversation.
public struct BrainKeyValidator: Sendable {

    public enum Verdict: Sendable, Equatable {
        case works(modelName: String)
        /// Reached the provider, which rejected the key.
        case rejected(String)
        /// Key accepted, but the model cannot do what this product needs.
        case unusable(String)
        case unreachable(String)

        public var isUsable: Bool {
            if case .works = self { return true }
            return false
        }

        /// What the owner reads. Names the fix, not the failure.
        public var spokenDescription: String {
            switch self {
            case .works(let model):
                return "That works — you're connected to \(model)."
            case .rejected(let detail):
                return "That key was refused. \(detail)"
            case .unusable(let detail):
                return "The key works, but this model can't run the assistant. \(detail)"
            case .unreachable:
                return "I couldn't reach the provider. Check this Mac's internet connection."
            }
        }
    }

    private let probeTool = MCPTool(
        name: "get_time",
        description: "Returns the current time. Call this to answer what time it is.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
    )

    public init() {}

    public func validate(_ backend: BrainBackend, temperature: Double? = 0) async -> Verdict {
        let request = BrainRequest(
            messages: [
                .system("You are a helpful assistant. Use tools when they fit."),
                .user("What time is it? Use the tool.")
            ],
            tools: [probeTool.brainTool],
            // The exact value real turns send. Sending nil here is precisely the
            // bug this type exists to prevent.
            temperature: temperature,
            maxOutputTokens: 256,
            reasoning: .disabled
        )

        do {
            let reply = try await backend.complete(request)
            let toolCalls = reply.message.toolCalls
            guard !toolCalls.isEmpty || !reply.message.content.isEmpty else {
                return .unusable("It answered with nothing at all.")
            }
            if toolCalls.isEmpty {
                // Not fatal — the model may simply have answered — but worth
                // saying, because this product is almost entirely tool calls.
                return .unusable(
                    "It replied but ignored the tool it was given, so it probably can't drive the assistant's actions."
                )
            }
            // The model that actually served the request, which is not always
            // the one asked for — providers alias and reroute, and the owner
            // should see what they really got.
            return .works(modelName: reply.model.isEmpty ? backend.modelName : reply.model)
        } catch let error as BrainBackendError {
            return Self.classify(error)
        } catch {
            return .unreachable("\(error)")
        }
    }

    /// `BrainBackendError` is already structured, so this switches on it rather
    /// than pattern-matching its description. Matching on rendered text is how
    /// a reworded error message silently becomes an unhelpful diagnosis.
    static func classify(_ error: BrainBackendError) -> Verdict {
        switch error {
        case .unauthorized:
            return .rejected("Check you copied the whole thing, and that it hasn't been deleted.")
        case .missingCredential:
            return .rejected("No key was supplied.")
        case .rateLimited(_, let retryAfterSeconds):
            if let seconds = retryAfterSeconds, seconds > 0 {
                return .rejected("You've hit the provider's rate limit. Try again in about \(Int(seconds.rounded())) seconds.")
            }
            return .rejected("You've hit the provider's rate limit. Wait a minute and try again.")
        case .unreachable(let detail):
            return .unreachable(detail)
        case .misconfigured(let detail):
            return .unusable(detail)
        case .badResponse(let status, _):
            switch status {
            case 403:
                return .rejected("The provider accepted the key but refused this model. It may be restricted.")
            case 404:
                return .unusable("That model name isn't available on this account.")
            default:
                // Deliberately not the status code: the owner cannot act on 502.
                return .rejected("The provider refused the request.")
            }
        case .malformedResponse:
            // The key may be fine; the adapter and the provider disagree about
            // the wire format. Blaming the key would send the owner to fix the
            // one thing that is not broken.
            return .unusable("The provider answered in a format this app couldn't read.")
        case .requestRejected(let detail):
            // Where the Anthropic temperature bug would land: the credential is
            // good and the request shape is not.
            return .unusable(detail)
        }
    }
}
