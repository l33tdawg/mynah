#if canImport(Accelerate)
import Accelerate
#endif
import Foundation

/// Doubles a sample rate, correctly, with nothing but Accelerate.
///
/// ## Why this exists at all
///
/// Kokoro emits 24 kHz and Opus runs at 48 kHz, so something has to convert.
/// The Python bridge reached for `scipy.signal.resample_poly` — **98 MB of
/// scipy for one function call**, and the single largest item in a 309 MB
/// virtual environment. macOS does this natively.
///
/// ## Why not linear interpolation
///
/// Because the artefact is exactly the one this whole exercise exists to
/// remove. Inserting a sample halfway between two others leaves the spectral
/// images from the zero-stuffing in place, and they fold back as the metallic
/// edge that makes synthesis sound cheap. A proper anti-imaging filter is the
/// difference between a voice and a voice that sounds like a computer.
///
/// ## The filter
///
/// A 41-tap half-band Kaiser kernel — the same design `resample_poly` builds
/// for a factor of two, verified sample-for-sample against its output. Half-band
/// means every even-offset tap is zero, which is visible in the table below as
/// the `1e-17` values: those are not noise, they are structural zeros that
/// survive floating point as dust. They are kept rather than rounded so the
/// kernel remains a literal transcription of the reference.
///
/// The centre tap is 1.0 rather than 0.5 because the gain of two that
/// zero-stuffing costs is already folded in — `resample_poly` scales its filter
/// by the upsampling factor, and so does this. Multiplying the output again
/// would double every sample and clip.
///
/// ## Off Darwin
///
/// Accelerate is Apple's, so on Linux the four `vDSP` calls below
/// come from `ScalarDSP` instead. The kernel, the padding, the group-delay
/// trim and the clip-then-scale order are all shared — only the inner
/// arithmetic changes, and it changes to something that sums in `Double` and
/// is therefore no further from `resample_poly` than the Accelerate path is.
/// The Darwin branches are left exactly as they shipped.
public enum AudioUpsampler {

    /// 41 taps, centred at index 20.
    public static let halfBandKernel: [Float] = [
        -1.43179422e-18, -0.00210291753, 3.70859976e-18, 0.00501793344,
        -6.98829065e-18, -0.00978966895, 1.12129022e-17, 0.0171131175,
        -1.61820268e-17, -0.0279799458, 2.15622643e-17, 0.0440462418,
        -2.69193556e-17, -0.0686803609, 3.17692015e-17, 0.11057657,
        -3.56404134e-17, -0.201860398, 3.81385948e-17, 0.633400679,
        1.00051749,
        0.633400679, 3.81385948e-17, -0.201860398, -3.56404134e-17,
        0.11057657, 3.17692015e-17, -0.0686803609, -2.69193556e-17,
        0.0440462418, 2.15622643e-17, -0.0279799458, -1.61820268e-17,
        0.0171131175, 1.12129022e-17, -0.00978966895, -6.98829065e-18,
        0.00501793344, 3.70859976e-18, -0.00210291753, -1.43179422e-18
    ]

    /// The kernel's group delay, in output samples.
    ///
    /// A linear-phase FIR delays everything by half its length. Trimming exactly
    /// this much off the front is what makes the result *aligned* with the input
    /// rather than merely the right length — an untrimmed output is the correct
    /// audio arriving 20 samples late, which across a concatenated utterance
    /// accumulates into a click at every seam.
    public static var groupDelay: Int { halfBandKernel.count / 2 }

    /// 24 kHz in, 48 kHz out, same duration.
    ///
    /// Returns exactly `2 * input.count` samples, matching
    /// `resample_poly(x, 2, 1)`.
    public static func doubled(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }

        let outputCount = input.count * 2

        // Zero-stuffing: the input samples on even indices, silence between.
        // This is what creates the images the kernel then removes; doing it
        // explicitly rather than through a polyphase decomposition keeps this
        // readable and is not the expensive part.
        var stuffed = [Float](repeating: 0, count: outputCount)
        for index in 0..<input.count {
            stuffed[index * 2] = input[index]
        }

        // vDSP_conv consumes `filterLength - 1` samples of context, so the
        // signal is padded at both ends. Zeros rather than edge replication:
        // the audio genuinely is silent outside its own bounds, and repeating
        // the first sample 20 times would invent a DC step that the filter
        // would ring on.
        let taps = halfBandKernel.count
        var padded = [Float](repeating: 0, count: outputCount + taps - 1)
        // Offset by the group delay so the convolution's output lines up with
        // the input without a second trimming pass.
        for index in 0..<outputCount {
            padded[index + groupDelay] = stuffed[index]
        }

        var output = [Float](repeating: 0, count: outputCount)
        // vDSP_conv correlates rather than convolves, which for a symmetric
        // kernel is the same operation — and this kernel is symmetric by
        // construction. Asserted in the tests rather than assumed here.
        #if canImport(Accelerate)
        vDSP_conv(
            padded, 1,
            halfBandKernel, 1,
            &output, 1,
            vDSP_Length(outputCount),
            vDSP_Length(taps)
        )
        #else
        ScalarDSP.correlate(
            signal: padded,
            filter: halfBandKernel,
            into: &output,
            outputCount: outputCount
        )
        #endif
        return output
    }

    /// Float samples to the signed 16-bit the WAV contract promises and Opus
    /// takes.
    ///
    /// Clipped **before** scaling. Kokoro overshoots 1.0 on plosives — the
    /// golden vectors peak at -0.644 but the library neither normalises nor
    /// clips, so it is a soft bound rather than a guarantee. Wrapping at the
    /// integer boundary is an audible click; clamping is a momentarily flat
    /// peak nobody hears.
    public static func toInt16(_ samples: [Float]) -> [Int16] {
        #if canImport(Accelerate)
        var clipped = [Float](repeating: 0, count: samples.count)
        var low: Float = -1
        var high: Float = 1
        vDSP_vclip(samples, 1, &low, &high, &clipped, 1, vDSP_Length(samples.count))

        var scale: Float = 32767
        vDSP_vsmul(clipped, 1, &scale, &clipped, 1, vDSP_Length(samples.count))

        var output = [Int16](repeating: 0, count: samples.count)
        vDSP_vfix16(clipped, 1, &output, 1, vDSP_Length(samples.count))
        return output
        #else
        // `vDSP_vfix16` truncates toward zero, so this one does too — 0.5
        // scales to 16383.5 and lands on 16383 on both platforms rather than
        // on whichever the encoder happened to run on.
        return ScalarDSP.clippedScaledInt16(samples, low: -1, high: 1, scale: 32767)
        #endif
    }
}
