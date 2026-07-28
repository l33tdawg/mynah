// Command sage-call-relay serves the call page and introduces the two ends.
//
// # Why anything public exists at all
//
// The appliance could serve its own page — it did, and that is precisely what
// failed. A Mac on a home network has no name a certificate authority will sign
// and no address anyone outside the house can reach, so serving the page from it
// means a self-signed certificate. Browsers do not merely warn about those; they
// refuse to persist a permission for the origin, and without a persisted media
// permission Chrome replaces the phone's real ICE candidates with random .local
// names. The two machines end up on the same Wi-Fi, unable to name each other.
// The certificate warning is not the cost of that design — the broken call is.
//
// So the page comes from here, where a real certificate is possible. One
// hostname serves every appliance; nothing is provisioned per owner.
//
// # What this relay is not
//
// It is not in the call. It carries the offer and the answer — a few kilobytes
// of SDP — and the candidates inside those describe routes between the phone and
// the Mac. When both are on the same Wi-Fi, ICE selects the host pair and the
// audio crosses the room. This host never sees it.
//
// What it does learn is that a call happened, when, and between which addresses,
// because that is what an SDP contains. On a product whose argument is that the
// owner's words stay on their machine, that is a real cost and worth stating
// plainly: it is why this is a binary the owner runs on a host they rent, rather
// than a service anyone is asked to trust. Media never reaches it even when the
// call is relayed, since TURN traffic stays sealed under DTLS-SRTP.
//
// # The appliance never accepts a connection
//
// It dials out and waits. No port forwarded, no certificate, no address that has
// to stay reachable — the same reason natter exists for SAGE itself.
//
//	sage-call-relay -domain call.sage.delivery \
//	  -secret-file /etc/sage/relay.secret \
//	  -turn turn.sage.delivery:3478 -turn-secret-file /etc/sage/turn.secret
package main

import (
	"context"
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

	"golang.org/x/crypto/acme/autocert"

	"github.com/l33tdawg/sage-voice-bridge/webrtc/internal/callpage"
	"github.com/l33tdawg/sage-voice-bridge/webrtc/internal/rendezvous"
)

const (
	// How long an appliance's poll is held open before it is answered empty.
	// Long enough that an idle appliance is nearly silent on the wire, short
	// enough that a dead connection is noticed and replaced rather than leaving
	// the owner's next call ringing into a socket that is already gone.
	pollWindow = 50 * time.Second

	// How long a caller waits for the appliance to answer. Generous because the
	// appliance spends most of it gathering ICE candidates, and a caller who has
	// just tapped a link will wait a few seconds far more happily than they will
	// tap again.
	answerWindow = 30 * time.Second

	// How long an appliance may go unheard from before its token is forgotten.
	// Twice the poll window, so one lost poll is not one dropped registration.
	applianceTTL = 2 * pollWindow

	// How long a minted TURN credential lasts. It only has to survive the
	// setup of one call.
	turnCredentialTTL = time.Hour
)

func main() {
	var (
		domain         = flag.String("domain", "", "hostname to serve and obtain a certificate for (required)")
		email          = flag.String("email", "", "contact address for the certificate authority")
		cacheDir       = flag.String("cert-cache", "/var/lib/sage-call-relay", "where to keep issued certificates")
		secretFile     = flag.String("secret-file", "", "file holding the shared secret appliances authenticate with (required)")
		stunURL        = flag.String("stun", "stun:stun.l.google.com:19302", "STUN server offered to callers")
		turnHost       = flag.String("turn", "", "TURN server as host:port, e.g. turn.sage.delivery:3478")
		turnSecretFile = flag.String("turn-secret-file", "", "file holding the TURN shared secret")
		httpAddr       = flag.String("http", ":80", "plain HTTP address, for certificate challenges and redirects")
		httpsAddr      = flag.String("https", ":443", "HTTPS address")
	)
	flag.Parse()

	if *domain == "" || *secretFile == "" {
		fmt.Fprintln(os.Stderr, `error: -domain and -secret-file are required.

  sage-call-relay -domain call.sage.delivery -secret-file /etc/sage/relay.secret`)
		os.Exit(2)
	}

	secret, err := readSecret(*secretFile)
	if err != nil {
		log.Fatalf("shared secret: %v", err)
	}
	var turnSecret []byte
	if *turnSecretFile != "" {
		if turnSecret, err = readSecret(*turnSecretFile); err != nil {
			log.Fatalf("turn secret: %v", err)
		}
	}
	if *turnHost == "" {
		log.Println("no TURN server configured: calls will fail where ICE cannot find a direct route")
	} else if len(turnSecret) == 0 {
		log.Println("TURN configured without a secret: the relay cannot mint credentials and calls will not use it")
	}

	relay := &relay{
		secret:     secret,
		stunURL:    *stunURL,
		turnHost:   *turnHost,
		turnSecret: turnSecret,
		appliances: map[string]*appliance{},
		pending:    map[string]*call{},
	}
	go relay.forgetStaleAppliances()

	mux := relay.routes()

	manager := &autocert.Manager{
		Prompt:     autocert.AcceptTOS,
		HostPolicy: autocert.HostWhitelist(*domain),
		Cache:      autocert.DirCache(*cacheDir),
		Email:      *email,
	}

	// Port 80 exists for the certificate challenge. Everything else it receives
	// is redirected rather than served: this page holds a live microphone, and
	// answering it over plain HTTP would produce exactly the silent
	// secure-context failure this whole design exists to remove.
	plain := &http.Server{
		Addr:              *httpAddr,
		Handler:           manager.HTTPHandler(nil),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		if err := plain.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("http listener: %v", err)
		}
	}()

	secure := &http.Server{
		Addr:              *httpsAddr,
		Handler:           mux,
		TLSConfig:         manager.TLSConfig(),
		ReadHeaderTimeout: 10 * time.Second,
		// No WriteTimeout: an appliance's poll is held open for the better part
		// of a minute by design, and a write deadline would sever it.
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop
		log.Println("shutting down")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = secure.Shutdown(ctx)
		_ = plain.Shutdown(ctx)
	}()

	log.Printf("serving calls for %s", *domain)
	if err := secure.ListenAndServeTLS("", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// readSecret loads a secret from a file rather than a flag.
//
// A flag is visible in the process table to every user on the host and in the
// unit file to anyone who can read it. This at least confines it to something
// with permissions.
func readSecret(path string) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	secret := strings.TrimSpace(string(raw))
	if secret == "" {
		return nil, fmt.Errorf("%s is empty", path)
	}
	return []byte(secret), nil
}

// appliance is one Mac, waiting.
type appliance struct {
	offers   chan *call
	lastSeen time.Time
}

// call is one offer travelling out and one answer travelling back.
type call struct {
	id     string
	offer  string
	answer chan string
}

type relay struct {
	secret     []byte
	stunURL    string
	turnHost   string
	turnSecret []byte

	mu         sync.Mutex
	appliances map[string]*appliance
	pending    map[string]*call
	nextCall   uint64
}

// routes is separate from main so a test can exercise the relay without
// standing up a certificate authority.
func (r *relay) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /appliance/listen", r.handleListen)
	mux.HandleFunc("POST /appliance/answer", r.handleAnswer)
	mux.HandleFunc("GET /{token}", r.handlePage)
	mux.HandleFunc("POST /{token}/offer", r.handleOffer)
	mux.HandleFunc("POST /{token}/report", r.handleReport)
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"ok":true,"appliances":%d}`, r.count())
	})
	return mux
}

func (r *relay) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.appliances)
}

// forgetStaleAppliances drops registrations nobody is polling.
//
// An appliance that is shut down mid-call, or whose owner started a new call
// with a new token, leaves its old entry behind. Without this the relay
// accumulates tokens that resolve to nothing and serves a page for a call that
// can never be answered — which reaches the owner as a link that loads and then
// fails, the least diagnosable outcome available.
func (r *relay) forgetStaleAppliances() {
	for range time.Tick(pollWindow) {
		cutoff := time.Now().Add(-applianceTTL)
		r.mu.Lock()
		for token, waiting := range r.appliances {
			if waiting.lastSeen.Before(cutoff) {
				delete(r.appliances, token)
				log.Printf("forgot an appliance that stopped polling")
			}
		}
		r.mu.Unlock()
	}
}

func (r *relay) authenticate(w http.ResponseWriter, req *http.Request) bool {
	credential := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
	if !rendezvous.VerifyAppliance(r.secret, credential, time.Now(), 5*time.Minute) {
		http.Error(w, "not authorised", http.StatusUnauthorized)
		return false
	}
	return true
}

// handleListen parks an appliance until someone calls it.
//
// Long-polling rather than a WebSocket. The exchange is one offer and one answer
// per call, so a persistent framed protocol buys nothing over a held request —
// and it costs a dependency, a ping/pong keepalive, and a reconnect state
// machine, each of which is a way for the owner's appliance to be quietly
// unreachable.
func (r *relay) handleListen(w http.ResponseWriter, req *http.Request) {
	if !r.authenticate(w, req) {
		return
	}
	var body struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 4<<10)).Decode(&body); err != nil || body.Token == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	r.mu.Lock()
	waiting, known := r.appliances[body.Token]
	if !known {
		waiting = &appliance{offers: make(chan *call, 1)}
		r.appliances[body.Token] = waiting
		log.Printf("an appliance is listening")
	}
	waiting.lastSeen = time.Now()
	r.mu.Unlock()

	select {
	case incoming := <-waiting.offers:
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"call":  incoming.id,
			"offer": incoming.offer,
		})
	case <-time.After(pollWindow):
		// Nothing happened, which is the normal case. The appliance polls again.
		w.WriteHeader(http.StatusNoContent)
	case <-req.Context().Done():
	}
}

// handleAnswer takes the appliance's SDP back to the waiting caller.
func (r *relay) handleAnswer(w http.ResponseWriter, req *http.Request) {
	if !r.authenticate(w, req) {
		return
	}
	var body struct {
		Call   string `json:"call"`
		Answer string `json:"answer"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 256<<10)).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	r.mu.Lock()
	waiting, known := r.pending[body.Call]
	delete(r.pending, body.Call)
	r.mu.Unlock()
	if !known {
		// The caller gave up first. Not an error worth failing on — the
		// appliance has no way to know and nothing useful to do about it.
		w.WriteHeader(http.StatusNoContent)
		return
	}
	waiting.answer <- body.Answer
	w.WriteHeader(http.StatusNoContent)
}

// handleOffer hands a caller's SDP to the appliance and waits for its reply.
func (r *relay) handleOffer(w http.ResponseWriter, req *http.Request) {
	token := req.PathValue("token")
	var body struct {
		SDP string `json:"sdp"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 256<<10)).Decode(&body); err != nil {
		http.Error(w, "bad offer", http.StatusBadRequest)
		return
	}

	r.mu.Lock()
	appliance, known := r.appliances[token]
	if !known {
		r.mu.Unlock()
		http.Error(w, "no appliance is listening for this call", http.StatusNotFound)
		return
	}
	r.nextCall++
	outgoing := &call{
		id:     fmt.Sprintf("c%d", r.nextCall),
		offer:  body.SDP,
		answer: make(chan string, 1),
	}
	r.pending[outgoing.id] = outgoing
	r.mu.Unlock()

	select {
	case appliance.offers <- outgoing:
	default:
		// The appliance is registered but not currently holding a poll — asleep,
		// or already setting up another call. Failing now beats a caller
		// watching a spinner for thirty seconds.
		r.mu.Lock()
		delete(r.pending, outgoing.id)
		r.mu.Unlock()
		http.Error(w, "the appliance is not answering", http.StatusServiceUnavailable)
		return
	}

	select {
	case answer := <-outgoing.answer:
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"sdp": answer})
	case <-time.After(answerWindow):
		r.mu.Lock()
		delete(r.pending, outgoing.id)
		r.mu.Unlock()
		http.Error(w, "the appliance did not answer in time", http.StatusGatewayTimeout)
	case <-req.Context().Done():
		r.mu.Lock()
		delete(r.pending, outgoing.id)
		r.mu.Unlock()
	}
}

// handlePage serves the call page, if that call exists.
//
// A token with no appliance behind it is a 404 and not a page. Serving the page
// anyway would let anyone sweep the host for live calls by watching which paths
// render — and would hand the owner a link that loads, asks for a microphone,
// and then fails.
func (r *relay) handlePage(w http.ResponseWriter, req *http.Request) {
	token := req.PathValue("token")
	r.mu.Lock()
	_, known := r.appliances[token]
	r.mu.Unlock()
	if !known {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	ice, err := json.Marshal(r.iceServers())
	if err != nil {
		http.Error(w, "could not build the page", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "+
			"connect-src 'self' "+r.iceOrigins()+"; media-src blob: mediastream:; "+
			"base-uri 'none'; form-action 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	// A call link is not something to be indexed, previewed, or unfurled by a
	// messaging app that happens to see it.
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
	_, _ = w.Write([]byte(callpage.Render(string(ice), "/"+token+"/offer", "/"+token+"/report")))
}

func (r *relay) handleReport(w http.ResponseWriter, req *http.Request) {
	var report struct {
		Event  string `json:"event"`
		Detail string `json:"detail"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 8<<10)).Decode(&report); err != nil {
		http.Error(w, "bad report", http.StatusBadRequest)
		return
	}
	log.Printf("phone: %s %s", clean(report.Event), clean(report.Detail))
	w.WriteHeader(http.StatusNoContent)
}

// clean keeps a log line a log line — a newline in a reported value would
// otherwise let a caller forge one.
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

// iceServers is what the page is told to try, with fresh TURN credentials.
func (r *relay) iceServers() []map[string]any {
	servers := []map[string]any{}
	if r.stunURL != "" {
		servers = append(servers, map[string]any{"urls": []string{r.stunURL}})
	}
	if r.turnHost != "" && len(r.turnSecret) > 0 {
		user, password := rendezvous.TURNCredential(r.turnSecret, time.Now().Add(turnCredentialTTL))
		servers = append(servers, map[string]any{
			// UDP first because it is what a call wants, TCP behind it because
			// restrictive networks block UDP outright and a relay that only
			// speaks UDP is no relay at all on the connections that need one.
			"urls": []string{
				"turn:" + r.turnHost + "?transport=udp",
				"turn:" + r.turnHost + "?transport=tcp",
			},
			"username":   user,
			"credential": password,
		})
	}
	return servers
}

// iceOrigins lists the STUN and TURN URLs for the page's connect-src.
//
// Chrome applies connect-src to ICE server URLs as well as to fetch, so a
// policy that omits them strips the page's only means of finding a route off the
// local network — silently, with no error the page can catch.
func (r *relay) iceOrigins() string {
	var origins []string
	for _, server := range r.iceServers() {
		urls, _ := server["urls"].([]string)
		origins = append(origins, urls...)
	}
	return strings.Join(origins, " ")
}
