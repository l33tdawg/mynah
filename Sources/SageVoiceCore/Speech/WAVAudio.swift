import Foundation

/// Minimal RIFF/WAVE reader and writer.
///
/// Enough to (a) learn the sample rate and duration of a WAV a backend just
/// handed us, and (b) wrap raw float samples from a future in-process
/// synthesizer into a container the rest of the pipeline already understands.
/// Deliberately not a general audio library: PCM only, no compressed formats.
public enum WAVAudio {
    /// Fixed-size header emitted by `encode`. Canonical 44-byte layout.
    public static let headerByteCount = 44

    /// The parts of a WAV header we care about.
    public struct Format: Sendable, Equatable {
        public let sampleRate: Int
        public let channelCount: Int
        public let bitsPerSample: Int
        /// Byte count of the `data` chunk payload.
        public let dataByteCount: Int

        public init(sampleRate: Int, channelCount: Int, bitsPerSample: Int, dataByteCount: Int) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bitsPerSample = bitsPerSample
            self.dataByteCount = dataByteCount
        }

        /// Duration of the `data` chunk in seconds.
        public var duration: TimeInterval {
            let bytesPerFrame = max(1, channelCount * bitsPerSample / 8)
            guard sampleRate > 0 else { return 0 }
            return Double(dataByteCount / bytesPerFrame) / Double(sampleRate)
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case notRIFF
        case notWAVE
        case missingFormatChunk
        case missingDataChunk
        case unsupportedBitDepth(Int)
        /// The data chunk declared more bytes than the payload actually held —
        /// a truncated response (server died mid-write), not a streaming writer.
        case truncatedData(declared: Int, available: Int)

        public var description: String {
            switch self {
                case let .truncatedData(declared, available):
                    return "WAV data chunk declared \(declared) bytes but only \(available) arrived; the audio is truncated."
                case let .tooShort(count):
                    return "WAV payload is only \(count) bytes, too short to contain a header."
                case .notRIFF:
                    return "WAV payload does not start with a RIFF chunk."
                case .notWAVE:
                    return "RIFF payload is not of type WAVE."
                case .missingFormatChunk:
                    return "WAV payload has no fmt chunk."
                case .missingDataChunk:
                    return "WAV payload has no data chunk."
                case let .unsupportedBitDepth(bits):
                    return "WAV payload uses \(bits)-bit samples, which is not supported."
            }
        }
    }

    // MARK: - Reading

    /// Read the format of a WAV container, walking the chunk list so that files
    /// with `LIST`/`fact` chunks before `data` still parse.
    public static func format(of wav: Data) throws -> Format {
        guard wav.count >= 12 else { throw ParseError.tooShort(wav.count) }
        guard readASCII(wav, at: 0, count: 4) == "RIFF" else { throw ParseError.notRIFF }
        guard readASCII(wav, at: 8, count: 4) == "WAVE" else { throw ParseError.notWAVE }

        var offset = 12
        var sampleRate: Int?
        var channelCount: Int?
        var bitsPerSample: Int?
        var dataByteCount: Int?

        while offset + 8 <= wav.count {
            let chunkID = readASCII(wav, at: offset, count: 4)
            let chunkSize = Int(readUInt32(wav, at: offset + 4))
            let bodyOffset = offset + 8

            switch chunkID {
                case "fmt ":
                    guard bodyOffset + 16 <= wav.count else { throw ParseError.missingFormatChunk }
                    channelCount = Int(readUInt16(wav, at: bodyOffset + 2))
                    sampleRate = Int(readUInt32(wav, at: bodyOffset + 4))
                    bitsPerSample = Int(readUInt16(wav, at: bodyOffset + 14))
                case "data":
                    // Some writers stream and leave the size field at 0 or 0xFFFFFFFF,
                    // so an UNDECLARED length legitimately means "whatever arrived".
                    //
                    // But a chunk that declares N bytes and delivers fewer is a
                    // TRUNCATED response — the synth server died or was OOM-killed
                    // mid-write. Clamping there turns a failure into a valid-looking
                    // 0.1s click that nothing reports. Fail loudly instead.
                    let declared = chunkSize
                    let available = max(0, wav.count - bodyOffset)
                    if declared == 0 || declared == Int(UInt32.max) {
                        dataByteCount = available
                    } else if declared > available {
                        throw ParseError.truncatedData(declared: declared, available: available)
                    } else {
                        dataByteCount = declared
                    }
                default:
                    break
            }

            if dataByteCount != nil, sampleRate != nil { break }
            // Chunks are word aligned.
            // A zero-length chunk (fact/LIST/PAD) is legal RIFF and must not
            // abort the walk — `offset` still advances by the 8-byte header, so
            // this cannot spin.
            offset = bodyOffset + chunkSize + (chunkSize % 2)
            if chunkSize < 0 { break }
        }

        guard let sampleRate, let channelCount, let bitsPerSample else {
            throw ParseError.missingFormatChunk
        }
        guard let dataByteCount else { throw ParseError.missingDataChunk }
        guard bitsPerSample == 8 || bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32 else {
            throw ParseError.unsupportedBitDepth(bitsPerSample)
        }

        return Format(
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitsPerSample: bitsPerSample,
            dataByteCount: dataByteCount
        )
    }

    // MARK: - Writing

    /// Wrap normalized float samples (nominally -1.0 ... 1.0) in a 16-bit PCM WAV.
    ///
    /// This is the bridge a future in-process synthesizer needs: TTSKit and
    /// friends hand back `[Float]`, while everything downstream of
    /// `SpeechSynthesizing` speaks WAV.
    public static func encode(samples: [Float], sampleRate: Int, channelCount: Int = 1) -> Data {
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            // 32767 rather than 32768 so +1.0 does not wrap to negative.
            pcm.append(Int16((clamped * 32767.0).rounded()))
        }
        return encode(pcm: pcm, sampleRate: sampleRate, channelCount: channelCount)
    }

    /// Wrap 16-bit PCM samples in a WAV container.
    public static func encode(pcm: [Int16], sampleRate: Int, channelCount: Int = 1) -> Data {
        let bitsPerSample = 16
        let bytesPerFrame = channelCount * bitsPerSample / 8
        let dataByteCount = pcm.count * MemoryLayout<Int16>.size

        var wav = Data(capacity: headerByteCount + dataByteCount)
        wav.appendASCII("RIFF")
        wav.appendUInt32(UInt32(36 + dataByteCount))
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendUInt32(16)                                        // PCM fmt chunk size
        wav.appendUInt16(1)                                         // format tag: PCM
        wav.appendUInt16(UInt16(channelCount))
        wav.appendUInt32(UInt32(sampleRate))
        wav.appendUInt32(UInt32(sampleRate * bytesPerFrame))        // byte rate
        wav.appendUInt16(UInt16(bytesPerFrame))                     // block align
        wav.appendUInt16(UInt16(bitsPerSample))
        wav.appendASCII("data")
        wav.appendUInt32(UInt32(dataByteCount))
        for sample in pcm {
            wav.appendUInt16(UInt16(bitPattern: sample))
        }
        return wav
    }

    // MARK: - Little-endian helpers

    private static func readASCII(_ data: Data, at offset: Int, count: Int) -> String {
        guard offset >= 0, offset + count <= data.count else { return "" }
        let start = data.startIndex + offset
        return String(decoding: data[start..<(start + count)], as: UTF8.self)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let start = data.startIndex + offset
        return UInt16(data[start]) | (UInt16(data[start + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let start = data.startIndex + offset
        return UInt32(data[start])
            | (UInt32(data[start + 1]) << 8)
            | (UInt32(data[start + 2]) << 16)
            | (UInt32(data[start + 3]) << 24)
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
