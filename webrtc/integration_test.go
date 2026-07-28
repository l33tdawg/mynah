package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

// A real call against a real relay, with pion standing in for the browser.
//
// Everything else in this package is tested against a handler in memory, which
// proves the logic and nothing about the deployment. This is the only test that
// exercises what the owner actually touches: a link served over the public
// internet by a host holding a real certificate, an appliance that accepted no
// connection and is reachable anyway, ICE finding a route between two machines
// that have never spoken, and audio arriving.
//
// Skipped without a target, because it needs a relay and a listening appliance:
//
//	SAGE_CALL_LINK=https://call.sage.delivery/<token> go test -run TestARealCall -v
func TestARealCallOverTheRelay(t *testing.T) {
	link := os.Getenv("SAGE_CALL_LINK")
	if link == "" {
		t.Skip("set SAGE_CALL_LINK to a live call link to run this")
	}

	// The page has to be there before anything else is worth trying, and a 404
	// here means the appliance is not registered — a different problem entirely
	// from a call that fails to connect.
	page, err := http.Get(link) //nolint:noctx // A test, against a link under test.
	if err != nil {
		t.Fatalf("fetching the call page: %v", err)
	}
	defer page.Body.Close()
	if page.StatusCode != http.StatusOK {
		t.Fatalf("the call link answered %s: no appliance is listening", page.Status)
	}
	body, _ := io.ReadAll(io.LimitReader(page.Body, 1<<20))
	if !bytes.Contains(body, []byte("Talk to Mynah")) {
		t.Fatal("that link did not serve the call page")
	}

	caller, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{{URLs: []string{"stun:stun.l.google.com:19302"}}},
	})
	if err != nil {
		t.Fatalf("caller: %v", err)
	}
	defer caller.Close() //nolint:errcheck

	microphone, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus}, "audio", "phone",
	)
	if err != nil {
		t.Fatalf("track: %v", err)
	}
	if _, err := caller.AddTrack(microphone); err != nil {
		t.Fatalf("add track: %v", err)
	}

	// The return path. Without a track arriving here the owner can talk and
	// never hear anything — the exact failure that a healthy "connected" hides.
	heardBack := make(chan struct{})
	caller.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		buffer := make([]byte, 1500)
		if _, _, err := track.Read(buffer); err == nil {
			close(heardBack)
		}
	})

	connected := make(chan struct{})
	var once bool
	caller.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		t.Logf("caller sees: %s", state)
		if state == webrtc.PeerConnectionStateConnected && !once {
			once = true
			close(connected)
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
	select {
	case <-gathered:
	case <-time.After(10 * time.Second):
		t.Log("ICE gathering timed out; offering what we have")
	}

	request, _ := json.Marshal(map[string]string{"sdp": caller.LocalDescription().SDP})
	response, err := http.Post(link+"/offer", "application/json", bytes.NewReader(request)) //nolint:noctx
	if err != nil {
		t.Fatalf("posting the offer: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, 4<<10))
		t.Fatalf("the relay answered %s: %s", response.Status, strings.TrimSpace(string(detail)))
	}
	var answer struct {
		SDP string `json:"sdp"`
	}
	if err := json.NewDecoder(response.Body).Decode(&answer); err != nil {
		t.Fatalf("decoding the answer: %v", err)
	}
	if err := caller.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  answer.SDP,
	}); err != nil {
		t.Fatalf("remote description: %v", err)
	}

	select {
	case <-connected:
	case <-time.After(30 * time.Second):
		t.Fatal("the call never connected: ICE found no route between here and the appliance")
	}

	// Send audio the way a phone would, and listen for it coming back. Silence
	// here is the failure the owner reported as "it doesn't connect" — a call
	// that is up and carries nothing.
	go func() {
		packet := &rtp.Packet{
			Header:  rtp.Header{Version: 2, PayloadType: 111, SSRC: 0x1234},
			Payload: make([]byte, 160),
		}
		for sequence := uint16(0); ; sequence++ {
			packet.SequenceNumber = sequence
			packet.Timestamp = uint32(sequence) * 960
			raw, err := packet.Marshal()
			if err != nil {
				return
			}
			if _, err := microphone.Write(raw); err != nil {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
	}()

	// Audio must come back without anyone having said anything.
	//
	// The appliance greets on connect, which makes the return path testable
	// without speech: a loopback endpoint returns the caller's own audio, and a
	// real one returns "Hey, I'm here." Either way silence here is the failure
	// the owner reported as "I hear nothing" — a call that is up and carries
	// nothing in the direction that matters.
	select {
	case <-heardBack:
	case <-time.After(25 * time.Second):
		t.Fatal("the call connected but nothing came back: no greeting, no echo")
	}
}
