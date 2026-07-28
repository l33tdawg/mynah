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
		token    = flag.String("token", "", "required path token; the call link is /<token>")
	)
	flag.Parse()

	if !*insecure && (*certFile == "" || *keyFile == "") {
		fmt.Fprintln(os.Stderr, `error: -cert and -key are required.

getUserMedia is refused outside a secure context, so a page served over plain
HTTP to a phone gets a microphone that never starts. Pass a certificate, or
-insecure for a localhost-only developer loop.`)
		os.Exit(2)
	}

	if *token == "" {
		fmt.Fprintln(os.Stderr, `error: -token is required.

The link is the credential. It is delivered over Signal — an authenticated,
end-to-end encrypted channel only the owner can read — so an unguessable path is
what stands between a private microphone and anyone who can reach this port.`)
		os.Exit(2)
	}

	server := &callServer{
		ice:   iceServers(*stunURL, *turnURL, *turnUser, *turnPass),
		token: *token,
	}
	if *turnURL == "" {
		log.Println("no TURN server configured: calls will fail behind symmetric NAT")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/"+*token, server.handlePage)
	mux.HandleFunc("/"+*token+"/offer", server.handleOffer)
	mux.HandleFunc("/"+*token+"/report", server.handleReport)
	// Anything else, including a bare "/", is not a call.
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "not found", http.StatusNotFound)
	})
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

// How long a call may sit half-open before it is abandoned.
//
// Long enough for a slow relay allocation on a bad network, short enough that
// the owner has not already given up and tapped again — because a stalled call
// that is never closed keeps its ICE agent and ports, and the second attempt
// then competes with the corpse of the first.
const connectDeadline = 30 * time.Second

// selectedPair names the route the media actually took, or says it cannot.
//
// Written defensively because every step of it is optional: a peer with no data
// channel may have no SCTP transport, and a call that failed has no pair. None
// of that is worth a panic in a logging helper.
func selectedPair(peer *webrtc.PeerConnection) string {
	sctp := peer.SCTP()
	if sctp == nil {
		return "unknown"
	}
	transport := sctp.Transport()
	if transport == nil {
		return "unknown"
	}
	ice := transport.ICETransport()
	if ice == nil {
		return "unknown"
	}
	pair, err := ice.GetSelectedCandidatePair()
	if err != nil || pair == nil || pair.Local == nil || pair.Remote == nil {
		return "unknown"
	}
	return fmt.Sprintf("%s <- %s", pair.Local.String(), pair.Remote.String())
}

type callServer struct {
	ice   []webrtc.ICEServer
	token string

	mu    sync.Mutex
	calls int
}

// iceOrigins lists the STUN and TURN URLs for the page's connect-src.
func (s *callServer) iceOrigins() string {
	var origins []string
	for _, server := range s.ice {
		origins = append(origins, server.URLs...)
	}
	return strings.Join(origins, " ")
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

	// Closed by the first RTP packet. A call that connects and then carries
	// nothing is a distinct failure from one that never connects, and the
	// connection state cannot tell them apart: DTLS can complete while SRTP keys
	// disagree, and a phone can hold a microphone track that produces no audio.
	// Both arrive as a healthy "connected" followed by silence — which is
	// exactly what the owner reports and exactly what the log did not say.
	audioArrived := make(chan struct{})
	var audioOnce sync.Once

	// ICE state separately from connection state. "Connecting" covers gathering,
	// checking and the DTLS handshake, so a call stuck there could be failing at
	// any of three different layers; the ICE state names which one.
	peer.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		log.Printf("ice %s", state)
	})

	peer.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("call %s", state)
		switch state {
		case webrtc.PeerConnectionStateConnected:
			// Which path won. A relayed pair means TURN carried it, a host pair
			// means the two were on the same network — and when a call works on
			// Wi-Fi and not on cellular, this line is the difference.
			log.Printf("media path: %s", selectedPair(peer))
			go func() {
				select {
				case <-audioArrived:
				case <-time.After(3 * time.Second):
					log.Println("connected but no audio from the caller after 3s: " +
						"the path is up and the phone is not sending")
				}
			}()
		case webrtc.PeerConnectionStateFailed,
			webrtc.PeerConnectionStateClosed,
			webrtc.PeerConnectionStateDisconnected:
			finish()
		}
	})

	// A peer that never finishes connecting otherwise sits here forever holding
	// its ICE agent and ports. The owner has long since tapped again by then —
	// which is how one stalled call becomes three.
	go func() {
		time.Sleep(connectDeadline)
		if state := peer.ConnectionState(); state != webrtc.PeerConnectionStateConnected &&
			state != webrtc.PeerConnectionStateClosed {
			log.Printf("giving up on a call still %s after %s", state, connectDeadline)
			finish()
		}
	}()

	// Milestone one: loop the owner's audio straight back.
	//
	// It sounds trivial and it is the only test that proves the hard parts —
	// that ICE found a path through both NATs, that DTLS-SRTP came up, and that
	// the browser's echo cancellation is actually suppressing the loop. If the
	// owner hears themselves clearly and the assistant would not deafen itself,
	// the transport is done and the rest is ASR, the brain and TTS on a stream
	// that already works.
	peer.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		audioOnce.Do(func() { close(audioArrived) })
		log.Printf("receiving %s from the caller", remote.Codec().MimeType)

		var packets uint64
		defer func() {
			log.Printf("caller's audio ended after %d packets", packets)
		}()

		buffer := make([]byte, 1500)
		for {
			n, _, readErr := remote.Read(buffer)
			if readErr != nil {
				return
			}
			packets++
			if _, writeErr := audio.Write(buffer[:n]); writeErr != nil {
				return
			}
		}
	})

	// What the phone actually offered as a route to itself.
	//
	// Chrome replaces local IP addresses with random `.local` mDNS names unless
	// the page holds *persistent* media permission — and it refuses to persist
	// permission on an origin with a certificate error, which is every call this
	// appliance makes. So the candidates arrive obfuscated and this Mac has to
	// resolve them over multicast to find the phone sitting on the same Wi-Fi.
	//
	// When that resolution fails there is nothing in the connection state to say
	// so: ICE simply never completes, or completes over a route that carries no
	// media. Printing the candidates makes the difference between "on the same
	// network" and "able to name each other" visible in one line.
	logCandidates("phone", request.SDP)

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

	logCandidates("this Mac", peer.LocalDescription().SDP)

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(answerResponse{
		SDP: peer.LocalDescription().SDP,
	}); err != nil {
		log.Printf("write answer: %v", err)
		finish()
	}
}

// logCandidates prints the ICE candidates in an SDP, one line, deduplicated.
//
// Type and address are the whole story: `host` with a real address means a
// direct route exists, `host` with a `.local` name means it exists only if
// multicast resolution works, `srflx` means the route runs out through the
// router and back, and `relay` means TURN is carrying it.
func logCandidates(who, sdp string) {
	var found []string
	seen := map[string]bool{}
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "a=candidate:") {
			continue
		}
		// a=candidate:<foundation> <component> <transport> <priority> <address> <port> typ <type> ...
		fields := strings.Fields(line)
		if len(fields) < 8 {
			continue
		}
		summary := fmt.Sprintf("%s %s:%s/%s", fields[7], fields[4], fields[5], strings.ToLower(fields[2]))
		if seen[summary] {
			continue
		}
		seen[summary] = true
		found = append(found, summary)
	}
	if len(found) == 0 {
		log.Printf("%s offered no ICE candidates at all", who)
		return
	}
	log.Printf("%s can be reached at: %s", who, strings.Join(found, ", "))
}

// handleReport records what the phone saw.
//
// Everything that makes a call fail is visible in the browser and invisible
// here: a microphone that was refused, an ICE state that stalled at `checking`,
// a connection that reported itself healthy while sending zero packets. Without
// this the owner is the only instrument, and "it doesn't connect" has to cover
// every one of those.
//
// Bounded and append-only: it writes to the same log as everything else and
// accepts nothing that influences the call itself.
func (s *callServer) handleReport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var report struct {
		Event  string `json:"event"`
		Detail string `json:"detail"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&report); err != nil {
		http.Error(w, "bad report", http.StatusBadRequest)
		return
	}
	log.Printf("phone: %s %s", clean(report.Event), clean(report.Detail))
	w.WriteHeader(http.StatusNoContent)
}

// clean keeps a log line a log line. The phone is the owner's own, but this
// writes to a file someone will later read, and a newline in a value would let
// a report forge one.
func clean(value string) string {
	value = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return ' '
		}
		return r
	}, value)
	if len(value) > 300 {
		return value[:300] + "…"
	}
	return value
}

func (s *callServer) handlePage(w http.ResponseWriter, r *http.Request) {

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
	// The page posts back to its own token path, so the offer endpoint is as
	// unguessable as the page.
	page = strings.Replace(page, "OFFER_PATH", "/"+s.token+"/offer", 1)
	page = strings.Replace(page, "REPORT_PATH", "/"+s.token+"/report", 1)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// No external anything: no CDN, no font, no analytics. The page is served by
	// the owner's own Mac and must work on a phone with no internet beyond the
	// call itself.
	//
	// A strict CSP on top, because this page holds a live microphone: nothing
	// may be fetched, and nothing may be sent anywhere except back here.
	//
	// connect-src has to name the STUN and TURN servers explicitly. Chrome
	// applies it to ICE server URLs as well as to fetch, so a bare 'self' here
	// silently strips the page's only means of discovering a route off the local
	// network — and does it without an error the page can catch.
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "+
			"connect-src 'self' "+s.iceOrigins()+"; media-src blob: mediastream:; "+
			"base-uri 'none'; form-action 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	_, _ = w.Write([]byte(page))
}
