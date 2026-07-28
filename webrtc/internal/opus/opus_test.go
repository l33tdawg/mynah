package opus

import (
	"math"
	"testing"
)

// A tone survives the round trip.
//
// Opus is lossy, so this cannot compare samples. What it can prove is that the
// thing coming out is the thing that went in: a 440 Hz tone in must be a 440 Hz
// tone out, at roughly the level it was sent. That catches the failures that
// actually happen — a codec configured at the wrong sample rate, a channel count
// mismatch, samples interpreted as the wrong width — each of which produces
// audio that decodes without error and sounds like nothing.
func TestAToneSurvivesEncodingAndDecoding(t *testing.T) {
	encoder, err := NewEncoder()
	if err != nil {
		t.Fatalf("encoder: %v", err)
	}
	defer encoder.Close()

	decoder, err := NewDecoder()
	if err != nil {
		t.Fatalf("decoder: %v", err)
	}
	defer decoder.Close()

	const frame = SampleRate / 50 // 20 ms, what a browser sends.
	const tone = 440.0

	// Opus needs a few frames before its output settles; the first carry the
	// codec's own start-up transient rather than the signal.
	var decoded []int16
	for f := 0; f < 25; f++ {
		samples := make([]int16, frame)
		for i := range samples {
			at := float64(f*frame+i) / float64(SampleRate)
			samples[i] = int16(8000 * math.Sin(2*math.Pi*tone*at))
		}
		packet, err := encoder.Encode(samples)
		if err != nil {
			t.Fatalf("encode: %v", err)
		}
		if len(packet) == 0 {
			t.Fatal("encoded to nothing")
		}
		out, err := decoder.Decode(packet)
		if err != nil {
			t.Fatalf("decode: %v", err)
		}
		if len(out) != frame {
			t.Fatalf("decoded %d samples from a %d-sample frame", len(out), frame)
		}
		decoded = append(decoded, out...)
	}

	// Level, over the settled tail. Silence here is the signature of a codec
	// that ran without complaint and produced nothing.
	tail := decoded[len(decoded)-frame*10:]
	var energy float64
	for _, sample := range tail {
		energy += float64(sample) * float64(sample)
	}
	level := math.Sqrt(energy / float64(len(tail)))
	if level < 1000 {
		t.Fatalf("decoded audio is near silent (rms %.0f); the codec produced nothing usable", level)
	}

	// Frequency, by counting zero crossings. A rate or width mismatch keeps the
	// energy and moves the pitch, which no amount of level checking would catch.
	crossings := 0
	for i := 1; i < len(tail); i++ {
		if (tail[i-1] < 0) != (tail[i] < 0) {
			crossings++
		}
	}
	measured := float64(crossings) / 2 * (float64(SampleRate) / float64(len(tail)))
	if measured < tone*0.9 || measured > tone*1.1 {
		t.Fatalf("decoded tone is %.0f Hz, sent %.0f Hz: the codec is not at %d Hz mono",
			measured, tone, SampleRate)
	}
}

// A lost packet is concealed rather than dropped.
func TestAMissingPacketIsConcealed(t *testing.T) {
	decoder, err := NewDecoder()
	if err != nil {
		t.Fatalf("decoder: %v", err)
	}
	defer decoder.Close()

	const frame = SampleRate / 50
	concealed, err := decoder.DecodeMissing(frame)
	if err != nil {
		t.Fatalf("conceal: %v", err)
	}
	if len(concealed) != frame {
		t.Fatalf("concealed %d samples, wanted %d", len(concealed), frame)
	}
}

// The encoder must not fall silent when the caller does.
//
// DTX saves bandwidth by stopping transmission during silence. At the far end
// that is indistinguishable from a call that has died — which is exactly the
// anxiety an assistant must not create in the seconds while it is thinking.
func TestSilenceIsStillTransmitted(t *testing.T) {
	encoder, err := NewEncoder()
	if err != nil {
		t.Fatalf("encoder: %v", err)
	}
	defer encoder.Close()

	silence := make([]int16, SampleRate/50)
	for i := 0; i < 20; i++ {
		packet, err := encoder.Encode(silence)
		if err != nil {
			t.Fatalf("encode: %v", err)
		}
		// A DTX packet is one or two bytes. Anything larger is a real frame.
		if i > 5 && len(packet) <= 2 {
			t.Fatalf("frame %d encoded to %d bytes: the encoder has stopped "+
				"transmitting during silence, which sounds like a dropped call", i, len(packet))
		}
	}
}
