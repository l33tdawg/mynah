package main

import (
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/l33tdawg/mynah/webrtc/internal/callaudio"
	"github.com/pion/webrtc/v4"
)

func TestScreenCaptureBoundsAndCommit(t *testing.T) {
	c := screenCapture{}
	if _, err := c.receive([]byte{0, 0}, false); err == nil {
		t.Fatal("audio before start accepted")
	}
	_, _ = c.receive([]byte("start"), true)
	if _, err := c.receive([]byte{0}, false); err == nil {
		t.Fatal("odd PCM accepted")
	}
	_, _ = c.receive(make([]byte, 12800), false)
	wav, err := c.receive([]byte("stop"), true)
	if err != nil || len(wav) != 12844 || string(wav[:4]) != "RIFF" {
		t.Fatalf("WAV: %d %v", len(wav), err)
	}
	if _, err := c.receive([]byte("start"), true); err == nil {
		t.Fatal("overlapping turn accepted")
	}
	c.busy = false
	_, _ = c.receive([]byte("start"), true)
	c.pcm = make([]byte, maxScreenPCM)
	if _, err := c.receive([]byte{0, 0}, false); err == nil {
		t.Fatal("unbounded recording")
	}
}

// A real reliable data channel, the actual SDP dispatch, and a fake Mac socket.
// Proves G2 PCM reaches ASR framing and Unicode answers return without RTP/TTS.
func TestScreenDataChannelRoundTrip(t *testing.T)       { screenRoundTrip(t, false) }
func TestQueuedScreenDataChannelRoundTrip(t *testing.T) { screenRoundTrip(t, true) }
func screenRoundTrip(t *testing.T, queued bool) {
	// macOS UNIX paths are limited to 104 bytes; t.TempDir can exceed that.
	listener, err := net.Listen("unix", filepath.Join("/tmp", "mynah-g2-"+time.Now().Format("150405.000000000")+".screen"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	path := listener.Addr().String()
	macDone := make(chan error, 1)
	request := `{"command":"start","id":"g2-11111111-1111-4111-8111-111111111111"}`
	reply := strings.Repeat("hello 世界 ", 1000)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			macDone <- err
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		if queued {
			kind, meta, err := callaudio.ReadFrame(conn)
			if err != nil || kind != callaudio.KindScreenStatus || string(meta) != request {
				macDone <- net.InvalidAddrError("lost request metadata")
				return
			}
		}
		kind, wav, err := callaudio.ReadFrame(conn)
		if err != nil {
			macDone <- err
			return
		}
		if kind != callaudio.KindUtterance || len(wav) != 12844 {
			macDone <- net.InvalidAddrError("wrong utterance framing")
			return
		}
		_ = callaudio.WriteFrame(conn, callaudio.KindHeardText, []byte("my question"))
		_ = callaudio.WriteFrame(conn, callaudio.KindReplyText, []byte(reply))
		macDone <- callaudio.WriteFrame(conn, callaudio.KindReplyEnd, nil)
		// Wait for the client to consume the channel before closing its socket.
		var b [1]byte
		_, _ = conn.Read(b[:])
	}()
	peer, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	dc, err := peer.CreateDataChannel(screenChannel, nil)
	if err != nil {
		t.Fatal(err)
	}
	events := make(chan map[string]string, 20)
	dc.OnMessage(func(message webrtc.DataChannelMessage) {
		var event map[string]string
		if json.Unmarshal(message.Data, &event) == nil {
			events <- event
		}
	})
	var gotAudio bool
	peer.OnTrack(func(*webrtc.TrackRemote, *webrtc.RTPReceiver) { gotAudio = true })
	offer, _ := peer.CreateOffer(nil)
	gathered := webrtc.GatheringCompletePromise(peer)
	if err := peer.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-gathered:
	case <-time.After(5 * time.Second):
		t.Fatal("gather timeout")
	}
	server := &callServer{appliance: strings.TrimSuffix(path, ".screen")}
	answer, err := server.answerOffer(peer.LocalDescription().SDP, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := peer.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); err != nil {
		t.Fatal(err)
	}
	var received string
	for {
		select {
		case event := <-events:
			switch event["type"] {
			case "ready":
				command := "start"
				if queued {
					command = request
				}
				if err := dc.SendText(command); err != nil {
					t.Fatal(err)
				}
				if err := dc.Send(make([]byte, 12800)); err != nil {
					t.Fatal(err)
				}
				if err := dc.SendText("stop"); err != nil {
					t.Fatal(err)
				}
			case "reply":
				received += event["text"]
			case "error":
				t.Fatal(event["text"])
			case "done":
				if received != reply {
					t.Fatalf("answer differs: %d bytes", len(received))
				}
				if gotAudio {
					t.Fatal("glasses received an audio track")
				}
				if err := <-macDone; err != nil {
					t.Fatal(err)
				}
				return
			}
		case <-time.After(10 * time.Second):
			t.Fatal("no answer over data channel")
		}
	}
}

func TestPersistentGlassesEndpointRejectsSpokenCalls(t *testing.T) {
	s := &callServer{screenOnly: true}
	if _, err := s.answerOffer("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n", nil); err == nil {
		t.Fatal("pairing allowed a spoken call")
	}
}

func TestQueuedCaptureAcceptsNextRecordingWithoutWaitingForReply(t *testing.T) {
	c := screenCapture{}
	for _, id := range []string{"g2-11111111-1111-4111-8111-111111111111", "g2-22222222-2222-4222-8222-222222222222"} {
		if _, err := c.receive([]byte(`{"command":"start","id":"`+id+`"}`), true); err != nil {
			t.Fatal(err)
		}
		_, _ = c.receive(make([]byte, 12800), false)
		if _, err := c.receive([]byte("stop"), true); err != nil {
			t.Fatal(err)
		}
		if c.busy {
			t.Fatal("queued turn blocked the next recording")
		}
	}
}
