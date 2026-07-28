package speech

import (
	"math"
	"math/rand"
	"testing"
)

// speech builds a frame that sounds like a voice: loud, and not a pure tone.
func speech(seed int64, amplitude float64) []int16 {
	random := rand.New(rand.NewSource(seed)) //nolint:gosec // Test signal, not a secret.
	frame := make([]int16, FrameSamples)
	for i := range frame {
		at := float64(i) / SampleRate
		value := amplitude * (0.6*math.Sin(2*math.Pi*180*at) + 0.4*random.NormFloat64()*0.3)
		frame[i] = int16(math.Max(-32768, math.Min(32767, value)))
	}
	return frame
}

// room is a quiet line: the residue left after the browser's noise suppression.
func room(seed int64) []int16 {
	random := rand.New(rand.NewSource(seed)) //nolint:gosec // Test signal.
	frame := make([]int16, FrameSamples)
	for i := range frame {
		frame[i] = int16(random.NormFloat64() * 20)
	}
	return frame
}

func feed(t *testing.T, segmenter *Segmenter, frames [][]int16) []Event {
	t.Helper()
	var events []Event
	for _, frame := range frames {
		if event := segmenter.Push(frame); event != EventNone {
			events = append(events, event)
		}
	}
	return events
}

func repeat(build func(int64) []int16, count int, seed int64) [][]int16 {
	frames := make([][]int16, count)
	for i := range frames {
		frames[i] = build(seed + int64(i))
	}
	return frames
}

// The plain case: quiet, someone talks, they stop, one utterance comes out.
func TestOneSentenceBecomesOneUtterance(t *testing.T) {
	segmenter := NewSegmenter(DefaultSettings())

	var frames [][]int16
	frames = append(frames, repeat(room, 40, 1)...)                                               // settle
	frames = append(frames, repeat(func(s int64) []int16 { return speech(s, 6000) }, 60, 100)...) // ~1.2 s
	frames = append(frames, repeat(room, 50, 500)...)                                             // 1 s quiet

	events := feed(t, segmenter, frames)

	if len(events) != 2 || events[0] != EventSpeechStarted || events[1] != EventUtteranceComplete {
		t.Fatalf("expected a start then a complete, got %v", events)
	}
	if got := len(segmenter.Utterance()); got < 60*FrameSamples {
		t.Fatalf("utterance is %d samples, shorter than the %d spoken: speech was cut",
			got, 60*FrameSamples)
	}
}

// The beginning of a sentence must survive.
//
// Detection is retrospective — by the time speech is confirmed the first
// consonant has already passed — so without pre-roll every utterance reaches
// recognition with its opening shaved off.
func TestTheStartOfSpeechIsNotClipped(t *testing.T) {
	segmenter := NewSegmenter(DefaultSettings())

	var frames [][]int16
	frames = append(frames, repeat(room, 40, 1)...)
	frames = append(frames, repeat(func(s int64) []int16 { return speech(s, 6000) }, 30, 100)...)
	frames = append(frames, repeat(room, 50, 500)...)
	feed(t, segmenter, frames)

	// 30 frames were spoken. With pre-roll the utterance must exceed that,
	// because it reaches back before detection fired.
	spoken := 30 * FrameSamples
	if got := len(segmenter.Utterance()); got <= spoken {
		t.Fatalf("utterance is %d samples for %d spoken: no pre-roll, so the "+
			"first syllable is missing", got, spoken)
	}
}

// A pause inside a sentence must not end it.
//
// The pause before naming something is longer than people think, and splitting
// there produces two half-questions instead of one whole one.
func TestAPauseForThoughtDoesNotEndTheUtterance(t *testing.T) {
	segmenter := NewSegmenter(DefaultSettings())

	var frames [][]int16
	frames = append(frames, repeat(room, 40, 1)...)
	frames = append(frames, repeat(func(s int64) []int16 { return speech(s, 6000) }, 25, 100)...)
	frames = append(frames, repeat(room, 20, 300)...) // 400 ms — a thinking pause
	frames = append(frames, repeat(func(s int64) []int16 { return speech(s, 6000) }, 25, 700)...)
	frames = append(frames, repeat(room, 50, 900)...)

	events := feed(t, segmenter, frames)

	completions := 0
	for _, event := range events {
		if event == EventUtteranceComplete {
			completions++
		}
	}
	if completions != 1 {
		t.Fatalf("a 400 ms pause produced %d utterances; it must produce one", completions)
	}
}

// A noisy line must not read as speech.
//
// The threshold is relative to a tracked floor precisely so that a caller in a
// car or a café does not have every frame treated as talking — which would open
// an utterance that never closes.
func TestAConsistentlyNoisyLineIsNotSpeech(t *testing.T) {
	segmenter := NewSegmenter(DefaultSettings())

	// Loud, steady, and unlike a voice — the level of a fan or road noise.
	noisy := func(seed int64) []int16 {
		random := rand.New(rand.NewSource(seed)) //nolint:gosec // Test signal.
		frame := make([]int16, FrameSamples)
		for i := range frame {
			frame[i] = int16(random.NormFloat64() * 400)
		}
		return frame
	}

	events := feed(t, segmenter, repeat(noisy, 200, 1))
	for _, event := range events {
		if event == EventUtteranceComplete {
			t.Fatal("steady background noise was segmented as speech")
		}
	}
}

// Interruption depends on speech being reported as it starts, not when it ends.
//
// If the appliance only learned about the caller once the utterance completed,
// it would talk over them for the whole sentence and then stop — which is worse
// than not supporting interruption at all.
func TestSpeechIsReportedImmediatelyForInterruption(t *testing.T) {
	segmenter := NewSegmenter(DefaultSettings())
	feed(t, segmenter, repeat(room, 40, 1))

	settings := DefaultSettings()
	for i := 0; i < settings.StartFrames; i++ {
		event := segmenter.Push(speech(int64(100+i), 6000))
		if event == EventSpeechStarted {
			if !segmenter.Speaking() {
				t.Fatal("speech was reported as started but Speaking() is false")
			}
			return
		}
	}
	t.Fatalf("speech was not reported within %d frames (%d ms); interruption "+
		"would lag by the length of the sentence",
		settings.StartFrames, settings.StartFrames*20)
}

// A microphone that never goes quiet must not grow without limit.
func TestAnEndlessUtteranceIsCutOff(t *testing.T) {
	settings := DefaultSettings()
	settings.MaximumFrames = 50 // 1 s, to keep the test quick
	segmenter := NewSegmenter(settings)

	frames := repeat(func(s int64) []int16 { return speech(s, 6000) }, 300, 1)
	events := feed(t, segmenter, frames)

	completions := 0
	for _, event := range events {
		if event == EventUtteranceComplete {
			completions++
		}
	}
	if completions == 0 {
		t.Fatal("six seconds of unbroken speech never produced an utterance")
	}
}
