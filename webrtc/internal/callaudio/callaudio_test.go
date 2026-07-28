package callaudio

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"testing"
)

func TestFramesRoundTripInOrder(t *testing.T) {
	pipe := new(bytes.Buffer)

	sent := []struct {
		kind    Kind
		payload []byte
	}{
		{KindUtterance, []byte("a wav would go here")},
		{KindReplyAudio, Bytes([]int16{1, -1, 32767, -32768})},
		{KindReplyEnd, nil},
		{KindInterrupted, nil},
	}
	for _, frame := range sent {
		if err := WriteFrame(pipe, frame.kind, frame.payload); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	for _, want := range sent {
		kind, payload, err := ReadFrame(pipe)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if kind != want.kind {
			t.Fatalf("got kind %d, wanted %d", kind, want.kind)
		}
		if !bytes.Equal(payload, want.payload) {
			t.Fatalf("payload for kind %d did not survive", kind)
		}
	}

	if _, _, err := ReadFrame(pipe); !errors.Is(err, io.EOF) {
		t.Fatalf("a clean close should read as EOF, got %v", err)
	}
}

// A peer that dies mid-frame must not look like one that hung up.
//
// Both leave a closed socket. One is the far side finishing a call, the other is
// it crashing during a sentence — and treating them alike files a crash as a
// hang-up, which is how a broken appliance looks healthy in a log.
func TestATruncatedFrameIsNotACleanClose(t *testing.T) {
	whole := new(bytes.Buffer)
	if err := WriteFrame(whole, KindUtterance, []byte("half of this will arrive")); err != nil {
		t.Fatalf("write: %v", err)
	}
	truncated := bytes.NewReader(whole.Bytes()[:12])

	if _, _, err := ReadFrame(truncated); !errors.Is(err, ErrShortFrame) {
		t.Fatalf("expected ErrShortFrame for a frame cut in half, got %v", err)
	}
}

// A frame header claiming an absurd length must be refused, not allocated.
func TestAnOversizedFrameIsRefused(t *testing.T) {
	var header [5]byte
	header[0] = byte(KindReplyAudio)
	binary.BigEndian.PutUint32(header[1:], math.MaxUint32)

	if _, _, err := ReadFrame(bytes.NewReader(header[:])); err == nil {
		t.Fatal("a frame claiming 4 GB was accepted")
	}
}

func TestSamplesSurviveTheWire(t *testing.T) {
	original := []int16{0, 1, -1, 1000, -1000, math.MaxInt16, math.MinInt16}
	recovered := Samples(Bytes(original))
	if len(recovered) != len(original) {
		t.Fatalf("got %d samples, sent %d", len(recovered), len(original))
	}
	for i := range original {
		if recovered[i] != original[i] {
			t.Fatalf("sample %d became %d, was %d", i, recovered[i], original[i])
		}
	}
}

func TestWAVHeaderDescribesTheAudio(t *testing.T) {
	samples := make([]int16, 16000) // one second at 16 kHz
	wav := WAV(samples, RecognitionRate)

	if string(wav[0:4]) != "RIFF" || string(wav[8:12]) != "WAVE" {
		t.Fatal("that is not a WAV")
	}
	if rate := binary.LittleEndian.Uint32(wav[24:28]); rate != RecognitionRate {
		t.Fatalf("header says %d Hz, wanted %d — whisper.cpp refuses anything else", rate, RecognitionRate)
	}
	if channels := binary.LittleEndian.Uint16(wav[22:24]); channels != 1 {
		t.Fatalf("header says %d channels, wanted mono", channels)
	}
	if size := binary.LittleEndian.Uint32(wav[40:44]); int(size) != len(samples)*2 {
		t.Fatalf("data chunk claims %d bytes for %d samples", size, len(samples))
	}
}

// Downsampling must keep a tone in the speech band.
func TestDownsamplingPreservesSpeech(t *testing.T) {
	const source = 48000
	const tone = 1000.0 // Solidly inside the band that carries speech.

	samples := make([]int16, source) // one second
	for i := range samples {
		samples[i] = int16(8000 * math.Sin(2*math.Pi*tone*float64(i)/source))
	}

	out := Downsample(samples)
	if len(out) < RecognitionRate-10 || len(out) > RecognitionRate+10 {
		t.Fatalf("one second became %d samples, wanted about %d", len(out), RecognitionRate)
	}

	// Middle only, away from the clamped edges.
	middle := out[2000 : len(out)-2000]
	crossings := 0
	for i := 1; i < len(middle); i++ {
		if (middle[i-1] < 0) != (middle[i] < 0) {
			crossings++
		}
	}
	measured := float64(crossings) / 2 * (float64(RecognitionRate) / float64(len(middle)))
	if measured < tone*0.95 || measured > tone*1.05 {
		t.Fatalf("a %.0f Hz tone came out at %.0f Hz", tone, measured)
	}

	var energy float64
	for _, sample := range middle {
		energy += float64(sample) * float64(sample)
	}
	if level := math.Sqrt(energy / float64(len(middle))); level < 3000 {
		t.Fatalf("the tone lost most of its level (rms %.0f, sent about 5657)", level)
	}
}

// The filter has to be there, and this is the test that proves it.
//
// A 12 kHz tone cannot exist at 16 kHz. Decimate without filtering and it does
// not vanish — it folds down to 4 kHz and sits in the middle of the speech band
// as energy that was never spoken, degrading exactly the consonants that
// separate similar words.
func TestHighFrequenciesAreFilteredNotFolded(t *testing.T) {
	const source = 48000
	const tone = 12000.0

	samples := make([]int16, source)
	for i := range samples {
		samples[i] = int16(8000 * math.Sin(2*math.Pi*tone*float64(i)/source))
	}

	out := Downsample(samples)
	middle := out[2000 : len(out)-2000]

	var energy float64
	for _, sample := range middle {
		energy += float64(sample) * float64(sample)
	}
	level := math.Sqrt(energy / float64(len(middle)))

	// Sent at about 5657 rms. Anything close to that means the tone aliased
	// straight through rather than being removed.
	if level > 500 {
		t.Fatalf("a 12 kHz tone survived downsampling at rms %.0f: it has aliased "+
			"to 4 kHz, into the middle of the speech band", level)
	}
}
