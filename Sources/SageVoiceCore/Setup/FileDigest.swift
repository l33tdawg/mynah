import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// SHA-256 over a file, read in chunks.
///
/// Streaming rather than `Data(contentsOf:)` because the thing being verified is
/// a multi-hundred-megabyte disk image, and mapping one into memory on a 16 GB
/// appliance that is also holding a 4B model resident is how you get an OOM
/// during what should be a background download.
///
/// The hash comes from CryptoKit on Apple platforms, where it is a system
/// framework, and from swift-crypto elsewhere. The two present the same API, so
/// nothing below changes — but the old claim that this kept the package free of
/// external dependencies is no longer true off Darwin, where swift-crypto is a
/// declared package dependency.
public enum FileDigest {
    /// 1 MiB: large enough that syscall overhead is irrelevant, small enough to
    /// stay out of the way of the model.
    static let chunkByteCount = 1024 * 1024

    public static func sha256Hex(
        ofFileAt url: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SageNodeError.notFound(url.path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: chunkByteCount), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Single-shot digest of bytes already in memory.
    ///
    /// Not used for disk images — it exists so the streaming path above can be
    /// checked against a whole-buffer hash of the same bytes, which is the only
    /// way to catch a chunk-boundary bug.
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
