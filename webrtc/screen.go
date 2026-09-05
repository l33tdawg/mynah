package main

import (
	"encoding/json"
	"errors"
	"net"
	"sync"
	"time"

	"github.com/l33tdawg/mynah/webrtc/internal/callaudio"
	"github.com/pion/webrtc/v4"
)

const screenChannel = "mynah.g2.v1"
const maxScreenPCM = 60 * 16000 * 2

// Recording boundaries are explicit; the glasses SDK already supplies 16 kHz
// mono PCM. A reliable ordered channel carries small chunks, then a commit.
type screenCapture struct {
	pcm       []byte
	recording bool
	busy      bool
}

func (c *screenCapture) receive(data []byte, text bool) ([]byte, error) {
	if !text {
		if !c.recording || len(data)%2 != 0 || len(data) > 16384 || len(c.pcm)+len(data) > maxScreenPCM {
			return nil, errors.New("invalid or oversized recording")
		}
		c.pcm = append(c.pcm, data...)
		return nil, nil
	}
	if len(data) > 128 {
		return nil, errors.New("oversized control")
	}
	switch string(data) {
	case "start":
		if c.recording || c.busy {
			return nil, errors.New("a turn is already in progress")
		}
		c.pcm = nil
		c.recording = true
	case "stop":
		if !c.recording || len(c.pcm) < 12800 {
			return nil, errors.New("record at least 400 ms")
		}
		wav := callaudio.WAV(callaudio.Samples(c.pcm), 16000)
		c.pcm = nil
		c.recording = false
		c.busy = true
		return wav, nil
	case "cancel":
		c.pcm = nil
		c.recording = false
	default:
		return nil, errors.New("unknown control")
	}
	return nil, nil
}

func (s *callServer) answerScreenOffer(offer string, ice []webrtc.ICEServer) (string, error) {
	if s.appliance == "" {
		return "", errors.New("glasses require an appliance")
	}
	if len(ice) == 0 {
		ice = s.ice
	}
	peer, err := webrtc.NewPeerConnection(webrtc.Configuration{ICEServers: ice})
	if err != nil {
		return "", err
	}
	s.callStarted()
	var once sync.Once
	var mu sync.Mutex
	var brain net.Conn
	closed := false
	claimed := false
	finish := func() {
		once.Do(func() {
			mu.Lock()
			closed = true
			if brain != nil {
				_ = brain.Close()
			}
			mu.Unlock()
			s.callEnded()
			// Pion callbacks must not wait on their own shutdown.
			go peer.Close()
		})
	}
	peer.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateFailed || state == webrtc.PeerConnectionStateClosed || state == webrtc.PeerConnectionStateDisconnected {
			finish()
		}
	})
	time.AfterFunc(connectDeadline, func() {
		if peer.ConnectionState() != webrtc.PeerConnectionStateConnected {
			finish()
		}
	})
	peer.OnDataChannel(func(dc *webrtc.DataChannel) {
		mu.Lock()
		if closed || claimed || dc.Label() != screenChannel || !dc.Ordered() || dc.MaxRetransmits() != nil || dc.MaxPacketLifeTime() != nil {
			mu.Unlock()
			_ = dc.Close()
			return
		}
		claimed = true
		mu.Unlock()
		dc.OnOpen(func() {
			conn, err := net.DialTimeout("unix", s.appliance+".screen", 3*time.Second)
			if err != nil {
				_ = dc.SendText(`{"type":"error","text":"Mynah's glasses connection is unavailable. Update and restart Mynah."}`)
				finish()
				return
			}
			mu.Lock()
			if closed {
				mu.Unlock()
				_ = conn.Close()
				return
			}
			brain = conn
			mu.Unlock()
			go serveScreenChannel(dc, conn, finish)
		})
		dc.OnClose(finish)
		dc.OnError(func(error) { finish() })
	})
	if err = peer.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); err != nil {
		finish()
		return "", err
	}
	answer, err := peer.CreateAnswer(nil)
	if err != nil {
		finish()
		return "", err
	}
	gathered := webrtc.GatheringCompletePromise(peer)
	if err = peer.SetLocalDescription(answer); err != nil {
		finish()
		return "", err
	}
	select {
	case <-gathered:
	case <-time.After(5 * time.Second):
	}
	s.screenMu.Lock()
	previous := s.screenEnd
	s.screenEnd = finish
	s.screenMu.Unlock()
	if previous != nil {
		previous()
	}
	return peer.LocalDescription().SDP, nil
}

func serveScreenChannel(dc *webrtc.DataChannel, conn net.Conn, finish func()) {
	defer finish()
	var mu sync.Mutex
	capture := screenCapture{}
	send := func(kind, text string) error {
		data, _ := json.Marshal(map[string]string{"type": kind, "text": text})
		return dc.SendText(string(data))
	}
	dc.OnMessage(func(message webrtc.DataChannelMessage) {
		mu.Lock()
		defer mu.Unlock()
		wav, err := capture.receive(message.Data, message.IsString)
		if err != nil {
			capture.pcm = nil
			capture.recording = false
			_ = send("error", err.Error())
			if !capture.busy {
				_ = send("done", "")
			}
			return
		}
		if wav != nil {
			_ = conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if err := callaudio.WriteFrame(conn, callaudio.KindUtterance, wav); err != nil {
				go finish()
				return
			}
			_ = send("thinking", "Thinking…")
		}
	})
	if err := send("ready", "Tap to talk"); err != nil {
		return
	}
	for {
		// Bounds idle sessions and a stalled daemon. The UI reconnects explicitly.
		_ = conn.SetReadDeadline(time.Now().Add(7 * time.Minute))
		kind, body, err := callaudio.ReadFrame(conn)
		if err != nil {
			return
		}
		switch kind {
		case callaudio.KindScreenStatus:
			err = send("state", string(body))
		case callaudio.KindHeardText:
			err = send("heard", string(body))
		case callaudio.KindReplyText:
			// SCTP messages stay below the browser's message-size limit.
			for len(body) > 0 {
				n := len(body)
				if n > 8000 {
					n = 8000
				}
				// JSON strings must not split a UTF-8 code point.
				for n < len(body) && n > 0 && body[n]&0xc0 == 0x80 {
					n--
				}
				if err = send("reply", string(body[:n])); err != nil {
					break
				}
				body = body[n:]
			}
		case callaudio.KindTurnFailed:
			err = send("error", string(body))
		case callaudio.KindReplyEnd:
			mu.Lock()
			capture.busy = false
			mu.Unlock()
			err = send("done", "")
		case callaudio.KindEndCall:
			return
		}
		if err != nil {
			return
		}
	}
}
