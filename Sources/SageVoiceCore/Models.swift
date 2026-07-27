import Foundation

public enum AppProfile: String, Codable, Sendable {
    case messaging
    case email
    case notes
    case codeEditor
    case browser
    case balanced
}

public struct AppContext: Codable, Equatable, Sendable {
    public var appName: String
    public var bundleIdentifier: String?
    public var processIdentifier: Int32?
    public var windowTitle: String?
    public var selectedText: String?
    public var nearbyText: String?
    public var profile: AppProfile
    public var isSecureInput: Bool

    public init(
        appName: String,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        windowTitle: String? = nil,
        selectedText: String? = nil,
        nearbyText: String? = nil,
        profile: AppProfile = .balanced,
        isSecureInput: Bool = false
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
        self.selectedText = selectedText
        self.nearbyText = nearbyText
        self.profile = profile
        self.isSecureInput = isSecureInput
    }
}

public struct VocabularyEntry: Codable, Equatable, Sendable {
    public var term: String
    public var spokenForms: [String]
    public var preferredSpelling: String
    public var category: String
    public var confidenceBoost: Double

    public init(
        term: String,
        spokenForms: [String],
        preferredSpelling: String,
        category: String,
        confidenceBoost: Double
    ) {
        self.term = term
        self.spokenForms = spokenForms
        self.preferredSpelling = preferredSpelling
        self.category = category
        self.confidenceBoost = confidenceBoost
    }
}

public struct ASRConfusion: Codable, Equatable, Sendable {
    public var heard: String
    public var corrected: String
    public var contextTerms: [String]
    public var confidence: Double

    public init(heard: String, corrected: String, contextTerms: [String] = [], confidence: Double = 1.0) {
        self.heard = heard
        self.corrected = corrected
        self.contextTerms = contextTerms
        self.confidence = confidence
    }
}

public enum SpellingPreference: String, Codable, Equatable, Sendable, CaseIterable {
    case system
    case british
    case american
}

public struct DictationProfile: Codable, Equatable, Sendable {
    public var language: String
    public var speechRateWPM: Int
    public var pauseThresholdMS: Int
    public var vadSensitivity: Double
    public var activeASRBackend: String
    public var activeEditorModel: String
    public var spellingPreference: SpellingPreference
    public var profanityFilterEnabled: Bool
    public var vocabulary: [VocabularyEntry]
    public var confusions: [ASRConfusion]

    private enum CodingKeys: String, CodingKey {
        case language
        case speechRateWPM
        case pauseThresholdMS
        case vadSensitivity
        case activeASRBackend
        case activeEditorModel
        case spellingPreference
        case profanityFilterEnabled
        case vocabulary
        case confusions
    }

    public init(
        language: String = "en",
        speechRateWPM: Int = 148,
        pauseThresholdMS: Int = 420,
        vadSensitivity: Double = 0.63,
        activeASRBackend: String = "stub",
        activeEditorModel: String = "ollama-local",
        spellingPreference: SpellingPreference = .system,
        profanityFilterEnabled: Bool = true,
        vocabulary: [VocabularyEntry] = [],
        confusions: [ASRConfusion] = []
    ) {
        self.language = language
        self.speechRateWPM = speechRateWPM
        self.pauseThresholdMS = pauseThresholdMS
        self.vadSensitivity = vadSensitivity
        self.activeASRBackend = activeASRBackend
        self.activeEditorModel = activeEditorModel
        self.spellingPreference = spellingPreference
        self.profanityFilterEnabled = profanityFilterEnabled
        self.vocabulary = vocabulary
        self.confusions = confusions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.language = try container.decodeIfPresent(String.self, forKey: .language) ?? "en"
        self.speechRateWPM = try container.decodeIfPresent(Int.self, forKey: .speechRateWPM) ?? 148
        self.pauseThresholdMS = try container.decodeIfPresent(Int.self, forKey: .pauseThresholdMS) ?? 420
        self.vadSensitivity = try container.decodeIfPresent(Double.self, forKey: .vadSensitivity) ?? 0.63
        self.activeASRBackend = try container.decodeIfPresent(String.self, forKey: .activeASRBackend) ?? "stub"
        self.activeEditorModel = try container.decodeIfPresent(String.self, forKey: .activeEditorModel) ?? "ollama-local"
        self.spellingPreference = try container.decodeIfPresent(SpellingPreference.self, forKey: .spellingPreference) ?? .system
        self.profanityFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .profanityFilterEnabled) ?? true
        self.vocabulary = try container.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? []
        self.confusions = try container.decodeIfPresent([ASRConfusion].self, forKey: .confusions) ?? []
    }

    public static let development = DictationProfile(
        vocabulary: [
            VocabularyEntry(term: "SAGE", spokenForms: ["sage"], preferredSpelling: "SAGE", category: "technical_term", confidenceBoost: 0.95),
            VocabularyEntry(term: "CometBFT", spokenForms: ["comet bft", "comet bee eff tee", "comet b f t"], preferredSpelling: "CometBFT", category: "technical_term", confidenceBoost: 0.95),
            VocabularyEntry(term: "Ollama", spokenForms: ["ollama", "all llama", "ulama", "ullama"], preferredSpelling: "Ollama", category: "technical_term", confidenceBoost: 0.92),
            VocabularyEntry(term: "Utimaco", spokenForms: ["utimaco", "ultimate go"], preferredSpelling: "Utimaco", category: "technical_term", confidenceBoost: 0.92),
            VocabularyEntry(term: "CSe100", spokenForms: ["cse100", "see as e one hundred"], preferredSpelling: "CSe100", category: "technical_term", confidenceBoost: 0.92),
            VocabularyEntry(term: "Ed25519", spokenForms: ["ed25519", "ed twenty five five nineteen"], preferredSpelling: "Ed25519", category: "technical_term", confidenceBoost: 0.92),
            VocabularyEntry(term: "OpenRouter", spokenForms: ["openrouter", "open router", "open and author"], preferredSpelling: "OpenRouter", category: "technical_term", confidenceBoost: 0.92)
        ],
        confusions: [
            ASRConfusion(heard: "ultimate go", corrected: "Utimaco", contextTerms: ["HSM", "security", "hardware"], confidence: 0.9),
            ASRConfusion(heard: "see as e one hundred", corrected: "CSe100", contextTerms: ["Utimaco", "HSM"], confidence: 0.9),
            ASRConfusion(heard: "ed twenty five five nineteen", corrected: "Ed25519", contextTerms: ["cryptography", "signature", "HSM"], confidence: 0.9)
        ]
    )
}

public struct StableSegment: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var isFinal: Bool

    public init(text: String, confidence: Double = 1.0, isFinal: Bool = false) {
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
    }
}

public struct EditorRequest: Codable, Equatable, Sendable {
    public var stableText: String
    public var unstableTail: String
    public var rollingPolishedText: String
    public var appContext: AppContext
    public var profile: DictationProfile
    public var isFinal: Bool

    public init(
        stableText: String,
        unstableTail: String = "",
        rollingPolishedText: String = "",
        appContext: AppContext,
        profile: DictationProfile,
        isFinal: Bool
    ) {
        self.stableText = stableText
        self.unstableTail = unstableTail
        self.rollingPolishedText = rollingPolishedText
        self.appContext = appContext
        self.profile = profile
        self.isFinal = isFinal
    }
}

public struct EditorResult: Codable, Equatable, Sendable {
    public var text: String
    public var latencyMS: Int

    public init(text: String, latencyMS: Int = 0) {
        self.text = text
        self.latencyMS = latencyMS
    }
}
