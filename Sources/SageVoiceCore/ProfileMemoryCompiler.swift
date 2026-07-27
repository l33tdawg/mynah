import Foundation

public enum ProfileMemoryCompiler {
    public static func enrich(_ profile: DictationProfile, with memories: [DictationMemory]) -> DictationProfile {
        var enriched = profile

        for memory in memories.sorted(by: { $0.confidence > $1.confidence }) {
            switch memory.type {
            case .vocabulary:
                appendVocabulary(from: memory, to: &enriched)
                appendTrainingCorrections(from: memory, to: &enriched)
                applyCadenceHints(from: memory, to: &enriched)
            case .correction:
                appendCorrection(from: memory, to: &enriched)
            case .styleProfile, .formattingPreference:
                applyCadenceHints(from: memory, to: &enriched)
            case .transcriptNote, .voiceNote:
                continue
            }
        }

        enriched.vocabulary = dedupeVocabulary(enriched.vocabulary)
        enriched.confusions = dedupeConfusions(enriched.confusions)
        return enriched
    }

    private static func appendVocabulary(from memory: DictationMemory, to profile: inout DictationProfile) {
        guard let term = memory.payload["term"]
            ?? memory.payload["preferred"]
            ?? memory.payload["preferred_spelling"] else {
            return
        }

        let preferred = memory.payload["preferred"]
            ?? memory.payload["preferred_spelling"]
            ?? term
        let spokenForms = splitForms(memory.payload["spoken_forms"] ?? memory.payload["spoken_forms_json"])
        let generatedForms = generatedSpokenForms(for: preferred)
        let forms = Array(Set((spokenForms + generatedForms + [term]).map(normalizeKey))).filter { !$0.isEmpty }

        profile.vocabulary.append(
            VocabularyEntry(
                term: term,
                spokenForms: forms,
                preferredSpelling: preferred,
                category: memory.payload["category"] ?? "setup_memory",
                confidenceBoost: memory.confidence
            )
        )
    }

    private static func appendCorrection(from memory: DictationMemory, to profile: inout DictationProfile) {
        guard let heard = memory.payload["heard"] ?? memory.payload["raw"],
              let corrected = memory.payload["corrected"] ?? memory.payload["prefer"] else {
            return
        }
        appendConfusion(heard: heard, corrected: corrected, contexts: memory.contexts, confidence: memory.confidence, to: &profile)
        for spokenForm in splitForms(memory.payload["spoken_forms"] ?? memory.payload["spoken_forms_json"]) {
            appendConfusion(heard: spokenForm, corrected: corrected, contexts: memory.contexts, confidence: memory.confidence, to: &profile)
        }
    }

    private static func appendTrainingCorrections(from memory: DictationMemory, to profile: inout DictationProfile) {
        guard let preferred = memory.payload["preferred"] ?? memory.payload["term"] else {
            return
        }

        let knownForms = generatedSpokenForms(for: preferred)
        for form in knownForms where normalizeKey(form) != normalizeKey(preferred) {
            appendConfusion(
                heard: form,
                corrected: preferred,
                contexts: memory.contexts,
                confidence: min(0.98, memory.confidence),
                to: &profile
            )
        }

        appendKnownTrainingCorrections(for: preferred, confidence: memory.confidence, contexts: memory.contexts, to: &profile)
    }

    private static func appendConfusion(
        heard: String,
        corrected: String,
        contexts: [String],
        confidence: Double,
        to profile: inout DictationProfile
    ) {
        let normalizedHeard = normalizeKey(heard)
        let normalizedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHeard.isEmpty, !normalizedCorrected.isEmpty, normalizedHeard != normalizeKey(normalizedCorrected) else {
            return
        }
        profile.confusions.append(
            ASRConfusion(
                heard: normalizedHeard,
                corrected: normalizedCorrected,
                contextTerms: contexts,
                confidence: confidence
            )
        )
    }

    private static func applyCadenceHints(from memory: DictationMemory, to profile: inout DictationProfile) {
        if let value = memory.payload["estimated_wpm"].flatMap(Int.init), value > 40, value < 280 {
            profile.speechRateWPM = value
            profile.pauseThresholdMS = value > 170 ? 330 : value < 115 ? 560 : 420
            profile.vadSensitivity = value > 170 ? 0.56 : 0.63
        }
    }

    private static func splitForms(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else {
            return []
        }
        return value
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split(separator: ",")
            .map { normalizeKey(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func generatedSpokenForms(for term: String) -> [String] {
        let lower = normalizeKey(term)
        var forms = [lower]

        let custom: [String: [String]] = [
            "SAGE": ["sage"],
            "CometBFT": ["comet bft", "comet b f t", "comet bee eff tee", "comet beef tea"],
            "Ollama": ["ollama", "all llama", "oh llama", "ulama", "ullama"],
            "WhisperKit": ["whisper kit"],
            "Utimaco": ["utimaco", "ultimate go"],
            "CSe100": ["cse100", "c s e one hundred", "see as e one hundred"],
            "Ed25519": ["ed25519", "ed twenty five five nineteen", "ed two five five one nine"],
            "Greek yogurt": ["greek yogurt"],
            "dishwashing liquid": ["dishwashing liquid", "dish washing liquid", "plates washing liquid", "make washing liquid"]
        ]
        forms.append(contentsOf: custom[term] ?? [])

        let splitCamel = term
            .replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z])([0-9])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([0-9])([A-Za-z])"#, with: "$1 $2", options: .regularExpression)
        forms.append(normalizeKey(splitCamel))

        return forms
    }

    private static func appendKnownTrainingCorrections(
        for preferred: String,
        confidence: Double,
        contexts: [String],
        to profile: inout DictationProfile
    ) {
        let corrections: [String: [String]] = [
            "3 apples": ["three apples"],
            "2 bananas": ["two bananas"],
            "Ed25519": ["ed twenty five five nineteen", "ed two five five one nine"],
            "CometBFT": ["comet beef tea"],
            "dishwashing liquid": ["dish washing liquid", "plates washing liquid", "make washing liquid"]
        ]

        for heard in corrections[preferred] ?? [] {
            appendConfusion(
                heard: heard,
                corrected: preferred,
                contexts: contexts,
                confidence: min(0.94, confidence),
                to: &profile
            )
        }
    }

    private static func dedupeVocabulary(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var seen: Set<String> = []
        var result: [VocabularyEntry] = []
        for entry in entries.sorted(by: { $0.confidenceBoost > $1.confidenceBoost }) {
            let key = normalizeKey(entry.preferredSpelling)
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(entry)
        }
        return result
    }

    private static func dedupeConfusions(_ entries: [ASRConfusion]) -> [ASRConfusion] {
        var seen: Set<String> = []
        var result: [ASRConfusion] = []
        for entry in entries.sorted(by: {
            if $0.heard.count == $1.heard.count {
                return $0.confidence > $1.confidence
            }
            return $0.heard.count > $1.heard.count
        }) {
            let key = "\(normalizeKey(entry.heard))->\(normalizeKey(entry.corrected))"
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(entry)
        }
        return result
    }

    private static func normalizeKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
