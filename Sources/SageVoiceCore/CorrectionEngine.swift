import Foundation

public struct CorrectionEngine: Sendable {
    private let profile: DictationProfile

    public init(profile: DictationProfile) {
        self.profile = profile
    }

    public func apply(to transcript: String) -> String {
        var corrected = transcript

        for confusion in profile.confusions.sorted(by: { $0.heard.count > $1.heard.count }) {
            guard !isUnsafeButBroRewrite(from: confusion.heard, to: confusion.corrected) else {
                continue
            }
            corrected = replacePhrase(confusion.heard, with: confusion.corrected, in: corrected)
        }

        // A reviewed casing correction such as "AMy" -> "Amy" is strong
        // evidence that the token is a name. Whisper can subsequently render
        // the same short name as another all-caps variant (for example "AME").
        // Repair only one-character, equal-length all-caps variants learned
        // from an anomalously-cased source; ordinary lowercase words are never
        // fuzzy-matched.
        for confusion in profile.confusions where isReviewedNameCasing(confusion) {
            corrected = replaceNearbyUppercaseVariant(
                of: confusion.heard,
                with: confusion.corrected,
                in: corrected
            )
        }

        for entry in profile.vocabulary {
            for spokenForm in entry.spokenForms.sorted(by: { $0.count > $1.count }) {
                guard !isUnsafeButBroRewrite(from: spokenForm, to: entry.preferredSpelling) else {
                    continue
                }
                corrected = replacePhrase(spokenForm, with: entry.preferredSpelling, in: corrected)
            }
        }

        return corrected
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "but" and "bro" are both common, intentional words. A transcript
    /// review can safely teach contextual repairs, but a global one-token
    /// memory in either direction corrupts genuine speech throughout every
    /// app. Leave this ambiguous pair to the grammar-aware semantic repair.
    private func isUnsafeButBroRewrite(from source: String, to replacement: String) -> Bool {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (source == "but" && replacement == "bro")
            || (source == "bro" && replacement == "but")
    }

    private func replacePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: #"\ "#, with: #"\s+"#)
        guard !escaped.isEmpty else {
            return text
        }
        return text.replacingOccurrences(
            of: #"(?<![A-Za-z0-9])\#(escaped)(?![A-Za-z0-9])"#,
            with: replacement,
            options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]
        )
    }

    private func isReviewedNameCasing(_ confusion: ASRConfusion) -> Bool {
        let heard = confusion.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = confusion.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.contains(where: { $0.isWhitespace }),
              heard.count >= 3,
              heard.count == corrected.count,
              heard.caseInsensitiveCompare(corrected) == .orderedSame,
              heard != corrected,
              corrected.first?.isUppercase == true,
              corrected.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) else {
            return false
        }
        return heard.dropFirst().contains(where: { $0.isUppercase })
    }

    private func replaceNearbyUppercaseVariant(of heard: String, with replacement: String, in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[A-Za-z]+(?![A-Za-z0-9])"#) else {
            return text
        }

        let mutable = NSMutableString(string: text)
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        for match in matches.reversed() {
            let candidate = mutable.substring(with: match.range)
            guard candidate.count == heard.count,
                  candidate == candidate.uppercased(),
                  candidate != candidate.lowercased(),
                  singleCharacterDifference(candidate.lowercased(), heard.lowercased()) else {
                continue
            }
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    private func singleCharacterDifference(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).reduce(0) { count, pair in
            count + (pair.0 == pair.1 ? 0 : 1)
        } == 1
    }
}
