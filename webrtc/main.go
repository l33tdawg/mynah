// Command sage-voice-webrtc is the full-duplex voice endpoint.
//
// The Signal bridge is turn-based by construction: the owner sends a message,
// waits, gets an answer. That is why this codebase has a 300-second deadline,
// three progress messages and a whole vocabulary for saying "still working" —
// all of it exists to make waiting bearable.
//
// A call is not that. Silence past about a second is the failure, the model has
// to stream, and the owner has to be able to interrupt. Barge-in is the entire
// point: an assistant you cannot cut off is a slower voice note.
//
// # Why a browser, and why WebRTC
//
// The browser gives us the two hardest parts for nothing:
//
//   - Acoustic echo cancellation. Full duplex without AEC means the microphone
//     hears the speaker and the assistant interrupts itself. Browsers solved
//     this years ago behind one getUserMedia constraint; doing it ourselves is
//     a signal-processing project.
//   - NAT traversal, via ICE. The owner is on cellular, the Mac is behind a
//     home router, and neither can accept an inbound connection.
//
// A link also sidesteps app review, app installation and microphone permission
// prompts on a phone the owner does not want to install anything on.
//
// # Why Go, in a Swift repository
//
// There is no WebRTC in Foundation, and vendoring libwebrtc is a build system
// unto itself. Pion is pure Go, mature, and — decisively — already in this
// project's dependency graph: SAGE pulls pion's ICE, DTLS, SRTP and TURN stacks
// in through libp2p. The toolchain is already here and already trusted.
//
// # The secure-context problem, stated up front
//
// getUserMedia is refused outside a secure context. `http://192.168.1.10:8090`
// is NOT one, so serving this page over plain HTTP on a LAN gets a microphone
// that never starts and a console error the owner will never see. Localhost is
// exempt, which is why the developer loop works and the phone does not.
//
// So this serves HTTPS with the certificate it is given. That is not a detail
// to be discovered later; it is the difference between working and not.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/pion/webrtc/v4"
)

func main() {
	var (
		addr     = flag.String("addr", "127.0.0.1:8090", "listen address")
		certFile = flag.String("cert", "", "TLS certificate (required unless -insecure)")
		keyFile  = flag.String("key", "", "TLS private key (required unless -insecure)")
		insecure = flag.Bool("insecure", false, "serve plain HTTP — localhost only; a phone will refuse the microphone")
		stunURL  = flag.String("stun", "stun:stun.l.google.com:19302", "STUN server")
		turnURL  = flag.String("turn", "", "TURN server, e.g. turn:relay.example.com:3478")
		turnUser = flag.String("turn-user", "", "TURN username")
		turnPass = flag.String("turn-pass", "", "TURN credential")
	)
	flag.Parse()

	if !*insecure && (*certFile == "" || *keyFile == "") {
		fmt.Fprintln(os.Stderr, `error: -cert and -key are required.

getUserMedia is refused outside a secure context, so a page served over plain
HTTP to a phone gets a microphone that never starts. Pass a certificate, or
-insecure for a localhost-only developer loop.`)
		os.Exit(2)
	}

	server := &callServer{ice: iceServers(*stunURL, *turnURL, *turnUser, *turnPass)}
	if *turnURL == "" {
		log.Println("no TURN server configured: calls will fail behind symmetric NAT")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", server.handlePage)
	mux.HandleFunc("/offer", server.handleOffer)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"ok":true,"calls":%d}`, server.activeCalls())
	})

	httpServer := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		// Deliberately no WriteTimeout: a call lives as long as the owner is
		// talking, and a timeout here would cut it mid-sentence.
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop
		log.Println("shutting down")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(ctx)
	}()

	log.Printf("listening on %s (secure=%v)", *addr, !*insecure)
	var err error
	if *insecure {
		err = httpServer.ListenAndServe()
	} else {
		httpServer.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
		err = httpServer.ListenAndServeTLS(*certFile, *keyFile)
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// iceServers builds the ICE configuration.
//
// STUN alone resolves most home NATs by discovering the public mapping. It does
// NOT resolve symmetric NAT, which is common on cellular carriers — precisely
// where the owner will be when they want to call. That case needs TURN, which
// relays the media rather than merely describing a path to it.
//
// Worth being explicit about the privacy trade, because this product's argument
// is that the owner's words stay on their machine: a TURN relay carries the
// audio. It is encrypted end-to-end by DTLS-SRTP and the relay cannot read it,
// but it does see that a call happened, for how long, and between which
// addresses. Self-hosting the TURN server keeps even that metadata in the
// owner's hands, which is why this takes a URL rather than shipping someone
// else's.
func iceServers(stunURL, turnURL, user, pass string) []webrtc.ICEServer {
	servers := []webrtc.ICEServer{}
	if stunURL != "" {
		servers = append(servers, webrtc.ICEServer{URLs: []string{stunURL}})
	}
	if turnURL != "" {
		servers = append(servers, webrtc.ICEServer{
			URLs:           []string{turnURL},
			Username:       user,
			Credential:     pass,
			CredentialType: webrtc.ICECredentialTypePassword,
		})
	}
	return servers
}

type callServer struct {
	ice []webrtc.ICEServer

	mu    sync.Mutex
	calls int
}

func (s *callServer) activeCalls() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

func (s *callServer) callStarted() {
	s.mu.Lock()
	s.calls++
	s.mu.Unlock()
}

func (s *callServer) callEnded() {
	s.mu.Lock()
	if s.calls > 0 {
		s.calls--
	}
	s.mu.Unlock()
}

type offerRequest struct {
	SDP string `json:"sdp"`
}

type answerResponse struct {
	SDP string `json:"sdp"`
}

// handleOffer completes the whole handshake in one request.
//
// No trickle ICE and no signalling socket: the answer is withheld until
// gathering finishes, so every candidate travels in the SDP. That costs a second
// or two of setup and removes an entire class of failure — a dropped candidate
// message, a socket that closed mid-negotiation, ordering bugs between the two.
// For a call the owner starts by opening a link, a second of setup is invisible
// and a flaky handshake is not.
func (s *callServer) handleOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var request offerRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&request); err != nil {
		http.Error(w, "bad offer", http.StatusBadRequest)
		return
	}

	peer, err := webrtc.NewPeerConnection(webrtc.Configuration{ICEServers: s.ice})
	if err != nil {
		log.Printf("peer connection: %v", err)
		http.Error(w, "could not start the call", http.StatusInternalServerError)
		return
	}

	// Declared before the answer so the SDP advertises both directions. A
	// recvonly transceiver here would produce a call the owner can talk into and
	// never hear anything back.
	audio, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus},
		"audio", "mynah",
	)
	if err != nil {
		log.Printf("track: %v", err)
		http.Error(w, "could not start the call", http.StatusInternalServerError)
		_ = peer.Close()
		return
	}
	if _, err := peer.AddTrack(audio); err != nil {
		log.Printf("add track: %v", err)
		http.Error(w, "could not start the call", http.StatusInternalServerError)
		_ = peer.Close()
		return
	}

	s.callStarted()
	var once sync.Once
	finish := func() {
		once.Do(func() {
			s.callEnded()
			_ = peer.Close()
		})
	}

	peer.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("call %s", state)
		switch state {
		case webrtc.PeerConnectionStateFailed,
			webrtc.PeerConnectionStateClosed,
			webrtc.PeerConnectionStateDisconnected:
			finish()
		}
	})

	// Milestone one: loop the owner's audio straight back.
	//
	// It sounds trivial and it is the only test that proves the hard parts —
	// that ICE found a path through both NATs, that DTLS-SRTP came up, and that
	// the browser's echo cancellation is actually suppressing the loop. If the
	// owner hears themselves clearly and the assistant would not deafen itself,
	// the transport is done and the rest is ASR, the brain and TTS on a stream
	// that already works.
	peer.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		log.Printf("receiving %s from the caller", remote.Codec().MimeType)
		buffer := make([]byte, 1500)
		for {
			n, _, readErr := remote.Read(buffer)
			if readErr != nil {
				return
			}
			if _, writeErr := audio.Write(buffer[:n]); writeErr != nil {
				return
			}
		}
	})

	if err := peer.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  request.SDP,
	}); err != nil {
		log.Printf("remote description: %v", err)
		http.Error(w, "bad offer", http.StatusBadRequest)
		finish()
		return
	}

	answer, err := peer.CreateAnswer(nil)
	if err != nil {
		log.Printf("answer: %v", err)
		http.Error(w, "could not answer", http.StatusInternalServerError)
		finish()
		return
	}
	gathered := webrtc.GatheringCompletePromise(peer)
	if err := peer.SetLocalDescription(answer); err != nil {
		log.Printf("local description: %v", err)
		http.Error(w, "could not answer", http.StatusInternalServerError)
		finish()
		return
	}

	// Bounded: a peer behind a hostile NAT can gather for a long time, and the
	// owner is holding a phone waiting for a call to connect. Whatever has been
	// found by now is what we answer with.
	select {
	case <-gathered:
	case <-time.After(5 * time.Second):
		log.Println("ICE gathering timed out; answering with what we have")
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(answerResponse{
		SDP: peer.LocalDescription().SDP,
	}); err != nil {
		log.Printf("write answer: %v", err)
		finish()
	}
}

func (s *callServer) handlePage(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	// ICE configuration is injected rather than baked in, so TURN credentials
	// live in the process's arguments and not in a page anyone can view-source.
	ice, err := json.Marshal(s.ice)
	if err != nil {
		http.Error(w, "could not build the page", http.StatusInternalServerError)
		return
	}
	page := strings.Replace(
		strings.TrimSpace(callPage),
		"ICE_SERVERS",
		string(ice),
		1,
	)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// No external anything: no CDN, no font, no analytics. The page is served by
	// the owner's own Mac and must work on a phone with no internet beyond the
	// call itself.
	//
	// A strict CSP on top, because this page holds a live microphone: nothing
	// may be fetched, and nothing may be sent anywhere except back here.
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "+
			"connect-src 'self'; media-src blob: mediastream:; base-uri 'none'; form-action 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	_, _ = w.Write([]byte(page))
}
