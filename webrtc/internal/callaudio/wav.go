package callaudio

import (
	"bytes"
	"encoding/binary"
	"math"
)

// RecognitionRate is what the utterance is resampled to before it is sent up.
//
// Whisper works at 16 kHz and the whisper.cpp command backend refuses anything
// else outright. The hosted WhisperKit helper would resample internally, but
// relying on that would make the fallback backend fail on exactly the audio the
// primary one accepted — a difference that would only appear once the primary
// was already broken.
const RecognitionRate = 16000

// WAV wraps samples in the header a transcriber expects.
func WAV(samples []int16, sampleRate int) []byte {
	const channels, bitsPerSample = 1, 16
	dataBytes := len(samples) * 2
	byteRate := sampleRate * channels * bitsPerSample / 8

	buffer := new(bytes.Buffer)
	buffer.Grow(44 + dataBytes)
	buffer.WriteString("RIFF")
	_ = binary.Write(buffer, binary.LittleEndian, uint32(36+dataBytes))
	buffer.WriteString("WAVEfmt ")
	_ = binary.Write(buffer, binary.LittleEndian, uint32(16))
	_ = binary.Write(buffer, binary.LittleEndian, uint16(1)) // PCM
	_ = binary.Write(buffer, binary.LittleEndian, uint16(channels))
	_ = binary.Write(buffer, binary.LittleEndian, uint32(sampleRate))
	_ = binary.Write(buffer, binary.LittleEndian, uint32(byteRate))
	_ = binary.Write(buffer, binary.LittleEndian, uint16(channels*bitsPerSample/8))
	_ = binary.Write(buffer, binary.LittleEndian, uint16(bitsPerSample))
	buffer.WriteString("data")
	_ = binary.Write(buffer, binary.LittleEndian, uint32(dataBytes))
	for _, sample := range samples {
		_ = binary.Write(buffer, binary.LittleEndian, sample)
	}
	return buffer.Bytes()
}

// lowPass is a 31-tap windowed-sinc filter for 48 kHz → 16 kHz.
//
// Decimation without it is the classic mistake: dropping two samples in three
// folds everything above 8 kHz back down into the band as noise that sounds
// like nothing in particular and costs recognition accuracy on exactly the
// consonants that distinguish similar words. A box average over three samples —
// the tempting one-liner — is a filter, but a poor one that leaves most of the
// offending energy in place.
//
// Cut at 7.6 kHz rather than the 8 kHz Nyquist limit, leaving the transition
// band room to roll off before it folds. Speech has little left up there, and
// what it does have is not worth the aliasing.
var lowPass = buildLowPass(31, 7600.0/48000.0)

func buildLowPass(taps int, cutoff float64) []float64 {
	filter := make([]float64, taps)
	middle := float64(taps-1) / 2
	var total float64
	for i := range filter {
		offset := float64(i) - middle
		var value float64
		if offset == 0 {
			value = 2 * cutoff
		} else {
			value = math.Sin(2*math.Pi*cutoff*offset) / (math.Pi * offset)
		}
		// Hamming window, to trade a little transition width for stopband
		// rejection deep enough that the aliasing is genuinely inaudible.
		value *= 0.54 - 0.46*math.Cos(2*math.Pi*float64(i)/float64(taps-1))
		filter[i] = value
		total += value
	}
	for i := range filter {
		filter[i] /= total
	}
	return filter
}

// Downsample converts 48 kHz to 16 kHz.
//
// Fixed ratio rather than general resampling: 48 and 16 divide exactly, and a
// rate converter that handles arbitrary ratios would add interpolation error to
// a conversion that needs none.
func Downsample(samples []int16) []int16 {
	const ratio = 3
	if len(samples) == 0 {
		return nil
	}
	out := make([]int16, 0, len(samples)/ratio+1)
	half := len(lowPass) / 2
	for centre := 0; centre < len(samples); centre += ratio {
		var sum float64
		for tap, weight := range lowPass {
			at := centre + tap - half
			// Edges are clamped rather than zero-padded: zeros at the start of
			// an utterance are a step the filter rings on, and that ring lands
			// on the first syllable.
			switch {
			case at < 0:
				at = 0
			case at >= len(samples):
				at = len(samples) - 1
			}
			sum += float64(samples[at]) * weight
		}
		out = append(out, clamp(sum))
	}
	return out
}

func clamp(value float64) int16 {
	switch {
	case value > math.MaxInt16:
		return math.MaxInt16
	case value < math.MinInt16:
		return math.MinInt16
	default:
		return int16(math.Round(value))
	}
}
