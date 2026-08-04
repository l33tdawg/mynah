import XCTest
@testable import SageVoiceCore

/// **That the silence Kokoro pads with is removed exactly where librosa removes
/// it.**
///
/// Verified against both golden vectors captured from the running
/// `kokoro_onnx`, and the intervals match to the sample:
///
///   - the fox sentence, 90,600 samples → `8192..<78848`
///   - "Hello.", 34,200 samples → `7168..<28160`
///
/// Those runs need the captured arrays on disk. Everything below them holds
/// without any fixture, because a trim that is merely *approximately* right is
/// the kind of thing that passes review and then clips the first consonant off
/// every sentence.
///
/// **The two fixture tests skipped on every machine, for ever, and said nothing
/// about it.** They read from `/private/tmp/claude-501/…/caf51fc9-…/scratchpad/`
/// — an agent session's scratch directory, which stopped existing when that
/// session did and cannot come back. So they were not "skipped until somebody
/// stages the fixture", they were retired without anybody deciding to retire
/// them, and they spent two places in the release gate's skip budget doing it.
/// Found on 4 August 2026 by the audit of the gate itself.
///
/// They now read from the lab directory the Kokoro tests already use, and the
/// skip says how to put the vectors there. A skip that names no action is a
/// deleted test with extra steps.
final class SilenceTrimTests: XCTestCase {

    // MARK: Against librosa

    /// Where the captured arrays live, following `KokoroVoicesTests` and
    /// `KokoroSessionTests` rather than inventing a third convention.
    ///
    /// Overridable, because the lab path is one person's home directory and the
    /// vectors are a few hundred kilobytes that nobody should have to put there
    /// to run them.
    static var goldenDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MYNAH_KOKORO_GOLDEN"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("sage-voice-lab/kokoro-golden", isDirectory: true)
    }

    /// The captured raw model output, if this machine has it.
    private func golden(_ name: String) throws -> [Float] {
        let file = Self.goldenDirectory.appendingPathComponent("\(name).f32")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("""
                no golden vector at \(file.path). These are the raw float32 arrays \
                kokoro_onnx returns before any trimming, captured once and compared \
                against librosa's own intervals. Recapture with:

                  python3 -c "import numpy, kokoro_onnx; \
                k = kokoro_onnx.Kokoro('kokoro-v1.0.onnx', 'voices-v1.0.bin'); \
                s, _ = k.create('The quick brown fox jumps over the lazy dog.', \
                voice='am_puck', speed=1.0); \
                numpy.asarray(s, dtype=numpy.float32).tofile('samples.f32')"

                and 'Hello.' for samples-hello. Put both in \
                \(Self.goldenDirectory.path), or point MYNAH_KOKORO_GOLDEN at them.
                """)
        }
        let data = try Data(contentsOf: file)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testTheFoxSentenceIsTrimmedWhereLibrosaTrimmedIt() throws {
        let samples = try golden("samples")
        XCTAssertEqual(samples.count, 90_600, "the fixture is not the captured array")
        XCTAssertEqual(SilenceTrim.speechRange(in: samples), 8192..<78_848)
    }

    func testTheShortSentenceIsTrimmedWhereLibrosaTrimmedIt() throws {
        let samples = try golden("samples-hello")
        XCTAssertEqual(samples.count, 34_200)
        XCTAssertEqual(SilenceTrim.speechRange(in: samples), 7168..<28_160)
    }

    // MARK: Without a fixture

    private func speech(_ count: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * sin(Float($0) * 0.05) }
    }

    func testLeadingAndTrailingSilenceIsRemoved() {
        let samples = [Float](repeating: 0, count: 4096)
            + speech(8192)
            + [Float](repeating: 0, count: 4096)

        let range = SilenceTrim.speechRange(in: samples)

        // Within one frame of the true boundary in each direction — the hop
        // quantisation is the reference's behaviour, not slack in the test.
        XCTAssertGreaterThanOrEqual(range.lowerBound, 4096 - SilenceTrim.frameLength)
        XCTAssertLessThanOrEqual(range.lowerBound, 4096)
        XCTAssertGreaterThanOrEqual(range.upperBound, 4096 + 8192)
        XCTAssertLessThanOrEqual(range.upperBound, 4096 + 8192 + SilenceTrim.frameLength)
    }

    /// The boundaries land on hop multiples. This is librosa's behaviour rather
    /// than a limitation worth fixing, and matching it exactly is worth more
    /// than a tighter cut nobody can hear.
    func testBoundariesLandOnHopMultiples() {
        let samples = [Float](repeating: 0, count: 3000) + speech(9000) + [Float](repeating: 0, count: 3000)
        let range = SilenceTrim.speechRange(in: samples)

        XCTAssertEqual(range.lowerBound % SilenceTrim.hopLength, 0)
        // The end is also clamped to the sample count, so it is a hop multiple
        // or the very end of the buffer.
        XCTAssertTrue(
            range.upperBound % SilenceTrim.hopLength == 0 || range.upperBound == samples.count
        )
    }

    /// **Loud audio must come back untouched.** The reference measures against
    /// the signal's own peak, so a uniformly loud signal has nothing 60 dB below
    /// anything — and a trim that ate into it would clip real speech.
    func testUniformlyLoudAudioIsNotTrimmed() {
        let samples = speech(16_384)
        let range = SilenceTrim.speechRange(in: samples)

        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, samples.count)
    }

    /// Silence relative to the loudest frame, not to an absolute level: quiet
    /// speech is still speech, and a whisper must not be trimmed away merely
    /// for being quiet.
    func testQuietAudioIsNotTrimmedMerelyForBeingQuiet() {
        let samples = speech(16_384, amplitude: 0.002)
        let range = SilenceTrim.speechRange(in: samples)

        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, samples.count)
    }

    /// A pause in the middle is not silence to be removed — only the ends are
    /// trimmed. Splitting on internal quiet would delete the gaps between
    /// sentences.
    func testAPauseInTheMiddleIsKept() {
        let samples = speech(4096) + [Float](repeating: 0, count: 8192) + speech(4096)
        let range = SilenceTrim.speechRange(in: samples)

        XCTAssertLessThanOrEqual(range.lowerBound, SilenceTrim.hopLength)
        XCTAssertGreaterThanOrEqual(range.upperBound, samples.count - SilenceTrim.frameLength)
        XCTAssertGreaterThan(range.count, 8192, "the internal pause was removed")
    }

    // MARK: Nothing there

    /// Digital silence produces no speech range rather than a logarithm of zero.
    func testDigitalSilenceProducesAnEmptyRange() {
        XCTAssertTrue(SilenceTrim.speechRange(in: [Float](repeating: 0, count: 8192)).isEmpty)
        XCTAssertTrue(SilenceTrim.trimmed([Float](repeating: 0, count: 8192)).isEmpty)
    }

    func testAnEmptyInputIsEmptyRatherThanACrash() {
        XCTAssertTrue(SilenceTrim.speechRange(in: []).isEmpty)
        XCTAssertTrue(SilenceTrim.trimmed([]).isEmpty)
    }

    /// Shorter than a single frame, which is the case a framing loop gets wrong
    /// by reading past its buffer.
    func testAudioShorterThanOneFrameDoesNotReadPastItsBuffer() {
        for count in [1, 100, 511, 512, 513, SilenceTrim.frameLength - 1] {
            let range = SilenceTrim.speechRange(in: speech(count))
            XCTAssertLessThanOrEqual(range.upperBound, count, "\(count) samples over-ran")
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
        }
    }

    // MARK: The slice

    func testTrimmedReturnsExactlyTheRange() {
        let samples = [Float](repeating: 0, count: 4096) + speech(8192) + [Float](repeating: 0, count: 4096)
        let range = SilenceTrim.speechRange(in: samples)

        XCTAssertEqual(SilenceTrim.trimmed(samples), Array(samples[range]))
    }
}
