// Package callaudio carries audio between the endpoint and the appliance.
//
// The two halves of a call live in different processes for reasons neither can
// escape: WebRTC and Opus exist in Go, and the brain — memory, tools, the
// model — is Swift. So the audio crosses a Unix socket, and this is the shape it
// crosses in.
//
// # Why framed rather than a stream
//
// A turn is not a stream of bytes, it is a sequence of events with boundaries
// that matter: this utterance ended, that reply is finished, the caller cut in.
// Recovering those boundaries from a byte stream means inventing a framing
// anyway, and inventing it badly is how a reply gets spoken with the first
// syllable of the next one attached.
//
// # Why a socket rather than stdin
//
// The endpoint is spawned per call and the daemon outlives it. A socket lets
// either end restart without the other having to notice, and keeps the
// appliance's log — which is inherited on stdout — free of audio.
package callaudio

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// Kind is what a frame carries.
type Kind byte

const (
	// KindUtterance is the caller, having finished a sentence. Payload is a WAV
	// the appliance can hand straight to recognition.
	KindUtterance Kind = 1

	// KindReplyAudio is part of the answer. Payload is 48 kHz mono signed
	// 16-bit samples, little-endian and headerless — the rate Opus wants, so the
	// endpoint can encode without touching it.
	//
	// Sent in pieces rather than whole. The first sentence should be playing
	// while the rest is still being synthesised, which is most of the difference
	// between a call that feels responsive and one that does not.
	KindReplyAudio Kind = 2

	// KindInterrupted travels up: the caller started talking while the appliance
	// was. Whatever the turn was doing must stop, including the model.
	KindInterrupted Kind = 3

	// KindReplyEnd travels down: that is the whole answer.
	KindReplyEnd Kind = 4

	// KindTurnFailed travels down: nothing to say, and why. The endpoint has
	// nothing useful to play, but the log should not have to infer silence.
	KindTurnFailed Kind = 5
)

// maximumPayload bounds a single frame.
//
// Thirty seconds of 48 kHz mono is under 3 MB, and the segmenter will not hand
// over more than that. The limit exists so a confused or hostile peer cannot ask
// either side to allocate without bound.
const maximumPayload = 8 << 20

var ErrShortFrame = errors.New("frame ended early")

// WriteFrame emits one frame.
func WriteFrame(writer io.Writer, kind Kind, payload []byte) error {
	if len(payload) > maximumPayload {
		return fmt.Errorf("payload of %d bytes exceeds the %d-byte limit", len(payload), maximumPayload)
	}
	var header [5]byte
	header[0] = byte(kind)
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	if _, err := writer.Write(header[:]); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := writer.Write(payload)
	return err
}

// ReadFrame reads one frame.
//
// Returns io.EOF only when nothing at all was waiting — a clean close between
// frames. A close *within* a frame is ErrShortFrame, because the two mean
// different things: one is the far side finishing, the other is it dying
// mid-sentence, and treating them alike hides a crash as a hang-up.
func ReadFrame(reader io.Reader) (Kind, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		if errors.Is(err, io.ErrUnexpectedEOF) {
			return 0, nil, ErrShortFrame
		}
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(header[1:])
	if length > maximumPayload {
		return 0, nil, fmt.Errorf("frame claims %d bytes, over the %d-byte limit", length, maximumPayload)
	}
	if length == 0 {
		return Kind(header[0]), nil, nil
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return 0, nil, ErrShortFrame
		}
		return 0, nil, err
	}
	return Kind(header[0]), payload, nil
}

// Samples reinterprets a reply payload as samples.
func Samples(payload []byte) []int16 {
	samples := make([]int16, len(payload)/2)
	for i := range samples {
		samples[i] = int16(binary.LittleEndian.Uint16(payload[i*2:]))
	}
	return samples
}

// Bytes is the inverse, for anything sending audio down.
func Bytes(samples []int16) []byte {
	payload := make([]byte, len(samples)*2)
	for i, sample := range samples {
		binary.LittleEndian.PutUint16(payload[i*2:], uint16(sample))
	}
	return payload
}
