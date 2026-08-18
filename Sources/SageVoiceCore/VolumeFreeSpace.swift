import Foundation

/// How much room is left on the volume holding a path.
///
/// ## Why this is a type rather than three copies of one line
///
/// Three places ask it — before a 325 MB voice model, before a three-times-the-
/// download app update, and when the setup probe reports what this machine can
/// run. All three used
/// `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`,
/// which does not exist off Darwin, and each one would otherwise have grown its
/// own `#if` and its own idea of what "free" means. This package's most
/// repeated defect, by its own commit messages, is a change made at one call
/// site while an identical one goes unwatched.
///
/// ## The two answers are not the same number, and that is worth knowing
///
/// `volumeAvailableCapacityForImportantUsage` is macOS's *considered* answer: it
/// counts space the system would purge — caches, local snapshots, redownloadable
/// files — because those really will be given up rather than let a download
/// fail. On an APFS Mac with Time Machine local snapshots it is routinely tens
/// of gigabytes above what `df` prints, and using the raw statvfs figure there
/// would refuse installs that would have succeeded.
///
/// Off Darwin there is nothing with that judgement, so this reports the plain
/// filesystem answer that `df` gives. It is the more pessimistic of the two,
/// which is the right direction to be wrong in for every caller here: each one
/// is asking "is there room", and an answer that is too small refuses an install
/// that would have fitted, while an answer that is too large runs out of disk
/// half way through replacing the app.
///
/// **It is not `FileManager.attributesOfFileSystem` by accident.** That is the
/// one portable spelling of statvfs in Foundation itself, so this needs no libc
/// import and no second implementation to keep in step with `POSIXShim`.
public enum VolumeFreeSpace {

    /// Bytes available on the volume containing `url`, or `nil` if the question
    /// cannot be answered — which is what every caller here already handles,
    /// and is the honest answer for a path that does not exist yet.
    ///
    /// The path must exist. Both implementations answer about a real file or
    /// directory, not about where one would go, so a caller wanting the volume
    /// under a directory it has not created yet has to walk up to something that
    /// does exist — see `SystemHardwareProbe.freeBytes(near:)`, which does.
    public static func availableBytes(at url: URL) -> Int64? {
        #if canImport(Darwin)
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
        #else
        guard let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: url.path
        ) else { return nil }
        // Foundation stores these as `NSNumber` on every platform that has this
        // call, but the dictionary is `[FileAttributeKey: Any]` and the day it
        // holds a plain integer instead is not a day this should start
        // reporting "no idea" and refusing installs.
        switch attributes[.systemFreeSize] {
        case let number as NSNumber: return number.int64Value
        case let value as Int64: return value
        case let value as UInt64: return Int64(clamping: value)
        case let value as Int: return Int64(value)
        default: return nil
        }
        #endif
    }
}
