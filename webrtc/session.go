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
	track     *webrtc.TrackLocalStaticSample
	segmenter *speech.Segmenter

	mu       sync.Mutex
	playing  bool
	playlist [][]int16
	wake     chan struct{}
	stopped  bool
}

func newConversation(appliance net.Conn, track *webrtc.TrackLocalStaticSample) *conversation {
	return &conversation{
		appliance: appliance,
		track:     track,
		segmenter: speech.NewSegmenter(speech.DefaultSettings()),
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
			c.send(callaudio.KindUtterance,
				callaudio.WAV(callaudio.Downsample(c.segmenter.Utterance()), callaudio.RecognitionRate))
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

	for {
		kind, payload, err := callaudio.ReadFrame(c.appliance)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("the appliance stopped talking: %v", err)
			}
			c.stop()
			return
		}
		switch kind {
		case callaudio.KindReplyAudio:
			c.enqueue(callaudio.Samples(payload))
		case callaudio.KindReplyEnd:
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
	if err := callaudio.WriteFrame(c.appliance, kind, payload); err != nil {
		log.Printf("could not reach the appliance: %v", err)
	}
}

func (c *conversation) stop() {
	c.mu.Lock()
	c.stopped = true
	c.playlist = nil
	c.mu.Unlock()
}

// isPlaying reports whether the appliance's voice is on the line right now.
func (c *conversation) isPlaying() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.playing || len(c.playlist) > 0
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
