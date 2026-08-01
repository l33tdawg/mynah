import Foundation
import SageVoiceCore

/// Which model the owner last used *for each brain*, so switching sides does not
/// lose it.
///
/// **A destination and a model are one decision, and the sheet was treating them
/// as two.** Moving from DeepSeek to "On this Mac" changed where the words went
/// and left the model as whatever happened to be selected; moving back offered
/// the provider with nothing behind it. The owner put it plainly:
///
/// > *"if the user tries to change from cloud to local; OBVIOUSLY the model must
/// > be changed to the last used local model OR qwen by default — you can't
/// > change one without the other."*
///
/// `BrainSelectionStore` cannot answer this. It holds *the* choice, so the
/// moment the owner moves to local, what they were running on DeepSeek is
/// overwritten and the way back has forgotten. This keeps one entry per brain
/// instead of one entry.
///
/// Keyed by `BrainSetupOptionID`, not by backend: `key.deepseek` and
/// `key.openai` are different accounts with different catalogues, and a model
/// remembered for one is meaningless for the other.
enum LastBrainModelStore {

    private static func key(for id: BrainSetupOptionID) -> String {
        "mynah.brain.lastModel.\(id.rawValue)"
    }

    /// Records what a brain was last used with. A `nil` model is not recorded
    /// rather than recorded as nothing — an option saved before it had a model
    /// must not erase a good answer from last week.
    static func remember(_ option: BrainSetupOption, defaults: UserDefaults = .standard) {
        guard let model = option.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return }
        defaults.set(model, forKey: key(for: option.id))
    }

    static func model(for id: BrainSetupOptionID, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(for: id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    // MARK: What to use when there is no history

    /// The local model to preselect: what they used last, if it is still on the
    /// disk, then qwen, then whatever else is installed.
    ///
    /// The middle step is the one the owner named. A Mac with three models
    /// pulled and no history should land on the one this product chose and
    /// downloaded, not on whichever sorts first.
    static func localModel(
        installed: [String],
        defaults: UserDefaults = .standard
    ) -> String? {
        if let remembered = model(for: .fullyLocal, defaults: defaults),
           installed.contains(remembered) {
            return remembered
        }
        if let preferred = installed.first(where: {
            LocalBrainModelCatalog.normalize($0)
                == LocalBrainModelCatalog.normalize(LocalBrainModelCatalog.preferredModel)
        }) {
            return preferred
        }
        return installed.first
    }

    /// The cloud model to preselect: what they used last with *this* provider,
    /// if this build still offers it, otherwise the quick one.
    ///
    /// Falling back to quick rather than to the stored string is deliberate. A
    /// model this build no longer offers is one the vendor may have retired, and
    /// carrying it forward silently is how an owner ends up on a name that 404s
    /// — the failure `CloudBrainModelCatalog` exists to make survivable.
    static func cloudModel(
        for id: BrainSetupOptionID,
        provider: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        let offered = CloudBrainModelCatalog.models(forProvider: provider)
        if let remembered = model(for: id, defaults: defaults), offered.contains(remembered) {
            return remembered
        }
        return CloudBrainModelCatalog.model(forProvider: provider)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
