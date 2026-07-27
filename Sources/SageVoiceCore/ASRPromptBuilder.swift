import Foundation

public struct ASRPromptBuilder: Sendable {
    public var maxVocabularyTerms: Int
    public var maxCorrectionPairs: Int

    public init(maxVocabularyTerms: Int = 8, maxCorrectionPairs: Int = 0) {
        self.maxVocabularyTerms = maxVocabularyTerms
        self.maxCorrectionPairs = maxCorrectionPairs
    }

    public func prompt(for profile: DictationProfile, appName: String? = nil) -> String {
        let vocabulary = preferredSpellings(from: profile.vocabulary)
        let corrections = correctionPairs(from: profile.confusions)
        var parts: [String] = []

        if !vocabulary.isEmpty {
            parts.append("Vocabulary: \(vocabulary.joined(separator: ", ")).")
        }

        if !corrections.isEmpty {
            parts.append("Corrections: \(corrections.joined(separator: "; ")).")
        }

        parts.append("Preserve exact names, acronyms, and numbers.")
        return parts.joined(separator: " ")
    }

    /// Keep production transcription unprompted. The vocabulary prompt
    /// added material release-to-text latency without changing retained-corpus
    /// output. Deterministic local vocabulary repair still runs after ASR.
    public func productionOptions() -> AudioTranscriptionOptions {
        .none
    }

    private func preferredSpellings(from entries: [VocabularyEntry]) -> [String] {
        guard maxVocabularyTerms > 0 else {
            return []
        }

        var seen: Set<String> = []
        var result: [String] = []

        for entry in entries.sorted(by: { $0.confidenceBoost > $1.confidenceBoost }) {
            let spelling = entry.preferredSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = spelling.lowercased()
            guard !spelling.isEmpty, !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(spelling)
            if result.count >= maxVocabularyTerms {
                break
            }
        }

        return result
    }

    private func correctionPairs(from confusions: [ASRConfusion]) -> [String] {
        guard maxCorrectionPairs > 0 else {
            return []
        }

        var seen: Set<String> = []
        var result: [String] = []

        for confusion in confusions.sorted(by: { $0.confidence > $1.confidence }) {
            let heard = confusion.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = confusion.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(heard.lowercased())->\(corrected.lowercased())"
            guard !heard.isEmpty, !corrected.isEmpty, heard.lowercased() != corrected.lowercased(), !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            result.append("\(heard) -> \(corrected)")
            if result.count >= maxCorrectionPairs {
                break
            }
        }

        return result
    }
}
