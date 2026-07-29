import Accelerate
import Foundation

/// Removes the silence Kokoro leaves at the start and end of every utterance.
///
/// ## Why this has to exist rather than be skipped
///
/// The model pads. On the sentence used as this port's reference it emitted
/// 90,600 samples of which only 70,656 are speech — **a fifth of every
/// utterance is silence**, and on the short one it is closer to two fifths.
/// Left in, each spoken reply begins with a third of a second of nothing, and
/// on a call that reads as the appliance having failed to answer.
///
/// It matters more than that for long text. `kokoro_onnx` synthesizes in
/// batches and joins them with a plain concatenation — no crossfade, no gap —
/// so an untrimmed batch contributes its padding to the *middle* of the
/// sentence, and the speech develops pauses in places nobody wrote one.
///
/// ## What this is a translation of
///
/// `librosa.effects.trim` at its defaults, as vendored into `kokoro_onnx/trim.py`
/// — frame length 2048, hop 512, threshold 60 dB below the loudest frame, RMS
/// per frame with centred framing and zero padding. It is reproduced faithfully
/// rather than improved on, including the detail that boundaries land on
/// multiples of the hop: 512-sample quantisation is audible as nothing at all,
/// and matching the reference exactly is worth more here than a tighter cut.
public enum SilenceTrim {

    public static let frameLength = 2048
    public static let hopLength = 512
    /// Frames quieter than this far below the loudest frame are silence.
    public static let topDecibels: Float = 60
    /// `librosa`'s floor, squared — `amplitude_to_db` passes `amin: 1e-5` down
    /// to `power_to_db` as `amin**2`. It stops a digitally silent frame taking
    /// the logarithm to negative infinity.
    public static let minimumPower: Float = 1e-10

    /// The span of `samples` that is speech.
    ///
    /// Returned as a range rather than a copied array so a caller that only
    /// wants to know where the speech is does not pay for the slice.
    /// `0..<0` when every frame is below the threshold.
    public static func speechRange(in samples: [Float]) -> Range<Int> {
        guard !samples.isEmpty else { return 0..<0 }

        let energies = frameRMS(samples)
        guard let loudest = energies.max(), loudest > 0 else { return 0..<0 }

        // 10·log10(max(amin, rms²)) − 10·log10(max(amin, peak²)) > −topDb,
        // written as a comparison against a threshold so the logarithm is taken
        // once instead of per frame.
        let reference = 10 * log10(max(minimumPower, loudest * loudest))
        let cutoff = reference - topDecibels

        var first: Int?
        var last: Int?
        for (index, rms) in energies.enumerated() {
            let decibels = 10 * log10(max(minimumPower, rms * rms))
            guard decibels > cutoff else { continue }
            if first == nil { first = index }
            last = index
        }

        guard let first, let last else { return 0..<0 }
        let start = first * hopLength
        // One frame past the last loud one, because the frame is evidence about
        // a window of samples rather than about its first sample.
        let end = min(samples.count, (last + 1) * hopLength)
        return start..<max(start, end)
    }

    /// The speech, with the silence removed.
    public static func trimmed(_ samples: [Float]) -> [Float] {
        let range = speechRange(in: samples)
        guard !range.isEmpty else { return [] }
        return Array(samples[range])
    }

    /// Root-mean-square per analysis frame, with centred framing.
    ///
    /// Centred means the signal is padded by half a frame at each end, so frame
    /// `i` is centred on sample `i · hop` rather than starting there. That is
    /// what puts the boundaries on hop multiples and it is why the first frame
    /// is half silence by construction.
    static func frameRMS(_ samples: [Float]) -> [Float] {
        let half = frameLength / 2
        var padded = [Float](repeating: 0, count: samples.count + frameLength)
        padded.replaceSubrange(half..<(half + samples.count), with: samples)

        let frames = 1 + samples.count / hopLength
        var energies = [Float](repeating: 0, count: frames)

        padded.withUnsafeBufferPointer { buffer in
            for index in 0..<frames {
                let start = index * hopLength
                // The last frame can run past the padded buffer when the sample
                // count is not a multiple of the hop; librosa's framing simply
                // does not produce that frame, so it is measured over whatever
                // is genuinely there.
                let length = min(frameLength, buffer.count - start)
                guard length > 0 else { continue }
                var mean: Float = 0
                vDSP_measqv(buffer.baseAddress! + start, 1, &mean, vDSP_Length(length))
                energies[index] = sqrt(mean)
            }
        }
        return energies
    }
}
