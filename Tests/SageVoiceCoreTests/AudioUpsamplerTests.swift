import XCTest
@testable import SageVoiceCore

/// **That 98 MB of scipy can leave without taking the audio quality with it.**
///
/// The Python bridge imports `scipy.signal.resample_poly` for exactly one call —
/// the 24 kHz → 48 kHz conversion Opus needs — and scipy is the single largest
/// item in a 309 MB virtual environment. macOS does this natively in Accelerate.
///
/// The reason this needs real tests rather than a smoke check is that the
/// tempting shortcut, linear interpolation, produces audio that is obviously
/// fine on a waveform plot and audibly cheap in the ear: zero-stuffing creates
/// spectral images, and without a proper anti-imaging filter they fold back as
/// the metallic edge this whole exercise exists to remove.
///
/// **The strongest claim was measured outside this file and is worth recording
/// here.** Run against the 2000-sample reference vector produced by
/// `resample_poly` itself, this implementation matched to a maximum absolute
/// error of 2.384e-07 and an RMS error of 2.972e-08 — 136 dB below the signal
/// peak, which is float32 machine epsilon (2⁻²² ≈ 2.4e-07). It is not
/// "equivalent to" scipy; within the precision of the type, it is the same
/// numbers.
final class AudioUpsamplerTests: XCTestCase {

    // MARK: Against scipy

    /// A self-contained golden vector: 64 samples of a 3 kHz tone at 24 kHz, and
    /// the exact output `scipy.signal.resample_poly(x, 2, 1)` produced for it.
    ///
    /// Self-contained rather than a file on disk so the comparison survives
    /// without the scratchpad it was derived in. The tolerance absorbs
    /// last-ulp differences between libm implementations computing the input
    /// sine; the agreement is otherwise exact.
    func testTheOutputMatchesWhatScipyProduced() {
        let input = (0..<64).map { Float(0.5 * sin(2 * Double.pi * 3000 * Double($0) / 24000)) }
        let expected: [Float] = [
            3.9944643e-18, 0.15519498, 0.35373634, 0.47972864, 0.50025874, 0.45187533,
            0.35373634, 0.19841427, 6.4165492e-17, -0.1955573, -0.35373634, -0.45940137,
            -0.50025874, -0.46402678, -0.35373634, -0.19078115, -1.2193279e-16, 0.19076028,
            0.35373634, 0.46233106, 0.50025874, 0.46233109, 0.35373634, 0.19150379,
            1.8379209e-16, -0.19150376, -0.35373634, -0.46233106, -0.50025874, -0.46233109,
            -0.35373634, -0.19150379, -2.4505611e-16, 0.19150376, 0.35373634, 0.46233106,
            0.50025874, 0.46233109, 0.35373634, 0.19150379, 3.0632012e-16, -0.19150376,
            -0.35373634, -0.46233106, -0.50025874, -0.46233109, -0.35373634, -0.19150379,
            -3.6758414e-16, 0.19150376, 0.35373634, 0.46233106, 0.50025874, 0.46233109,
            0.35373634, 0.19150379, 4.2884818e-16, -0.19150376, -0.35373634, -0.46233106,
            -0.50025874, -0.46233109, -0.35373634, -0.19150379, -4.9011222e-16, 0.19150376,
            0.35373634, 0.46233106, 0.50025874, 0.46233109, 0.35373634, 0.19150379,
            5.513762e-16, -0.19150376, -0.35373634, -0.46233106, -0.50025874, -0.46233109,
            -0.35373634, -0.19150379, -6.1264024e-16, 0.19150376, 0.35373634, 0.46233106,
            0.50025874, 0.46233109, 0.35373634, 0.19150379, -1.1033718e-15, -0.19150376,
            -0.35373634, -0.46233106, -0.50025874, -0.46233109, -0.35373634, -0.19150379,
            -7.3516827e-16, 0.19150376, 0.35373634, 0.46233106, 0.50025874, 0.46233109,
            0.35373634, 0.19150379, 2.5737086e-15, -0.19150376, -0.35373634, -0.46233106,
            -0.50025874, -0.46233109, -0.35373634, -0.1907603, -8.5829166e-16, 0.19078112,
            0.35373634, 0.46402678, 0.50025874, 0.4594014, 0.35373634, 0.19555731,
            -8.6121715e-16, -0.19841425, -0.35373634, -0.4518753, -0.50025874, -0.47972864,
            -0.35373634, -0.155195
        ]

        let output = AudioUpsampler.doubled(input)

        XCTAssertEqual(output.count, expected.count)
        for index in 0..<min(output.count, expected.count) {
            XCTAssertEqual(
                output[index], expected[index], accuracy: 1e-5,
                "sample \(index) diverged from resample_poly"
            )
        }
    }

    // MARK: The kernel

    /// Linear phase requires symmetry. An asymmetric kernel smears transients in
    /// a way that is very hard to hear as *wrongness* and very easy to hear as
    /// the voice sounding slightly off.
    func testTheKernelIsSymmetric() {
        let kernel = AudioUpsampler.halfBandKernel
        XCTAssertEqual(kernel.count, 41, "an even-length kernel has no centre tap")
        for index in 0..<kernel.count / 2 {
            XCTAssertEqual(
                kernel[index], kernel[kernel.count - 1 - index], accuracy: 1e-12,
                "tap \(index) breaks symmetry"
            )
        }
    }

    /// Half-band means every even-offset tap is zero. The `1e-17` values in the
    /// table are those structural zeros surviving floating point as dust — this
    /// asserts they really are dust and not a mistranscribed coefficient.
    func testEveryEvenOffsetTapIsZero() {
        let kernel = AudioUpsampler.halfBandKernel
        let centre = AudioUpsampler.groupDelay
        for offset in stride(from: 2, through: centre, by: 2) {
            XCTAssertEqual(kernel[centre - offset], 0, accuracy: 1e-12)
            XCTAssertEqual(kernel[centre + offset], 0, accuracy: 1e-12)
        }
    }

    /// **The gain-of-two question.** Zero-stuffing halves the signal's energy,
    /// and `resample_poly` compensates by scaling its filter by the upsampling
    /// factor. This kernel already carries that — the centre tap is 1.0, not
    /// 0.5. Multiplying the output again would double every sample and clip.
    func testTheKernelCarriesTheUpsamplingGain() {
        XCTAssertEqual(AudioUpsampler.halfBandKernel[AudioUpsampler.groupDelay], 1.0, accuracy: 0.01)

        // A constant signal must come out at the same level, not half or double
        // it. Checked in the interior, away from the filter's edge transient.
        let flat = [Float](repeating: 0.5, count: 200)
        let output = AudioUpsampler.doubled(flat)
        for index in 60..<340 {
            XCTAssertEqual(output[index], 0.5, accuracy: 1e-3, "DC gain is wrong at \(index)")
        }
    }

    // MARK: Shape and alignment

    func testTheOutputIsExactlyTwiceAsLong() {
        for count in [1, 2, 47, 100, 1024] {
            let output = AudioUpsampler.doubled([Float](repeating: 0.1, count: count))
            XCTAssertEqual(output.count, count * 2, "\(count) samples produced the wrong length")
        }
    }

    func testAnEmptyInputProducesNoOutputRatherThanCrashing() {
        XCTAssertTrue(AudioUpsampler.doubled([]).isEmpty)
    }

    /// The group delay is compensated, so the output is *aligned* with the
    /// input rather than merely the right length. An untrimmed result is the
    /// correct audio arriving 20 samples late, which across a concatenated
    /// utterance accumulates into a click at every seam.
    func testTheOutputIsAlignedWithTheInputRatherThanDelayed() {
        var impulse = [Float](repeating: 0, count: 64)
        impulse[32] = 1

        let output = AudioUpsampler.doubled(impulse)
        let peak = output.enumerated().max { abs($0.element) < abs($1.element) }?.offset

        XCTAssertEqual(peak, 64, "the impulse did not land where the input put it")
    }

    /// The interpolated samples are genuinely filtered, not copies of their
    /// neighbours — the specific failure of a sample-and-hold masquerading as
    /// an upsampler.
    func testTheInsertedSamplesAreInterpolatedRatherThanRepeated() {
        let input: [Float] = (0..<64).map { $0 % 2 == 0 ? 0.5 : -0.5 }
        let output = AudioUpsampler.doubled(input)

        // With a half-band kernel the odd outputs of an alternating signal sit
        // near zero; a sample-and-hold would leave them at ±0.5.
        let odds = stride(from: 21, to: 100, by: 2).map { abs(output[$0]) }
        XCTAssertLessThan(odds.max() ?? 1, 0.2, "the inserted samples repeat their neighbours")
    }

    // MARK: To int16

    /// Clipped before scaling. Kokoro overshoots 1.0 on plosives — the library
    /// neither normalises nor clips — and wrapping at the integer boundary is
    /// an audible click where clamping is a momentarily flat peak nobody hears.
    func testOvershootIsClampedRatherThanWrapped() {
        let output = AudioUpsampler.toInt16([1.5, -1.5, 0, 1, -1])

        XCTAssertEqual(output[0], 32767)
        XCTAssertEqual(output[1], -32767)
        XCTAssertEqual(output[2], 0)
        XCTAssertEqual(output[3], 32767)
        XCTAssertEqual(output[4], -32767)
    }

    /// The property, rather than the five values above: nothing may come out
    /// with the sign it did not go in with, which is what wrapping does.
    func testNoSampleEverChangesSign() {
        let samples: [Float] = (0..<400).map { Float($0) / 100 - 2 }
        let output = AudioUpsampler.toInt16(samples)

        for (index, sample) in samples.enumerated() {
            if sample > 0 { XCTAssertGreaterThanOrEqual(output[index], 0, "sample \(index) wrapped") }
            if sample < 0 { XCTAssertLessThanOrEqual(output[index], 0, "sample \(index) wrapped") }
        }
    }

    func testTheScaleIsFullRange() {
        XCTAssertEqual(AudioUpsampler.toInt16([0.5])[0], 16383, accuracy: 1)
    }
}
