package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

// A real handshake against the real handler, with pion standing in for the
// browser.
//
// This is the only test that proves the hard parts: that ICE negotiated a path,
// that DTLS-SRTP came up, and that audio flows in BOTH directions. Everything
// after this — ASR, the brain, TTS — is work on a stream that already exists.
// Everything before it is a page nobody can talk into.
func TestACallConnectsAndAudioFlowsBothWays(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(
		(&callServer{ice: iceServers("", "")}).handleOffer,
	))
	defer server.Close()

	caller, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("caller: %v", err)
	}
	defer caller.Close() //nolint:errcheck

	// What getUserMedia would hand us.
	microphone, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus}, "audio", "phone",
	)
	if err != nil {
		t.Fatalf("track: %v", err)
	}
	if _, err := caller.AddTrack(microphone); err != nil {
		t.Fatalf("add track: %v", err)
	}

	// Proof of the return path. Without a track arriving here the owner can talk
	// and never hear anything, which is the failure a recvonly transceiver
	// produces and which no amount of "connected" would reveal.
	heardBack := make(chan struct{})
	caller.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		buffer := make([]byte, 1500)
		if _, _, err := track.Read(buffer); err == nil {
			close(heardBack)
		}
	})

	connected := make(chan struct{})
	caller.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateConnected {
			select {
			case <-connected:
			default:
				close(connected)
			}
		}
	})

	offer, err := caller.CreateOffer(nil)
	if err != nil {
		t.Fatalf("offer: %v", err)
	}
	gathered := webrtc.GatheringCompletePromise(caller)
	if err := caller.SetLocalDescription(offer); err != nil {
		t.Fatalf("local description: %v", err)
	}
	<-gathered

	body, _ := json.Marshal(offerRequest{SDP: caller.LocalDescription().SDP})
	response, err := http.Post(server.URL, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("post offer: %v", err)
	}
	defer response.Body.Close() //nolint:errcheck
	if response.StatusCode != http.StatusOK {
		t.Fatalf("offer rejected: %d", response.StatusCode)
	}

	var answer answerResponse
	if err := json.NewDecoder(response.Body).Decode(&answer); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if err := caller.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer, SDP: answer.SDP,
	}); err != nil {
		t.Fatalf("remote description: %v", err)
	}

	select {
	case <-connected:
	case <-time.After(20 * time.Second):
		t.Fatal("the call never connected")
	}

	// Keep talking until it comes back. One packet can be lost to a warming
	// SRTP session without anything being wrong.
	stop := make(chan struct{})
	defer close(stop)
	var sequence uint16
	go func() {
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				packet := &rtp.Packet{
					Header:  rtp.Header{Version: 2, PayloadType: 111, SequenceNumber: sequence},
					Payload: []byte{0xf8, 0xff, 0xfe},
				}
				sequence++
				raw, marshalErr := packet.Marshal()
				if marshalErr != nil {
					return
				}
				_, _ = microphone.Write(raw)
			}
		}
	}()

	select {
	case <-heardBack:
	case <-time.After(20 * time.Second):
		t.Fatal("audio never came back: the owner would talk and hear nothing")
	}
}

// The answer must offer to send, not merely to receive. A recvonly answer
// produces a call that connects, shows every green light, and is silent.
func TestTheAnswerOffersToSendAudio(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(
		(&callServer{ice: iceServers("", "")}).handleOffer,
	))
	defer server.Close()

	caller, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("caller: %v", err)
	}
	defer caller.Close() //nolint:errcheck
	if _, err := caller.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio); err != nil {
		t.Fatalf("transceiver: %v", err)
	}

	offer, _ := caller.CreateOffer(nil)
	gathered := webrtc.GatheringCompletePromise(caller)
	_ = caller.SetLocalDescription(offer)
	<-gathered

	body, _ := json.Marshal(offerRequest{SDP: caller.LocalDescription().SDP})
	response, err := http.Post(server.URL, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer response.Body.Close() //nolint:errcheck

	var answer answerResponse
	_ = json.NewDecoder(response.Body).Decode(&answer)

	if !bytes.Contains([]byte(answer.SDP), []byte("opus")) {
		t.Error("the answer does not carry Opus, so nothing can be spoken back")
	}
	if bytes.Contains([]byte(answer.SDP), []byte("a=recvonly")) {
		t.Error("recvonly answer: the call connects and stays silent")
	}
}

func TestAMalformedOfferIsRefusedWithoutCrashing(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(
		(&callServer{ice: iceServers("", "")}).handleOffer,
	))
	defer server.Close()

	for _, body := range []string{`{"sdp":"not an sdp"}`, `{`, `{"sdp":""}`} {
		response, err := http.Post(server.URL, "application/json", bytes.NewReader([]byte(body)))
		if err != nil {
			t.Fatalf("post %q: %v", body, err)
		}
		_ = response.Body.Close()
		if response.StatusCode == http.StatusOK {
			t.Errorf("%q was accepted as a call", body)
		}
	}
}
