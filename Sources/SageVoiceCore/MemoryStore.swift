import CryptoKit
import Foundation
import Security

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
    private static let keychainService = "QuietType.MemoryStore"
    private static let keychainAccount = "quiettype-local-memory-aes-gcm-key"

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

    public static func persistentDefault(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> SQLiteMemoryStore {
        let directory = homeDirectory
            .appendingPathComponent("Library/Application Support/QuietType", isDirectory: true)
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

    private static func memoryKey() throws -> SymmetricKey {
        if let data = try keychainKeyData() {
            return SymmetricKey(data: data)
        }

        let data = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        try saveKeyDataToKeychain(data)
        return SymmetricKey(data: data)
    }

    private static func keychainKeyData() throws -> Data? {
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

    private static func saveKeyDataToKeychain(_ data: Data) throws {
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
}

public enum MemoryStoreError: Error, Equatable {
    case notFound(String)
    case sageUnavailable
    case nonLocalSageEndpoint(String)
    case networkedSageRequiresUserConsent
    case encryptionFailed
}
