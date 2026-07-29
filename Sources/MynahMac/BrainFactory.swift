import Foundation
import SageVoiceCore

/// Turns a chosen setup option into a live backend.
///
/// Keyed on `BrainSetupOptionID.backendPlan` rather than on the free-form
/// `backendIdentifier` string. That distinction is the whole point: the string
/// was a *description* the planner wrote and this switch was a *guess* at what
/// the descriptions would be, so the two drifted — the planner emitted
/// `claude-code-cli`, `codex-cli`, `signin.google` and `openai-compatible`, this
/// file matched `ollama`, `gemini`, `openai` and `anthropic`, and four of the
/// seven cards on the brain screen threw on the owner's first question. Worse,
/// `gemini` was never emitted at all, so the one Google branch that existed was
/// dead code.
///
/// `backendPlan` is an enum the compiler makes exhaustive, and the planner marks
/// every option with no plan `.unavailable`, so an option that cannot be built
/// can no longer be offered.
enum BrainFactory {

    enum Failure: Error, CustomStringConvertible {
        /// The planner should have marked this unavailable. Reaching here means a
        /// stored choice from an older build, or a gate that regressed.
        case notServiceable(BrainSetupOptionID)

        var description: String {
            switch self {
            case .notServiceable(let id):
                return "nothing can serve '\(id.rawValue)' yet"
            }
        }
    }

    static func makeBackend(for option: BrainSetupOption, apiKey: String?) throws -> BrainBackend {
        guard let plan = option.id.backendPlan else {
            throw Failure.notServiceable(option.id)
        }

        switch plan {
        case .localOllama:
            return OllamaBackend(
                model: option.modelName ?? LocalBrainModelCatalog.preferredModel,
                managedRuntime: OllamaRuntimeInstaller.shared
            )

        case .anthropic:
            return AnthropicBackend(
                modelName: option.modelName ?? "claude-opus-5",
                apiKey: apiKey ?? ""
            )

        case .openAICompatible(let provider):
            return OpenAICompatBackend(
                provider: provider,
                modelName: option.modelName ?? defaultModelName(for: provider),
                credential: StaticAPIKeyCredential.bearer(
                    apiKey ?? "",
                    providerLabel: provider.displayName
                )
            )
        }
    }

    /// The model Mynah picks — read from the one catalogue, not restated here.
    ///
    /// This used to be a second copy of the daemon's list, under a comment
    /// saying the two matched. They did not: DeepSeek was `deepseek-v4-flash` in
    /// the daemon and the dead `deepseek-chat` alias here, so a brain set up in
    /// the app asked for a model that no longer resolved while the same brain
    /// set up from a terminal worked. The comment is what made the drift
    /// invisible. Now there is one list and nothing to keep in sync.
    private static func defaultModelName(for provider: OpenAICompatProvider) -> String {
        CloudBrainModelCatalog.model(forProvider: provider.identifier) ?? "local-model"
    }
}

/// Where a pasted key lives.
///
/// An API key is a spending credential on the owner's account, so it gets the
/// same treatment as the Google refresh token and the owner's transcripts: 0600
/// in a 0700 directory. Not the Keychain in this first cut — a Keychain item
/// prompts on first access after a restart, and this appliance restarts
/// unattended on a machine nobody is sitting at, which would turn a reboot into
/// a silent outage waiting for a password nobody is there to type.
enum KeyStorage {

    static func url(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("provider-keys.json")
    }

    static func save(_ key: String, forProvider provider: String) throws {
        var all = load()
        all[provider] = key
        let destination = url()
        try OwnerOnlyFileSecurity.prepareDirectory(destination.deletingLastPathComponent())
        try JSONEncoder().encode(all).write(to: destination, options: [.atomic])
        try OwnerOnlyFileSecurity.protectFile(destination)
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url()),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func key(forProvider provider: String) -> String? {
        load()[provider]
    }
}
