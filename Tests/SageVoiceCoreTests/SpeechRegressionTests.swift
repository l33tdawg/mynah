import XCTest
@testable import SageVoiceCore

/// Regression tests for the Speech defects found in adversarial review.
/// Each uses the reviewer's original failing input.
final class SpeechRegressionTests: XCTestCase {

    // MARK: - Segmenter: abbreviations were treated as sentence ends

    func testDoesNotSplitOnAbbreviations() {
        let cases: [(String, Int)] = [
            ("Nothing new in your inbox since 9 a.m. today.", 1),
            ("Ping Dr. Smith about the mini.", 1),
            ("Use e.g. the throughput mode. That is faster.", 2),
            ("The U.S. agent is idle.", 1),
        ]
        for (text, expected) in cases {
            let segments = SpeechTextSegmenter.segments(for: text, maximumLength: 240)
            XCTAssertEqual(
                segments.count, expected,
                "\(text.debugDescription) -> \(segments)"
            )
        }
    }

    /// The fix must not break real sentence splitting.
    func testStillSplitsRealSentences() {
        let segments = SpeechTextSegmenter.segments(
            for: "You have three open tasks. The oldest is fixing the whisper model. Want the list?",
            maximumLength: 240
        )
        XCTAssertEqual(segments.count, 3, "\(segments)")
    }

    /// Decimals and version strings must stay intact (this one already worked).
    func testDoesNotSplitInsideVersionsOrDecimals() {
        let segments = SpeechTextSegmenter.segments(
            for: "qwen3.5:4b scored 91.2% on routing.",
            maximumLength: 240
        )
        XCTAssertEqual(segments.count, 1, "\(segments)")
    }

    // MARK: - Segmenter: over-long single tokens escaped the budget

    /// The old `!current.isEmpty` guard let an over-long first token through
    /// whole, so the stated first-audio guarantee did not hold.
    func testEnforcesMaximumLengthAgainstOneHugeToken() {
        let giant = String(repeating: "x", count: 432)
        let segments = SpeechTextSegmenter.segments(
            for: "The token is \(giant) ok.",
            maximumLength: 240
        )
        for segment in segments {
            XCTAssertLessThanOrEqual(
                segment.count, 240,
                "segment of \(segment.count) chars exceeds the 240 budget"
            )
        }
    }

    /// Text with no spaces at all was never split.
    func testEnforcesMaximumLengthOnTextWithNoSpaces() {
        let cjk = String(repeating: "日", count: 500)
        let segments = SpeechTextSegmenter.segments(for: cjk, maximumLength: 60)
        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.count, 60, "segment of \(segment.count) chars")
        }
    }

    // MARK: - WAV parser

    /// A server that dies mid-write produced a "successful" 0.1s click with no
    /// error reported anywhere.
    func testTruncatedWAVIsRejectedRatherThanClamped() throws {
        var wav = WAVAudio.encode(pcm: [Int16](repeating: 0, count: 20_000), sampleRate: 24_000)
        // Keep the header (which declares 40,000 data bytes), drop most of the body.
        wav = wav.prefix(WAVAudio.headerByteCount + 5_000)

        XCTAssertThrowsError(try WAVAudio.format(of: Data(wav))) { error in
            guard case WAVAudio.ParseError.truncatedData = error else {
                return XCTFail("expected .truncatedData, got \(error)")
            }
        }
    }

    func testCompleteWAVStillParses() throws {
        let wav = WAVAudio.encode(pcm: [Int16](repeating: 0, count: 24_000), sampleRate: 24_000)
        let format = try WAVAudio.format(of: wav)
        XCTAssertEqual(format.sampleRate, 24_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.bitsPerSample, 16)
        XCTAssertEqual(format.duration, 1.0, accuracy: 0.001)
    }

    /// A zero-length `fact`/`LIST`/`PAD` chunk before `data` is legal RIFF and
    /// used to abort the chunk walk, rejecting a perfectly valid file.
    func testZeroLengthChunkBeforeDataDoesNotAbortParsing() throws {
        var wav = Data()
        func ascii(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }

        let payload = Data(repeating: 0, count: 100)
        ascii("RIFF"); u32(UInt32(4 + 24 + 8 + 8 + payload.count)); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        ascii("fact"); u32(0)                      // zero-length chunk
        ascii("data"); u32(UInt32(payload.count)); wav.append(payload)

        let format = try WAVAudio.format(of: wav)
        XCTAssertEqual(format.sampleRate, 24_000)
        XCTAssertEqual(format.dataByteCount, 100)
    }
}
