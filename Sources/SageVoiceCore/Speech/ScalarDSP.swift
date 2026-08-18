import Foundation

/// The three Accelerate primitives the speech path uses, in plain Swift.
///
/// ## Why this exists
///
/// `AudioUpsampler` and `SilenceTrim` are the only two files in the package that
/// reach for `vDSP`, and between them they use exactly four calls: `vDSP_conv`,
/// `vDSP_vclip`, `vDSP_vsmul`, `vDSP_vfix16` and `vDSP_measqv`. Accelerate is
/// Apple-only, so on Linux those four calls are the whole of what
/// stands between the port and voice notes working. They are replaced here
/// rather than in the call sites so the guarded region at each call site is one
/// line and the arithmetic can be read — and checked — in one place.
///
/// ## What "equivalent" is held to mean
///
/// `AudioUpsamplerTests` compares against a golden vector produced by
/// `scipy.signal.resample_poly` with `accuracy: 1e-5`, and `SilenceTrimTests`
/// asserts *exact* sample ranges against captured Kokoro output. So these are
/// not "close enough for audio" approximations: they have to make the same
/// decisions the Accelerate versions make.
///
/// Two choices follow from that, and neither is arbitrary.
///
/// **Sums accumulate in `Double`.** vDSP accumulates in `Float` across
/// vectorised partial sums; a straight `Float` loop accumulates in a different
/// order and can drift further from the true value than vDSP does, which is the
/// one way a scalar rewrite can *lose* to the thing it replaces. Summing in
/// `Double` and narrowing once at the end is at least as accurate as either, so
/// the result sits inside the tolerance from the correct side. It matters most
/// in `meanSquare`, where a frame is 2048 terms and the answer decides a
/// threshold comparison that moves a trim boundary.
///
/// **The conversion to `Int16` truncates.** `vDSP_vfix16` rounds toward zero —
/// `vDSP_vfixr16` is the rounding one — so 0.5 becomes 16383 and not 16384.
/// `testTheScaleIsFullRange` permits either, but the WAV bytes should not
/// change depending on which machine encoded them.
///
/// Compiled on every platform, called only where Accelerate is absent. Keeping
/// it in the Darwin build costs nothing at runtime and means a mistake here is
/// a compile error on the machine the release is cut from rather than a
/// surprise in a Linux container.
enum ScalarDSP {

    /// `vDSP_conv`: `output[n] = Σₚ signal[n + p] · filter[p]`.
    ///
    /// Despite the name this is a correlation, which for the symmetric
    /// half-band kernel in `AudioUpsampler` is the same operation as a
    /// convolution. The caller is responsible for the padding — `signal` must
    /// hold at least `outputCount + filter.count - 1` elements, exactly as
    /// `vDSP_conv` requires — so this reads past `outputCount` by design.
    static func correlate(
        signal: [Float],
        filter: [Float],
        into output: inout [Float],
        outputCount: Int
    ) {
        precondition(
            signal.count >= outputCount + filter.count - 1,
            "vDSP_conv reads filter.count - 1 samples of context past the output; pad first"
        )
        precondition(output.count >= outputCount, "output is shorter than the requested length")

        let taps = filter.count
        signal.withUnsafeBufferPointer { signalBuffer in
            filter.withUnsafeBufferPointer { filterBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    guard
                        let signalBase = signalBuffer.baseAddress,
                        let filterBase = filterBuffer.baseAddress,
                        let outputBase = outputBuffer.baseAddress
                    else { return }

                    for index in 0..<outputCount {
                        var accumulator = 0.0
                        for tap in 0..<taps {
                            accumulator += Double(signalBase[index + tap]) * Double(filterBase[tap])
                        }
                        outputBase[index] = Float(accumulator)
                    }
                }
            }
        }
    }

    /// `vDSP_vclip` + `vDSP_vsmul` + `vDSP_vfix16`, fused.
    ///
    /// Fused rather than three passes because the three exist separately on the
    /// Darwin side only to keep each one vectorised; scalar code has no such
    /// reason to walk the array three times, and doing it once removes the two
    /// intermediate buffers.
    ///
    /// Clamped **before** scaling, which is the order the Darwin path uses and
    /// is the point of the exercise: Kokoro overshoots 1.0 on plosives, and
    /// wrapping at the integer boundary is an audible click where clamping is a
    /// momentarily flat peak nobody hears.
    ///
    /// A NaN survives `vDSP_vclip` on Darwin and lands as 0 in `vDSP_vfix16`;
    /// here it would trap the `Int16` initialiser, so it is mapped to 0
    /// explicitly. Neither is *correct* — a NaN sample is already a bug
    /// upstream — but a silent zero matches the shipped behaviour and a crash
    /// in the middle of speaking does not.
    static func clippedScaledInt16(
        _ samples: [Float],
        low: Float,
        high: Float,
        scale: Float
    ) -> [Int16] {
        var output = [Int16](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { result in
                guard let inputBase = input.baseAddress, let resultBase = result.baseAddress else {
                    return
                }
                for index in 0..<samples.count {
                    let sample = inputBase[index]
                    guard !sample.isNaN else {
                        resultBase[index] = 0
                        continue
                    }
                    let clamped = min(max(sample, low), high)
                    // `rounded(.towardZero)` before the initialiser rather than
                    // relying on `Int16(_:)`'s own truncation, so the intent is
                    // stated where `vDSP_vfix16` states it.
                    let scaled = (clamped * scale).rounded(.towardZero)
                    resultBase[index] = Int16(scaled)
                }
            }
        }
        return output
    }

    /// `vDSP_measqv`: the mean of the squares of `count` values.
    ///
    /// Not the root — `SilenceTrim` takes that itself, because `librosa`'s
    /// threshold is expressed in power and the square root is only needed for
    /// the RMS it reports.
    static func meanSquare(_ values: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var accumulator = 0.0
        for index in 0..<count {
            let value = Double(values[index])
            accumulator += value * value
        }
        return Float(accumulator / Double(count))
    }
}
