// Package speech decides when the caller has started and stopped talking.
//
// This is the part that makes a call feel alive or broken, and almost none of it
// is about audio quality. Cut too early and the appliance answers half a
// sentence. Cut too late and every exchange carries a pause the caller reads as
// the thing not having heard them. Recognition accuracy and model speed are both
// downstream of getting this right, and neither can compensate for it.
//
// # Why energy rather than a model
//
// The browser has already done the hard part. WebRTC's getUserMedia applies echo
// cancellation, noise suppression and automatic gain before a single packet is
// sent, so what arrives here is a gated, levelled signal with the room and the
// appliance's own voice removed. A neural detector would spend milliseconds per
// frame re-deciding something the phone already decided, and would need to be
// bundled, versioned and loaded.
//
// The noise floor is still tracked rather than assumed, because AGC means the
// residual level differs per phone, per room, and drifts within one call.
package speech

import "math"

const (
	// The rate everything here runs at. Opus decodes to 48 kHz and there is no
	// reason to resample before deciding whether someone is talking.
	SampleRate = 48000

	// One analysis frame. Matches what a browser sends per packet, so a frame is
	// exactly one arriving packet and no buffering straddles a boundary.
	FrameSamples = SampleRate / 50 // 20 ms
)

// Settings tune the boundaries. The defaults are the interesting part.
type Settings struct {
	// How much louder than the noise floor counts as speech. In amplitude, so
	// 2.5 is roughly 8 dB — enough to ignore a room, low enough to catch someone
	// who trails off at the end of a sentence rather than truncating them.
	SpeechFactor float64

	// A floor under that ratio, so a silent line does not make the detector
	// infinitely sensitive to its own dither. Without this, a phone on mute in a
	// quiet room eventually triggers on nothing.
	MinimumLevel float64

	// How long speech must persist before an utterance opens. Two frames of
	// 20 ms rejects a cough or a door without adding latency anyone can feel.
	StartFrames int

	// How long silence must persist before an utterance closes.
	//
	// The single most consequential number here. Below about 500 ms it cuts
	// people off mid-thought — the pause before naming something is longer than
	// people believe. Above about a second the appliance feels slow to react.
	// 700 ms is the compromise, chosen to fail toward hearing the whole sentence,
	// because a truncated question wastes a whole turn and a slight pause does
	// not.
	SilenceFrames int

	// A hard cap, so a stuck-open microphone or a caller reading aloud does not
	// grow a buffer without limit. Reached, it closes the utterance and lets the
	// next one start; the caller experiences a reply mid-monologue rather than a
	// call that stops working.
	MaximumFrames int

	// How much louder speech must be to interrupt the appliance.
	//
	// Echo cancellation in the browser is good and not perfect. Enough of the
	// appliance's own voice returns through the phone — especially on
	// speakerphone, where the microphone hears the speaker directly — to clear
	// the ordinary speech threshold. Observed live: every single reply was
	// followed by an interruption the caller never made, and the appliance cut
	// itself off mid-answer.
	//
	// So interrupting costs more than starting. The residue is a fraction of the
	// original; a person talking into their phone is not.
	EchoFactor float64

	// How long speech must persist to interrupt, rather than merely to start.
	//
	// The other half of the same problem. Residual echo arrives in bursts that
	// track the appliance's own speech rhythm, so a threshold alone still trips
	// on the loud syllables. Requiring a quarter second of sustained sound
	// rejects that while staying well inside what a person notices — it is about
	// how long it takes to say "no, wait".
	InterruptFrames int

	// Audio kept from before speech was detected.
	//
	// Detection is retrospective: by the time two frames have exceeded the
	// threshold, the first consonant is already past. Without this every
	// utterance arrives at recognition with its beginning shaved off, and
	// "Send that to Maya" becomes "end that to Maya".
	PrerollFrames int
}

func DefaultSettings() Settings {
	return Settings{
		SpeechFactor:    2.5,
		MinimumLevel:    180,
		StartFrames:     2,  // 40 ms
		SilenceFrames:   35, // 700 ms
		EchoFactor:      3.0,
		InterruptFrames: 12,      // 240 ms
		MaximumFrames:   50 * 30, // 30 s
		PrerollFrames:   15,      // 300 ms
	}
}

// Event is what the segmenter noticed in a frame.
type Event int

const (
	// Nothing worth acting on.
	EventNone Event = iota
	// The caller started talking. Emitted the moment speech is confirmed, before
	// the utterance is complete, because this is what interrupts the appliance
	// when it is the one speaking.
	EventSpeechStarted
	// The caller finished. The utterance is available from Utterance().
	EventUtteranceComplete
)

// Segmenter turns a stream of frames into utterances.
//
// Not safe for concurrent use: one call, one segmenter, one goroutine feeding it
// from the RTP reader.
type Segmenter struct {
	settings Settings

	noiseFloor float64

	speaking          bool
	applianceSpeaking bool
	loudFrames        int
	quietFrames       int
	utterance         []int16
	preroll           [][]int16
	prerollAt         int
	lastUtterance     []int16
}

func NewSegmenter(settings Settings) *Segmenter {
	return &Segmenter{
		settings: settings,
		preroll:  make([][]int16, settings.PrerollFrames),
	}
}

// Push feeds one frame and reports what changed.
//
// applianceSpeaking raises the bar. While the appliance is talking, anything
// arriving on this line is its own voice until proven otherwise, and proving
// otherwise takes both more level and more time — see EchoFactor and
// InterruptFrames.
func (s *Segmenter) Push(frame []int16, applianceSpeaking bool) Event {
	level := rootMeanSquare(frame)
	s.applianceSpeaking = applianceSpeaking
	s.trackNoiseFloor(level)

	threshold := math.Max(s.noiseFloor*s.settings.SpeechFactor, s.settings.MinimumLevel)
	required := s.settings.StartFrames
	if applianceSpeaking && !s.speaking {
		threshold *= s.settings.EchoFactor
		required = s.settings.InterruptFrames
	}
	loud := level > threshold

	if !s.speaking {
		s.rememberForPreroll(frame)
		if !loud {
			s.loudFrames = 0
			return EventNone
		}
		s.loudFrames++
		if s.loudFrames < required {
			return EventNone
		}
		s.speaking = true
		s.quietFrames = 0
		s.utterance = s.utterance[:0]
		s.utterance = append(s.utterance, s.drainPreroll()...)
		s.utterance = append(s.utterance, frame...)
		return EventSpeechStarted
	}

	s.utterance = append(s.utterance, frame...)
	if loud {
		s.quietFrames = 0
	} else {
		s.quietFrames++
	}

	tooLong := len(s.utterance) >= s.settings.MaximumFrames*FrameSamples
	if s.quietFrames >= s.settings.SilenceFrames || tooLong {
		s.finish()
		return EventUtteranceComplete
	}
	return EventNone
}

// Utterance returns the audio of the most recently completed utterance.
//
// The trailing silence is trimmed. Recognition does not need it, and on a
// chunked backend every hundred milliseconds handed over is latency the caller
// waits through before hearing anything back.
func (s *Segmenter) Utterance() []int16 {
	return s.lastUtterance
}

// Levels reports what the detector is currently working with.
//
// Tuning this by ear across a phone, a room and a network is guesswork; these
// two numbers turn it into arithmetic. If the floor sits near the threshold the
// room is loud enough to trip it, and the factor is what needs raising.
func (s *Segmenter) Levels() (floor float64, threshold float64) {
	return s.noiseFloor, math.Max(s.noiseFloor*s.settings.SpeechFactor, s.settings.MinimumLevel)
}

// Speaking reports whether the caller is mid-utterance.
//
// Used for interruption: if this is true while the appliance is talking, the
// caller has cut in and playback must stop.
func (s *Segmenter) Speaking() bool {
	return s.speaking
}

// Reset abandons any utterance in progress.
//
// Called when a call ends or a turn is abandoned, so audio from before does not
// prepend itself to whatever is said next.
func (s *Segmenter) Reset() {
	s.speaking = false
	s.loudFrames = 0
	s.quietFrames = 0
	s.utterance = s.utterance[:0]
	s.prerollAt = 0
	for i := range s.preroll {
		s.preroll[i] = nil
	}
}

func (s *Segmenter) finish() {
	keep := len(s.utterance) - (s.quietFrames-s.settings.StartFrames)*FrameSamples
	if keep < FrameSamples {
		keep = len(s.utterance)
	}
	if keep > len(s.utterance) {
		keep = len(s.utterance)
	}
	s.lastUtterance = append([]int16(nil), s.utterance[:keep]...)

	s.speaking = false
	s.loudFrames = 0
	s.quietFrames = 0
	s.utterance = s.utterance[:0]
}

// trackNoiseFloor follows the quiet level of the line.
//
// Asymmetric on purpose: it rises slowly and falls quickly. A room that gets
// noisier should not drag the threshold up fast enough to swallow speech, but a
// line that goes quiet should become sensitive again promptly — otherwise one
// loud passage desensitises the detector for the rest of the call.
// It starts at zero rather than at the first frame's level. Seeding from the
// first frame seems obviously right and is a trap: a caller who is already
// talking when the call connects sets the floor to their own voice, the
// threshold to two and a half times it, and the appliance goes deaf. Continuous
// speech then holds the floor there, so it never recovers — the call simply
// never hears anything.
//
// Starting at zero means the fixed MinimumLevel governs the first moments,
// which is the safe direction to be wrong in: at worst a noisy room produces a
// spurious utterance in the first second, and the floor rises past it.
func (s *Segmenter) trackNoiseFloor(level float64) {
	if s.speaking {
		return // Speech is not evidence about the noise floor.
	}
	if s.applianceSpeaking {
		// Nor is the appliance's own voice coming back. Letting it raise the
		// floor would leave the line desensitised for seconds after every
		// reply — exactly when the caller is most likely to answer.
		return
	}
	if level > s.noiseFloor {
		s.noiseFloor += (level - s.noiseFloor) * 0.02
	} else {
		s.noiseFloor += (level - s.noiseFloor) * 0.25
	}
}

func (s *Segmenter) rememberForPreroll(frame []int16) {
	if len(s.preroll) == 0 {
		return
	}
	kept := make([]int16, len(frame))
	copy(kept, frame)
	s.preroll[s.prerollAt%len(s.preroll)] = kept
	s.prerollAt++
}

func (s *Segmenter) drainPreroll() []int16 {
	if len(s.preroll) == 0 {
		return nil
	}
	var audio []int16
	start := s.prerollAt - len(s.preroll)
	if start < 0 {
		start = 0
	}
	for i := start; i < s.prerollAt; i++ {
		if frame := s.preroll[i%len(s.preroll)]; frame != nil {
			audio = append(audio, frame...)
		}
	}
	s.prerollAt = 0
	for i := range s.preroll {
		s.preroll[i] = nil
	}
	return audio
}

func rootMeanSquare(frame []int16) float64 {
	if len(frame) == 0 {
		return 0
	}
	var energy float64
	for _, sample := range frame {
		energy += float64(sample) * float64(sample)
	}
	return math.Sqrt(energy / float64(len(frame)))
}
