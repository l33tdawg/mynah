// Package opus decodes what the phone sends and encodes what the agent says.
//
// macOS has no Opus codec, and WebRTC has no other codec worth using: every
// browser negotiates Opus, and the alternatives are G.711 at 8 kHz. That
// narrowband path is tempting because it needs no library at all — and it would
// be paid for in the one place this product cannot afford it, since the
// caller's speech goes straight into recognition. Accuracy there decides whether
// a call feels like talking to something or fighting it.
//
// So: a static libopus, built by scripts/build-opus.sh and linked in. Deliberate
// consequence — this package needs cgo, so the endpoint must be built for the
// architecture it runs on. That is the price of the appliance being one file
// that works on a Mac with no toolchain, no Homebrew and no shared libraries.
//
// The binding is small on purpose. A general-purpose wrapper would expose modes,
// bandwidths, and multistream surfaces that a two-party voice call never uses,
// each of which is a way to hold the codec wrong.
package opus

/*
#cgo CFLAGS: -I${SRCDIR}/../../third_party/opus/include
#cgo LDFLAGS: ${SRCDIR}/../../third_party/opus/lib/libopus.a -lm
#include <opus/opus.h>
#include <stdlib.h>

// opus_encoder_ctl is variadic and its arguments are macros, so cgo cannot
// reach it. These name the four settings a voice call actually cares about.
static int sage_set_bitrate(OpusEncoder *e, opus_int32 v) {
	return opus_encoder_ctl(e, OPUS_SET_BITRATE(v));
}
static int sage_set_inband_fec(OpusEncoder *e, opus_int32 v) {
	return opus_encoder_ctl(e, OPUS_SET_INBAND_FEC(v));
}
static int sage_set_packet_loss(OpusEncoder *e, opus_int32 v) {
	return opus_encoder_ctl(e, OPUS_SET_PACKET_LOSS_PERC(v));
}
static int sage_set_dtx(OpusEncoder *e, opus_int32 v) {
	return opus_encoder_ctl(e, OPUS_SET_DTX(v));
}
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

const (
	// Opus runs at 48 kHz internally and WebRTC always negotiates it there.
	// Resampling belongs to whoever needs another rate, not here.
	SampleRate = 48000

	// One channel. A call is a voice, and stereo would double the bandwidth to
	// transmit the same thing twice.
	Channels = 1

	// The largest frame this decodes into. Opus permits up to 120 ms per packet;
	// a browser sends 20 ms. Sized for the maximum because the alternative is
	// truncating a packet that is within spec, and the memory costs nothing.
	maxFrameSamples = SampleRate / 1000 * 120
)

// Decoder turns Opus packets into signed 16-bit samples.
type Decoder struct {
	handle *C.OpusDecoder
	buffer []int16
}

func NewDecoder() (*Decoder, error) {
	var status C.int
	handle := C.opus_decoder_create(C.opus_int32(SampleRate), C.int(Channels), &status)
	if status != C.OPUS_OK {
		return nil, fmt.Errorf("opus decoder: %s", errorText(status))
	}
	return &Decoder{handle: handle, buffer: make([]int16, maxFrameSamples)}, nil
}

// Decode returns the samples in one packet.
//
// The returned slice is reused on the next call. Callers that keep the audio —
// which is most of them, since recognition needs a whole utterance — must copy
// it. Reusing avoids an allocation every 20 ms for the length of a call.
func (d *Decoder) Decode(packet []byte) ([]int16, error) {
	if d.handle == nil {
		return nil, errors.New("opus decoder is closed")
	}
	if len(packet) == 0 {
		return nil, errors.New("empty packet")
	}
	written := C.opus_decode(
		d.handle,
		(*C.uchar)(unsafe.Pointer(&packet[0])),
		C.opus_int32(len(packet)),
		(*C.opus_int16)(unsafe.Pointer(&d.buffer[0])),
		C.int(maxFrameSamples),
		0,
	)
	if written < 0 {
		return nil, fmt.Errorf("opus decode: %s", errorText(C.int(written)))
	}
	return d.buffer[:int(written)*Channels], nil
}

// DecodeMissing conceals a packet that never arrived.
//
// Handing the decoder a gap rather than nothing keeps it from producing a click
// where the loss was, and keeps its internal state aligned with the sender's.
// Silence would be audible in a way a concealed frame is not.
func (d *Decoder) DecodeMissing(samples int) ([]int16, error) {
	if d.handle == nil {
		return nil, errors.New("opus decoder is closed")
	}
	written := C.opus_decode(d.handle, nil, 0,
		(*C.opus_int16)(unsafe.Pointer(&d.buffer[0])), C.int(samples), 0)
	if written < 0 {
		return nil, fmt.Errorf("opus conceal: %s", errorText(C.int(written)))
	}
	return d.buffer[:int(written)*Channels], nil
}

func (d *Decoder) Close() {
	if d.handle != nil {
		C.opus_decoder_destroy(d.handle)
		d.handle = nil
	}
}

// Encoder turns samples into Opus packets.
type Encoder struct {
	handle *C.OpusEncoder
	buffer []byte
}

// NewEncoder configures the codec for speech.
//
// OPUS_APPLICATION_VOIP rather than AUDIO: it optimises for intelligibility over
// fidelity and enables the speech-specific tools. This carries one voice saying
// words, and nothing here benefits from the settings that serve music.
func NewEncoder() (*Encoder, error) {
	var status C.int
	handle := C.opus_encoder_create(
		C.opus_int32(SampleRate), C.int(Channels), C.OPUS_APPLICATION_VOIP, &status)
	if status != C.OPUS_OK {
		return nil, fmt.Errorf("opus encoder: %s", errorText(status))
	}

	encoder := &Encoder{handle: handle, buffer: make([]byte, 4000)}

	// 24 kbit/s mono speech is transparent to the ear and undemanding of a
	// phone's uplink. Left explicit because the default varies with the build.
	C.sage_set_bitrate(handle, 24000)
	// Inband FEC, so a lost packet can be reconstructed from the next one. A
	// call to an appliance runs over home Wi-Fi and sometimes a relay, and this
	// is the difference between a dropout being heard and not.
	C.sage_set_inband_fec(handle, 1)
	C.sage_set_packet_loss(handle, 10)
	// No DTX. It saves bandwidth by stopping transmission during silence, and
	// stopping transmission is indistinguishable at the far end from a call that
	// has died — which is precisely the anxiety a voice assistant must not
	// create while it is thinking.
	C.sage_set_dtx(handle, 0)

	return encoder, nil
}

// Encode returns one packet for one frame of samples.
//
// The frame must be a duration Opus permits: 2.5, 5, 10, 20, 40 or 60 ms. The
// caller decides, because the caller is pacing playback.
func (e *Encoder) Encode(samples []int16) ([]byte, error) {
	if e.handle == nil {
		return nil, errors.New("opus encoder is closed")
	}
	if len(samples) == 0 {
		return nil, errors.New("no samples")
	}
	written := C.opus_encode(
		e.handle,
		(*C.opus_int16)(unsafe.Pointer(&samples[0])),
		C.int(len(samples)/Channels),
		(*C.uchar)(unsafe.Pointer(&e.buffer[0])),
		C.opus_int32(len(e.buffer)),
	)
	if written < 0 {
		return nil, fmt.Errorf("opus encode: %s", errorText(C.int(written)))
	}
	return e.buffer[:written], nil
}

func (e *Encoder) Close() {
	if e.handle != nil {
		C.opus_encoder_destroy(e.handle)
		e.handle = nil
	}
}

func errorText(status C.int) string {
	return C.GoString(C.opus_strerror(status))
}
