import Foundation
import SageVoiceCore

/// What the owner has picked on the "where your words go" sheet, and whether it
/// can be saved.
///
/// **A value type rather than a pile of `@State`, so the rules can be tested.**
/// The decisions here are the ones with consequences — a cloud brain saved
/// without a key is a Mac that stops answering, and a local brain saved with a
/// model that was never downloaded is the same failure wearing different
/// clothes. Both were previously expressed as computed properties on the view,
/// where nothing outside a running SwiftUI render could reach them.
struct BrainProviderChoice: Equatable {

    /// The only distinction on the sheet with consequences.
    enum Destination: String, CaseIterable, Identifiable, Equatable {
        case thisMac
        case cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .thisMac: return "On this Mac"
            case .cloud: return "Cloud"
            }
        }

        var explanation: String {
            switch self {
            case .thisMac:
                return "Your words never leave this Mac. Nothing is billed and it works "
                    + "with the internet off."
            case .cloud:
                return "Faster and stronger, and your words go to the company you pick. "
                    + "You pay them per question."
            }
        }
    }

    var destination: Destination
    var selected: BrainSetupOption?
    var localModel: String?
    /// Typed on the sheet, never read back out of storage — a key already saved
    /// shows as saved rather than as a row of dots that invites editing
    /// something the owner cannot see.
    var typedKey: String = ""

    // MARK: - Starting state

    /// Opens on whichever side he is already on, because this sheet is reached
    /// to adjust far more often than to switch sides.
    init(current: BrainSetupOption?, installedLocalModels: [String]) {
        let isLocal = current?.id.backendPlan == .localOllama
        self.destination = isLocal ? .thisMac : .cloud
        self.selected = current

        // **Only a model that is actually on screen.** The recorded model can
        // be one Ollama no longer has — it was removed, or the record predates
        // a reinstall — and preselecting it would put the dot on a row that
        // does not exist, leaving the sheet looking like nothing is chosen while
        // insisting something is.
        let recorded = current?.modelName
        self.localModel = recorded.flatMap { installedLocalModels.contains($0) ? $0 : nil }
            ?? installedLocalModels.first
    }

    // MARK: - Rules

    /// The option as it would be saved, with the chosen local model folded in,
    /// or `nil` when the selection is not yet a thing that could be saved.
    func resolved() -> BrainSetupOption? {
        guard var option = selected else { return nil }
        if option.id.backendPlan == .localOllama {
            // A local brain with no model behind it cannot answer, and there is
            // no sensible default to invent — the machine either has one
            // downloaded or it does not.
            guard let localModel else { return nil }
            option.modelName = localModel
        }
        return option
    }

    /// Whether "Use this brain" does anything.
    ///
    /// `hasSavedKey` is passed in rather than read from `KeyStorage` so this can
    /// be exercised without writing to the owner's real key file.
    func canCommit(
        current: BrainSetupOption?,
        hasSavedKey: (String) -> Bool
    ) -> Bool {
        guard let resolved = resolved() else { return false }
        let key = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // A cloud provider with no key anywhere cannot be verified, and saving
        // it would hand him a brain that fails on his next question.
        if let provider = resolved.keyProviderIdentifier, !hasSavedKey(provider), key.isEmpty {
            return false
        }

        // Changing nothing is not a change — but a typed key *is* one even when
        // the provider has not moved, or an expired key could never be replaced.
        if resolved.id == current?.id, resolved.modelName == current?.modelName, key.isEmpty {
            return false
        }
        return true
    }

    // MARK: - Moving between the two sides

    /// Reselects within the side now on screen.
    ///
    /// Carrying a selection that is no longer visible would let "Use this brain"
    /// commit something the owner cannot see.
    mutating func moved(
        to destination: Destination,
        localOption: BrainSetupOption?,
        cloudOptions: [BrainSetupOption],
        current: BrainSetupOption?
    ) {
        self.destination = destination
        self.typedKey = ""
        switch destination {
        case .thisMac:
            selected = localOption
        case .cloud:
            selected = cloudOptions.contains { $0.id == current?.id } ? current : nil
        }
    }
}

extension BrainSetupChoices {
    /// The one option that runs on this Mac.
    var localOption: BrainSetupOption? {
        options.first { $0.id.backendPlan == .localOllama }
    }

    /// Everything that sends the owner's words to a company, which is exactly
    /// the set that needs a key.
    var cloudOptions: [BrainSetupOption] {
        availableOptions.filter { $0.keyProviderIdentifier != nil }
    }
}
