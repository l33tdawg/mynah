#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Security)
import Security
#endif

public enum MemoryBackendMode: String, Codable, Sendable {
    case sqliteOnly
    case sage
    case hybrid
}

public enum DictationMemoryType: String, Codable, Sendable {
    case vocabulary = "dictation.vocabulary"
    case correction = "dictation.correction"
    case styleProfile = "dictation.style_profile"
    case formattingPreference = "dictation.formatting_preference"
    case transcriptNote = "dictation.transcript_note"
    case voiceNote = "dictation.voice_note"
}

public struct DictationMemory: Codable, Equatable, Sendable, Identifiable {
    public var id: String?
    public var type: DictationMemoryType
    public var payload: [String: String]
    public var contexts: [String]
    public var source: String
    public var confidence: Double
    public var privacy: String
    public var createdBy: String

    public init(
        id: String? = nil,
        type: DictationMemoryType,
        payload: [String: String],
        contexts: [String] = [],
        source: String,
        confidence: Double,
        privacy: String = "local",
        createdBy: String = SageVoiceIdentity.agentName
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.contexts = contexts
        self.source = source
        self.confidence = confidence
        self.privacy = privacy
        self.createdBy = createdBy
    }
}

public struct MemorySearchQuery: Codable, Equatable, Sendable {
    public var text: String
    public var appName: String?
    public var types: [DictationMemoryType]
    public var limit: Int
    public var localOnly: Bool

    public init(
        text: String,
        appName: String? = nil,
        types: [DictationMemoryType] = [],
        limit: Int = 8,
        localOnly: Bool = true
    ) {
        self.text = text
        self.appName = appName
        self.types = types
        self.limit = limit
        self.localOnly = localOnly
    }
}

public protocol MemoryStore: Sendable {
    func put(_ memory: DictationMemory) async throws -> String
    func search(_ query: MemorySearchQuery) async throws -> [DictationMemory]
    func update(memoryID: String, patch: [String: String]) async throws
    func delete(memoryID: String) async throws
    func explain(memoryID: String) async throws -> String
}

public actor SQLiteMemoryStore: MemoryStore {
    private static let encryptedFilePrefix = Data("QTMS1".utf8)
#if canImport(Security)
    private static let keychainService = "QuietType.MemoryStore"
    /// Internal rather than private so a Mac test can pin it against
    /// `keyFileName` below. The two platforms are supposed to name one secret
    /// one way, and that claim was a comment until it was an assertion.
    static let keychainAccount = "quiettype-local-memory-aes-gcm-key"
#endif

    /// The same identifier the Keychain item carries on a Mac, used as a file
    /// name off Darwin so the two platforms name one secret one way.
    ///
    /// Declared unconditionally — see `keyFileURL` for why a path that only
    /// exists on Linux is a path no Mac test can redden.
    static let keyFileName = "quiettype-local-memory-aes-gcm-key"

    private var memories: [String: DictationMemory] = [:]
    private let storeURL: URL?
    private let encrypted: Bool

    public init(storeURL: URL? = nil, encrypted: Bool = false) {
        self.storeURL = storeURL
        self.encrypted = encrypted
        if let storeURL,
           let data = try? Data(contentsOf: storeURL),
           let decoded = try? Self.decodeStoredMemories(from: data, encrypted: encrypted) {
            memories = decoded
        }
    }

    /// The directory holding the encrypted store **and the key that opens it**.
    ///
    /// One function because they were two, and the two disagreed. The store was
    /// spelled `~/Library/Application Support/QuietType` by hand and the key —
    /// which only exists off Darwin, where there is no Keychain — came from
    /// `FileManager.applicationSupportDirectory`, which is `$XDG_DATA_HOME` under
    /// swift-corelibs-foundation. On a Mac those are the same root and nobody
    /// noticed. On Linux the ciphertext went to a `~/Library` folder the system
    /// does not understand while its key went to `~/.local/share`: one secret in
    /// two roots, of which exactly one is on the owner's backup list. Losing the
    /// key loses every memory, silently, and the store beside it would still be
    /// sitting there looking intact.
    ///
    /// `QuietType` is kept on a Mac and only on a Mac. That folder name is where
    /// every shipped install's memories already are — this appliance grew out of
    /// QuietType and the store never moved — so renaming it would read as a
    /// factory-fresh appliance with no memories at all. Off Darwin nothing has
    /// ever been written under either name, so the store joins the rest of the
    /// appliance's state instead of importing a second product's folder.
    public static func persistentDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch layout {
        case .darwin:
            return homeDirectory
                .appendingPathComponent("Library/Application Support/QuietType", isDirectory: true)
        case .xdg:
            return ApplianceSupportDirectory.directory(
                layout: layout,
                homeDirectory: homeDirectory,
                environment: environment
            )
        }
    }

    public static func persistentDefault(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SQLiteMemoryStore {
        let directory = persistentDirectory(
            homeDirectory: homeDirectory,
            layout: layout,
            environment: environment
        )
        let encryptedURL = directory.appendingPathComponent("memory-store.qtmemory")
        let legacyURL = directory.appendingPathComponent("memory-store.json")
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: encryptedURL.path),
           fileManager.fileExists(atPath: legacyURL.path),
           let legacyData = try? Data(contentsOf: legacyURL),
           let legacyMemories = try? decodeStoredMemories(from: legacyData, encrypted: true),
           (try? writeStoredMemories(legacyMemories, to: encryptedURL, encrypted: true)) != nil {
            try? fileManager.removeItem(at: legacyURL)
        }
        return SQLiteMemoryStore(storeURL: encryptedURL, encrypted: true)
    }

    public func put(_ memory: DictationMemory) async throws -> String {
        let id = memory.id ?? UUID().uuidString
        var stored = memory
        stored.id = id
        memories[id] = stored
        try persist()
        return id
    }

    public func search(_ query: MemorySearchQuery) async throws -> [DictationMemory] {
        let needle = query.text.lowercased()
        let filtered = memories.values.filter { memory in
            let typeMatches = query.types.isEmpty || query.types.contains(memory.type)
            let textMatches = needle.isEmpty
                || memory.contexts.joined(separator: " ").lowercased().contains(needle)
                || memory.payload.values.joined(separator: " ").lowercased().contains(needle)
            return typeMatches && textMatches
        }

        return Array(filtered.prefix(query.limit))
    }

    public func update(memoryID: String, patch: [String: String]) async throws {
        guard var memory = memories[memoryID] else {
            throw MemoryStoreError.notFound(memoryID)
        }
        for (key, value) in patch {
            memory.payload[key] = value
        }
        memories[memoryID] = memory
        try persist()
    }

    public func delete(memoryID: String) async throws {
        memories.removeValue(forKey: memoryID)
        try persist()
    }

    public func explain(memoryID: String) async throws -> String {
        guard let memory = memories[memoryID] else {
            throw MemoryStoreError.notFound(memoryID)
        }
        return "Stored locally as \(memory.type.rawValue) with confidence \(memory.confidence)."
    }

    private func persist() throws {
        guard let storeURL else {
            return
        }

        try Self.writeStoredMemories(memories, to: storeURL, encrypted: encrypted)
    }

    private static func writeStoredMemories(_ memories: [String: DictationMemory], to storeURL: URL, encrypted: Bool) throws {
        let directory = storeURL.deletingLastPathComponent()
        try OwnerOnlyFileSecurity.prepareDirectory(directory)
        let data = try JSONEncoder().encode(memories)
        let storedData = try encrypted ? Self.encrypt(data) : data
        try storedData.write(to: storeURL, options: [.atomic])
        try OwnerOnlyFileSecurity.protectFile(storeURL)
    }

    private static func decodeStoredMemories(from data: Data, encrypted: Bool) throws -> [String: DictationMemory] {
        if data.starts(with: encryptedFilePrefix) {
            let encryptedPayload = data.dropFirst(encryptedFilePrefix.count)
            let decrypted = try decrypt(Data(encryptedPayload))
            return try JSONDecoder().decode([String: DictationMemory].self, from: decrypted)
        }

        if encrypted, let decrypted = try? decrypt(data) {
            return try JSONDecoder().decode([String: DictationMemory].self, from: decrypted)
        }

        return try JSONDecoder().decode([String: DictationMemory].self, from: data)
    }

    private static func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: memoryKey())
        guard let combined = sealed.combined else {
            throw MemoryStoreError.encryptionFailed
        }
        return encryptedFilePrefix + combined
    }

    private static func decrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealed, using: memoryKey())
    }

    /// The AES-GCM key, minted once and kept for the life of the install.
    ///
    /// Where it is kept is the platform's business: the Keychain on a Mac, an
    /// owner-only file elsewhere. Both branches answer the same two questions —
    /// "is there already a key" and "keep this one" — so nothing above this
    /// line knows which one it got.
    private static func memoryKey() throws -> SymmetricKey {
        if let data = try storedKeyData() {
            return SymmetricKey(data: data)
        }

        let data = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        try storeKeyData(data)
        return SymmetricKey(data: data)
    }

#if canImport(Security)

    private static func storedKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            throw MemoryStoreError.encryptionFailed
        }
        return data
    }

    private static func storeKeyData(_ data: Data) throws {
        guard data.count == 32 else {
            throw MemoryStoreError.encryptionFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MemoryStoreError.encryptionFailed
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw MemoryStoreError.encryptionFailed
        }
    }

#endif

    /// Where the key lives when there is no Keychain to put it in.
    ///
    /// **This is a downgrade and it is worth being plain about it.** The Mac
    /// path hands the key to a system daemon that keeps it encrypted at rest
    /// under the login password and never lets another user's process read it.
    /// Linux has no equivalent this package can depend on, so the key sits
    /// beside the store it unlocks, protected by nothing stronger than file
    /// permissions. That still buys the thing encryption at rest was for on a
    /// shared machine — another account cannot read the notes — but it does not
    /// survive an attacker who already has the owner's own uid.
    ///
    /// **"Beside the store it unlocks" is now true.** It was written here while
    /// the store went to `~/Library/Application Support/QuietType` and this went
    /// to `FileManager.applicationSupportDirectory` — `$XDG_DATA_HOME` under
    /// swift-corelibs-foundation — so the sentence described a layout the code
    /// did not produce. Both now come from `persistentDirectory`, which is the
    /// only way one root can be guaranteed rather than asserted in prose.
    ///
    /// Declared on both platforms although only the keyless build reads it. A
    /// `#if`-shaped path is a path the Mac cannot see, and the Mac is where this
    /// suite is run before a release: the split above survived review precisely
    /// because half of it did not exist on the reviewer's machine.
    static func keyFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        persistentDirectory(
            homeDirectory: homeDirectory,
            layout: layout,
            environment: environment
        )
        .appendingPathComponent(keyFileName, isDirectory: false)
    }

#if !canImport(Security)

    private static func storedKeyData() throws -> Data? {
        let url = keyFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        // A short read is a corrupt key, not an absent one: returning nil would
        // silently mint a second key and lose every note the first one sealed.
        guard let data = try? Data(contentsOf: url), data.count == 32 else {
            throw MemoryStoreError.encryptionFailed
        }
        return data
    }

    private static func storeKeyData(_ data: Data) throws {
        guard data.count == 32 else {
            throw MemoryStoreError.encryptionFailed
        }
        // 0700 on the directory and 0600 on the file, set before the first byte
        // of key material exists rather than chmod'ed afterwards.
        let url = keyFileURL()
        try OwnerOnlyFileSecurity.write(data, to: url)
    }

#endif
}

public enum MemoryStoreError: Error, Equatable {
    case notFound(String)
    case sageUnavailable
    case nonLocalSageEndpoint(String)
    case networkedSageRequiresUserConsent
    case encryptionFailed
}
