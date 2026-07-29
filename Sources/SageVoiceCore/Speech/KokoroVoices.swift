import Foundation

/// Reads a style vector out of `voices-v1.0.bin`.
///
/// ## What that file actually is
///
/// Despite the extension, it is a **ZIP archive** — an uncompressed numpy
/// `.npz` — holding 54 members named `<voice>.npy`, each a `(510, 1, 256)`
/// array of little-endian `float32`. Every member is `STORED`, not deflated,
/// which is what makes this readable without a compression library: the bytes
/// on disk are the bytes wanted.
///
/// ## Why it reads 1 KB instead of 28 MB
///
/// A synthesis needs exactly one row of one voice — 256 floats, selected by
/// token count. The Python side calls `np.load`, which memory-maps the whole
/// archive and hands back a lazily-loading object; the obvious Swift
/// translation would be to read the 28 MB file and index it, which is 28,000
/// times more I/O than the job requires on an appliance that answers from cold.
///
/// So this parses the central directory once, keeps an offset per voice, and
/// reads the single row it needs at synthesis time.
///
/// ## The index
///
/// The row is chosen by **token count before padding** — not the padded length,
/// and not the phoneme character count. They coincide only when every scalar
/// was in the vocabulary, so indexing by anything else is a bug that produces
/// subtly wrong prosody rather than an error.
public struct KokoroVoices: Sendable {

    public enum Failure: Error, Equatable {
        case cannotRead(String)
        /// Not a ZIP, or a ZIP this reader will not guess at.
        case notAnArchive
        /// A member is deflated. numpy writes `np.savez` uncompressed; a file
        /// that arrives compressed is a different file than the one this was
        /// verified against, and guessing is worse than saying so.
        case compressedMember(String)
        case unknownVoice(String)
        /// The member is not the `(510, 1, 256)` little-endian float32 array
        /// every voice is supposed to be.
        case unexpectedLayout(String)
        /// Asked for a row the array does not have.
        case tokenCountOutOfRange(Int)
    }

    /// Rows per voice. Also the exclusive upper bound on a token count.
    public static let styleRows = 510
    /// Floats per row — the model's `style` input is `[1, 256]`.
    public static let styleWidth = 256

    private let url: URL
    /// Voice name to the file offset of its array data, past the `.npy` header.
    private let offsets: [String: UInt64]

    public var names: [String] { offsets.keys.sorted() }

    public init(contentsOf url: URL) throws {
        self.url = url
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.cannotRead(url.lastPathComponent)
        }
        defer { try? handle.close() }
        self.offsets = try Self.index(handle)
    }

    /// The 256 floats for this voice at this token count.
    public func style(for voice: String, tokenCount: Int) throws -> [Float] {
        guard let base = offsets[voice] else { throw Failure.unknownVoice(voice) }
        guard tokenCount >= 0, tokenCount < Self.styleRows else {
            throw Failure.tokenCountOutOfRange(tokenCount)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.cannotRead(url.lastPathComponent)
        }
        defer { try? handle.close() }

        let rowBytes = Self.styleWidth * 4
        try handle.seek(toOffset: base + UInt64(tokenCount * rowBytes))
        guard let data = try handle.read(upToCount: rowBytes), data.count == rowBytes else {
            throw Failure.unexpectedLayout(voice)
        }
        // Copied through a byte buffer rather than bound in place: `Data` from a
        // file read carries no alignment guarantee, and binding unaligned memory
        // to Float is undefined rather than merely slow.
        return data.withUnsafeBytes { raw in
            (0..<Self.styleWidth).map { index in
                Float(bitPattern: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian)
            }
        }
    }

    // MARK: - Reading the archive

    /// Walks the central directory and returns the data offset of every member.
    private static func index(_ handle: FileHandle) throws -> [String: UInt64] {
        let size = try handle.seekToEnd()
        // The end-of-central-directory record is last, but a trailing comment
        // can push it back by up to 64 KB, so the tail is searched rather than
        // assumed to end exactly there.
        let tailLength = Int(min(size, 66_000))
        try handle.seek(toOffset: size - UInt64(tailLength))
        guard let tail = try handle.read(upToCount: tailLength) else { throw Failure.notAnArchive }

        guard let eocd = lastIndex(of: 0x0605_4b50, in: tail) else { throw Failure.notAnArchive }
        let entryCount = Int(tail.u16(eocd + 10))
        let directoryOffset = UInt64(tail.u32(eocd + 16))

        try handle.seek(toOffset: directoryOffset)
        guard let directory = try handle.read(upToCount: Int(size - directoryOffset)) else {
            throw Failure.notAnArchive
        }

        var offsets: [String: UInt64] = [:]
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count, directory.u32(cursor) == 0x0201_4b50 else {
                throw Failure.notAnArchive
            }
            let method = directory.u16(cursor + 10)
            let nameLength = Int(directory.u16(cursor + 28))
            let extraLength = Int(directory.u16(cursor + 30))
            let commentLength = Int(directory.u16(cursor + 32))
            let localOffset = UInt64(directory.u32(cursor + 42))
            let name = String(
                decoding: directory[(directory.startIndex + cursor + 46)...].prefix(nameLength),
                as: UTF8.self
            )

            guard method == 0 else { throw Failure.compressedMember(name) }
            if name.hasSuffix(".npy") {
                offsets[String(name.dropLast(4))] = try dataOffset(handle, localHeader: localOffset, member: name)
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard !offsets.isEmpty else { throw Failure.notAnArchive }
        return offsets
    }

    /// Skips a member's local header and its `.npy` header, validating the
    /// array's dtype and shape on the way past.
    ///
    /// The local header's name and extra lengths are read rather than copied
    /// from the central directory — the format permits them to differ, and
    /// numpy's writer pads the extra field to align array data.
    private static func dataOffset(
        _ handle: FileHandle,
        localHeader: UInt64,
        member: String
    ) throws -> UInt64 {
        try handle.seek(toOffset: localHeader)
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              header.u32(0) == 0x0403_4b50 else {
            throw Failure.notAnArchive
        }
        let nameLength = Int(header.u16(26))
        let extraLength = Int(header.u16(28))
        let contentStart = localHeader + 30 + UInt64(nameLength + extraLength)

        try handle.seek(toOffset: contentStart)
        guard let npy = try handle.read(upToCount: 128), npy.count == 128 else {
            throw Failure.unexpectedLayout(member)
        }
        // \x93NUMPY, then major/minor, then a two-byte header length.
        guard npy.prefix(6).elementsEqual([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) else {
            throw Failure.unexpectedLayout(member)
        }
        let descriptorLength = Int(npy.u16(8))
        let descriptor = String(
            decoding: npy[(npy.startIndex + 10)...].prefix(descriptorLength), as: UTF8.self
        )
        // Checked rather than trusted. A voices file with a different dtype or
        // shape would otherwise be read as garbage floats and synthesized — the
        // failure would be audible and unexplainable.
        guard descriptor.contains("'<f4'"),
              descriptor.contains("'fortran_order': False"),
              descriptor.contains("(\(styleRows), 1, \(styleWidth))") else {
            throw Failure.unexpectedLayout(member)
        }
        return contentStart + 10 + UInt64(descriptorLength)
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for offset in stride(from: data.count - 4, through: 0, by: -1)
        where data.u32(offset) == signature {
            return offset
        }
        return nil
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset])
            | UInt32(self[startIndex + offset + 1]) << 8
            | UInt32(self[startIndex + offset + 2]) << 16
            | UInt32(self[startIndex + offset + 3]) << 24
    }
}
