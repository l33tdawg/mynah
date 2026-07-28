package main

import (
	"errors"
	"io"
	"log"
	"net"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"

	"github.com/l33tdawg/sage-voice-bridge/webrtc/internal/callaudio"
	"github.com/l33tdawg/sage-voice-bridge/webrtc/internal/opus"
	"github.com/l33tdawg/sage-voice-bridge/webrtc/internal/speech"
)

// conversation runs one call: the caller's audio in, the appliance's out.
//
// The endpoint owns the audio and the appliance owns the thinking. Everything
// with a deadline measured in milliseconds — decoding, deciding a sentence has
// ended, pacing playback, cutting playback off — happens here, because a pause
// on this side is a pause the caller hears. Everything measured in seconds —
// recognition, the model, speech synthesis — happens over the socket, where a
// delay is a delay in answering rather than a stutter.
type conversation struct {
	appliance net.Conn
	socket    string
	hangUp    func()
	track     *webrtc.TrackLocalStaticSample
	segmenter *speech.Segmenter

	mu          sync.Mutex
	playing     bool
	playlist    [][]int16
	lastAudioAt time.Time
	wake        chan struct{}
	stopped     bool
}

// How long after the last frame the appliance is still considered to be
// speaking.
//
// The playlist empties when the last frame is *sent*, not when the caller hears
// it. Between those moments sit the network, the phone's jitter buffer and its
// speaker — three to five hundred milliseconds during which the appliance's own
// voice is still arriving back while the guard against it has already lifted.
//
// Observed live, and it destroyed whole answers: the opener played, its tail
// echoed back unguarded, that read as the caller interrupting, and the model
// call was cancelled mid-flight. One completed reply — "Just the A100
// benchmarks before Friday" — was thrown away this way between being generated
// and being spoken.
//
// A second covers the worst of that lag without being long enough to stop
// someone answering a question they were just asked.
const playbackHangover = time.Second

// The shortest utterance worth sending for recognition.
//
// Below this it is a door, a keyboard, a breath, or a fragment of the
// appliance's own voice — and the log filled with "heard nothing in 381ms of
// audio". Each one costs a recognition round trip and, worse, arrives as an
// interruption that cancels whatever the appliance was doing.
const minimumUtterance = 400 * time.Millisecond

func newConversation(
	appliance net.Conn,
	socket string,
	track *webrtc.TrackLocalStaticSample,
	listening speech.Settings,
	hangUp func(),
) *conversation {
	return &conversation{
		appliance: appliance,
		socket:    socket,
		hangUp:    hangUp,
		track:     track,
		segmenter: speech.NewSegmenter(listening),
		wake:      make(chan struct{}, 1),
	}
}

// listen decodes the caller and hands complete sentences to the appliance.
func (c *conversation) listen(remote *webrtc.TrackRemote) {
	decoder, err := opus.NewDecoder()
	if err != nil {
		log.Printf("opus decoder: %v", err)
		return
	}
	defer decoder.Close()

	log.Printf("receiving %s from the caller", remote.Codec().MimeType)
	packets := 0
	defer func() { log.Printf("caller's audio ended after %d packets", packets) }()

	buffer := make([]byte, 1500)
	for {
		read, _, err := remote.Read(buffer)
		if err != nil {
			return
		}
		packets++

		// Every five seconds, what the detector is actually seeing. Tuning a
		// voice detector for a room on the other side of a phone is guesswork
		// without it — and "it hears background noise as me speaking" is not a
		// report anyone can act on until the floor and the threshold are two
		// numbers rather than an impression.
		if packets%250 == 0 {
			floor, threshold := c.segmenter.Levels()
			log.Printf("listening: noise floor %.0f, speech above %.0f", floor, threshold)
		}

		// The RTP header is fixed at 12 bytes plus any CSRCs; pion's own reader
		// gives the whole packet, so the payload has to be found rather than
		// assumed. A wrong offset here decodes as noise, which sounds like a
		// broken microphone rather than a parsing bug.
		payload, ok := rtpPayload(buffer[:read])
		if !ok {
			continue
		}

		samples, err := decoder.Decode(payload)
		if err != nil {
			continue
		}

		// Decode reuses its buffer, and a completed utterance outlives the next
		// packet by the length of a model call.
		frame := make([]int16, len(samples))
		copy(frame, samples)

		switch c.segmenter.Push(frame, c.isPlaying()) {
		case speech.EventSpeechStarted:
			c.interrupt()
		case speech.EventUtteranceComplete:
			utterance := c.segmenter.Utterance()
			shortest := int(minimumUtterance.Seconds() * speech.SampleRate)
			if len(utterance) < shortest {
				// Too short to be words. Sending it costs a recognition round
				// trip and, worse, lands as an interruption that cancels
				// whatever the appliance was in the middle of.
				continue
			}
			c.send(callaudio.KindUtterance,
				callaudio.WAV(callaudio.Downsample(utterance), callaudio.RecognitionRate))
		case speech.EventNone:
		}
	}
}

// interrupt stops the appliance mid-sentence because the caller started talking.
//
// Both halves matter and they are different. Dropping the queued audio stops the
// voice within one frame, which is what the caller experiences as being able to
// cut in. Telling the appliance stops the model and the synthesiser, without
// which the rest of the abandoned answer arrives seconds later and is spoken
// over the new question.
func (c *conversation) interrupt() {
	c.mu.Lock()
	wasPlaying := c.playing || len(c.playlist) > 0
	c.playlist = nil
	c.mu.Unlock()

	if !wasPlaying {
		return
	}
	log.Println("the caller interrupted")
	c.send(callaudio.KindInterrupted, nil)
}

// play accepts the answer and speaks it.
func (c *conversation) play() {
	go c.pace()
	c.receive()
}

// receive reads frames until this connection to the appliance ends.
//
// Ending is not the same as the call ending: a redial replaces the connection
// and starts another of these. Only the call being stopped stops the audio.
func (c *conversation) receive() {
	c.mu.Lock()
	conn := c.appliance
	c.mu.Unlock()

	for {
		kind, payload, err := callaudio.ReadFrame(conn)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("the appliance stopped talking: %v", err)
			}
			return
		}
		switch kind {
		case callaudio.KindReplyAudio:
			c.enqueue(callaudio.Samples(payload))
		case callaudio.KindReplyEnd:
		case callaudio.KindEndCall:
			// The appliance is saying goodbye. Give the last words time to
			// reach the caller before the line goes — hanging up the instant
			// the audio is queued cuts off the sentence that explains why.
			log.Println("the appliance ended the call")
			go func() {
				time.Sleep(4 * time.Second)
				c.stop()
				if c.hangUp != nil {
					c.hangUp()
				}
			}()
		case callaudio.KindTurnFailed:
			log.Printf("the appliance could not answer: %s", clean(string(payload)))
		}
	}
}

func (c *conversation) enqueue(samples []int16) {
	if len(samples) == 0 {
		return
	}
	c.mu.Lock()
	c.playlist = append(c.playlist, samples)
	c.mu.Unlock()
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// pace encodes and sends the answer at the rate it is meant to be heard.
//
// Real time, deliberately. The whole answer could be handed to the track at
// once, and WebRTC would deliver it in a burst that the phone plays as a chipmunk
// or drops outright. Audio has to leave at the speed it is spoken.
//
// It also has to be interruptible between frames, which is why the queue is
// consulted every 20 ms rather than drained into a buffer — the caller cutting
// in must silence the appliance within a frame, not at the end of the sentence.
func (c *conversation) pace() {
	encoder, err := opus.NewEncoder()
	if err != nil {
		log.Printf("opus encoder: %v", err)
		return
	}
	defer encoder.Close()

	const frameSamples = opus.SampleRate / 50 // 20 ms
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()

	var pending []int16
	for {
		select {
		case <-ticker.C:
		case <-c.wake:
			continue
		}
		if c.isStopped() {
			return
		}

		c.mu.Lock()
		for len(pending) < frameSamples && len(c.playlist) > 0 {
			pending = append(pending, c.playlist[0]...)
			c.playlist = c.playlist[1:]
		}
		// Interruption empties the playlist; anything already staged has to go
		// too, or the last fragment is spoken over the caller.
		if len(c.playlist) == 0 && len(pending) < frameSamples && !c.playing {
			pending = pending[:0]
		}
		idle := len(pending) == 0
		c.playing = !idle
		c.mu.Unlock()

		if idle {
			continue
		}

		frame := pending
		if len(frame) > frameSamples {
			frame = frame[:frameSamples]
			pending = pending[frameSamples:]
		} else {
			// A short tail is padded rather than dropped. Opus will not encode a
			// partial frame, and the alternative is losing the last syllable.
			padded := make([]int16, frameSamples)
			copy(padded, frame)
			frame = padded
			pending = pending[:0]
		}

		packet, err := encoder.Encode(frame)
		if err != nil {
			log.Printf("opus encode: %v", err)
			continue
		}
		c.mu.Lock()
		c.lastAudioAt = time.Now()
		c.mu.Unlock()

		if err := c.track.WriteSample(media.Sample{
			Data:     packet,
			Duration: 20 * time.Millisecond,
		}); err != nil {
			log.Printf("writing audio to the call: %v", err)
			return
		}
	}
}

func (c *conversation) send(kind callaudio.Kind, payload []byte) {
	c.mu.Lock()
	conn := c.appliance
	c.mu.Unlock()

	if err := callaudio.WriteFrame(conn, kind, payload); err == nil {
		return
	} else {
		log.Printf("could not reach the appliance: %v", err)
	}

	// One redial before giving up on the frame.
	//
	// The appliance restarts — for an update, or because it fell over — and the
	// socket dies under a call that is otherwise perfectly healthy. Observed
	// live: 4,503 packets still arriving from the caller, ICE fine, and nothing
	// answering, which is indistinguishable from a crash to whoever is holding
	// the phone. A call should survive its brain being restarted.
	if conn, ok := c.redial(); ok {
		if err := callaudio.WriteFrame(conn, kind, payload); err != nil {
			log.Printf("the appliance is still unreachable: %v", err)
		}
	}
}

// redial reconnects to the appliance, briefly.
//
// Bounded because the caller is on the line: a few seconds covers a daemon
// restart, and beyond that the honest thing is to stop pretending. Nothing here
// tells the caller — that would need a voice, which is exactly what has gone
// missing.
func (c *conversation) redial() (net.Conn, bool) {
	if c.socket == "" {
		return nil, false
	}
	for attempt := 0; attempt < 10; attempt++ {
		if c.isStopped() {
			return nil, false
		}
		time.Sleep(500 * time.Millisecond)
		conn, err := net.Dial("unix", c.socket)
		if err != nil {
			continue
		}
		log.Println("reconnected to the appliance")

		c.mu.Lock()
		previous := c.appliance
		c.appliance = conn
		c.mu.Unlock()
		if previous != nil {
			_ = previous.Close()
		}

		// The reader was reading the old connection and has stopped; start
		// another, or the answer to the next question is never collected.
		go c.receive()
		return conn, true
	}
	log.Println("the appliance did not come back")
	return nil, false
}

func (c *conversation) stop() {
	c.mu.Lock()
	c.stopped = true
	c.playlist = nil
	c.mu.Unlock()
}

// isPlaying reports whether the appliance's voice is on the line right now —
// including the hangover after the last frame, while the caller is still
// hearing audio that has already left here.
func (c *conversation) isPlaying() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.playing || len(c.playlist) > 0 {
		return true
	}
	return !c.lastAudioAt.IsZero() && time.Since(c.lastAudioAt) < playbackHangover
}

func (c *conversation) isStopped() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stopped
}

// rtpPayload finds the Opus payload inside an RTP packet.
func rtpPayload(packet []byte) ([]byte, bool) {
	const minimumHeader = 12
	if len(packet) < minimumHeader {
		return nil, false
	}
	if packet[0]>>6 != 2 {
		return nil, false // Not RTP version 2.
	}
	offset := minimumHeader + int(packet[0]&0x0F)*4
	if packet[0]&0x10 != 0 { // An extension header follows the CSRCs.
		if len(packet) < offset+4 {
			return nil, false
		}
		length := int(packet[offset+2])<<8 | int(packet[offset+3])
		offset += 4 + length*4
	}
	if offset >= len(packet) {
		return nil, false
	}
	return packet[offset:], true
}
