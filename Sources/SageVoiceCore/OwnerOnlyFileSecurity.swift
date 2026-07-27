import Foundation

public enum OwnerOnlyFileSecurity {
    public static let directoryPermissions: NSNumber = 0o700
    public static let filePermissions: NSNumber = 0o600

    public static func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: url.path)
    }

    public static func protectFile(_ url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
    }
}
