import Foundation

/// Where a provider API key lives between runs.
///
/// Exists so the key is not passed on a command line. An appliance daemon is
/// started by launchd or by hand and runs for weeks, and anything in its
/// argument vector is readable by every process on the machine via `ps` — so
/// `--key sk-…` would publish the owner's spending credential to any local
/// process, permanently, for the lifetime of the daemon.
///
/// A file, 0600 in a 0700 directory: the same discipline this package applies
/// to the owner's transcripts and their Google refresh token.
///
/// Not the Keychain, deliberately. A Keychain item prompts for authorisation on
/// first access after a restart, and this appliance restarts unattended on a
/// Mac mini nobody is sitting at — which would turn a reboot into a silent
/// outage waiting for a password that no one is there to type.
public struct ProviderKeyStore: Sendable {

    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    public static func defaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("provider-keys.json")
    }

    /// The environment variable each provider is conventionally configured with.
    ///
    /// Kept here rather than at the call site so the CLI, the daemon and the app
    /// cannot drift on which variable a provider reads.
    public static func environmentVariable(forProvider provider: String) -> String? {
        switch provider {
        case "gemini":            return "GEMINI_API_KEY"
        case "openai":            return "OPENAI_API_KEY"
        case "anthropic":         return "ANTHROPIC_API_KEY"
        case "deepseek":          return "DEEPSEEK_API_KEY"
        case "groq":              return "GROQ_API_KEY"
        case "moonshot", "kimi":  return "MOONSHOT_API_KEY"
        case "glm", "zhipu":      return "GLM_API_KEY"
        default:                  return nil
        }
    }

    // MARK: Reading

    /// The key for a provider: environment first, then the stored file.
    ///
    /// Environment wins so a one-off `GEMINI_API_KEY=… sage-voiced …` can test a
    /// different key without disturbing what the appliance runs on.
    public func key(
        forProvider provider: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let variable = Self.environmentVariable(forProvider: provider),
           let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        let stored = load()[provider]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false) ? stored : nil
    }

    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    // MARK: Writing

    public func save(_ key: String, forProvider provider: String) throws {
        var all = load()
        all[provider] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(all)
    }

    public func remove(provider: String) throws {
        var all = load()
        all.removeValue(forKey: provider)
        try write(all)
    }

    public var configuredProviders: [String] {
        load().keys.sorted()
    }

    private func write(_ all: [String: String]) throws {
        try OwnerOnlyFileSecurity.prepareDirectory(url.deletingLastPathComponent())
        // Written to a sibling and moved, so a crash mid-write cannot leave a
        // truncated file that silently loses every other provider's key.
        try JSONEncoder().encode(all).write(to: url, options: [.atomic])
        try OwnerOnlyFileSecurity.protectFile(url)
    }
}
