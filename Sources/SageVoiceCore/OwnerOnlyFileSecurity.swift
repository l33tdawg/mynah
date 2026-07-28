import Foundation

public enum OwnerOnlyFileSecurity {
    public static let directoryPermissions: NSNumber = 0o700
    public static let filePermissions: NSNumber = 0o600

    public static func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: url.path)
    }

    /// Writes owner-only from the first byte.
    ///
    /// `Data.write(to:options:.atomic)` creates a fresh file at 0644 and only
    /// then can it be chmod'ed, so every first write published the contents
    /// world-readable for the moment in between. Measured on this machine: the
    /// intermediate mode really is 0644. It is a small window and it is on the
    /// owner's own conversations and keys, which is exactly the material that
    /// does not get a small window.
    public static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory, fileManager: fileManager)

        // Same directory, so the replace is a rename rather than a copy across
        // volumes — atomic, and the mode is set before any content exists.
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        guard fileManager.createFile(
            atPath: staging.path,
            contents: nil,
            attributes: [.posixPermissions: filePermissions]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        _ = try fileManager.replaceItemAt(url, withItemAt: staging)
        try protectFile(url, fileManager: fileManager)
    }

    public static func protectFile(_ url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
    }
}
