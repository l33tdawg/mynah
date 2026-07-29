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
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
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

// How long an appliance's poll is held open before it is answered empty.
//
// A var rather than a const so tests can shorten it. httptest.Server.Close
// blocks on outstanding requests, so a held poll makes every test that
// registers an appliance take the full window — a hundred seconds of a suite
// that otherwise runs in one.
var pollWindow = 50 * time.Second

// How long an appliance may go unheard from before its token is forgotten.
// Twice the poll window, so one lost poll is not one dropped registration.
func applianceTTL() time.Duration { return 2 * pollWindow }

const (
	// How long a caller waits for the appliance to answer. Generous because the
	// appliance spends most of it gathering ICE candidates, and a caller who has
	// just tapped a link will wait a few seconds far more happily than they will
	// tap again.
	answerWindow = 30 * time.Second

	// How long a minted TURN credential lasts. It only has to survive the
	// setup of one call.
	turnCredentialTTL = time.Hour
)

func main() {
	var (
		domain         = flag.String("domain", "", "hostname to serve and obtain a certificate for (required)")
		email          = flag.String("email", "", "contact address for the certificate authority")
		cacheDir       = flag.String("cert-cache", "/var/lib/sage-call-relay", "where to keep issued certificates")
		secretFile     = flag.String("secret-file", "", "file of appliance secrets, one per line (required)")
		rootKeyFile    = flag.String("root-key-file", "", "file holding the root key appliances are minted from; without it /appliance/enrol refuses")
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

	secrets, err := readSecrets(*secretFile)
	if err != nil {
		log.Fatalf("appliance secrets: %v", err)
	}
	log.Printf("%d appliance secret(s) loaded", len(secrets))
	var rootKey []byte
	if *rootKeyFile != "" {
		if rootKey, err = readSecret(*rootKeyFile); err != nil {
			log.Fatalf("root key: %v", err)
		}
		log.Println("minting is on: appliances can enrol themselves")
	} else {
		log.Println("no root key: appliances cannot enrol and must be added to the secret file by hand")
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
		secrets: secrets,
		rootKey: rootKey,
		// Once an hour per address. An appliance enrols once and keeps the
		// result; a household behind one address that reinstalls a few times in
		// an afternoon still fits, and a loop does not.
		enrolments: newEnrolmentLimiter(8, time.Hour),
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
	secrets, err := readSecrets(path)
	if err != nil {
		return nil, err
	}
	return secrets[0], nil
}

// readSecrets loads every appliance secret, one per line.
//
// Blank lines and # comments are skipped, so the file can say whose secret is
// whose — which is the difference between revoking one tester and revoking all
// of them.
func readSecrets(path string) ([][]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var secrets [][]byte
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		secrets = append(secrets, []byte(line))
	}
	if len(secrets) == 0 {
		return nil, fmt.Errorf("%s holds no secrets", path)
	}
	return secrets, nil
}

// appliance is one Mac, waiting.
type appliance struct {
	offers   chan *call
	lastSeen time.Time

	// Which credential claimed this token. A token is a live microphone, and
	// without this any authenticated appliance could poll somebody else's token
	// and take delivery of their call.
	owner string
}

// enrolmentLimiter caps how often one address may mint an identity.
//
// Enrolment asks for nothing identifying, which is deliberate and which makes it
// open by construction — so the only thing standing between the relay and a
// script minting identities in a loop is this. A fixed window rather than a
// token bucket: the thing being limited happens once in an appliance's life, so
// precision at the boundary buys nothing and a map of counters is something an
// operator can reason about at 3am.
//
// Addresses are forgotten as they age out, so this cannot grow without bound on
// a relay somebody points a scanner at.
type enrolmentLimiter struct {
	mu     sync.Mutex
	window time.Duration
	limit  int
	seen   map[string][]time.Time
}

func newEnrolmentLimiter(limit int, window time.Duration) *enrolmentLimiter {
	return &enrolmentLimiter{window: window, limit: limit, seen: map[string][]time.Time{}}
}

func (l *enrolmentLimiter) allow(address string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := time.Now().Add(-l.window)
	for who, stamps := range l.seen {
		kept := stamps[:0]
		for _, stamp := range stamps {
			if stamp.After(cutoff) {
				kept = append(kept, stamp)
			}
		}
		if len(kept) == 0 {
			delete(l.seen, who)
			continue
		}
		l.seen[who] = kept
	}

	if len(l.seen[address]) >= l.limit {
		log.Printf("enrolment refused: %s is over the limit", address)
		return false
	}
	l.seen[address] = append(l.seen[address], time.Now())
	return true
}

// call is one offer travelling out and one answer travelling back.
type call struct {
	id     string
	offer  string
	answer chan string
}

type relay struct {
	secrets [][]byte
	// rootKey mints and re-derives per-appliance secrets. Nil on a relay
	// started without one, which keeps serving the hand-provisioned list and
	// refuses to enrol rather than pretending to.
	rootKey    []byte
	enrolments *enrolmentLimiter
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
	mux.HandleFunc("POST /appliance/enrol", r.handleEnrol)
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
		cutoff := time.Now().Add(-applianceTTL())
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

// handleEnrol mints an appliance its own secret.
//
// **Why this exists.** Calling used to require a line hand-added to a file on
// this server, which is a workaround wearing the clothes of a feature: it does
// not scale past the people who can ssh here, and it means an owner who links
// their phone gets half a product with no way to ask for the other half. The
// owner's instruction was plain — "call relay secret is something we should be
// minting for the user".
//
// **Nothing is stored.** The secret is `HMAC(rootKey, id)`, so this hands back
// something it can recompute on every later request and immediately forgets. No
// user table: nothing to store, back up, replicate, or leak.
//
// **Nothing identifying is asked for.** No phone number, no hash of one, no
// account. An enrolment is anonymous by construction, because the alternative is
// a central server holding a list of who owns an appliance — and this product's
// promise is that the owner's words stay on their Mac. A phone number recovers
// from a hash in seconds, so hashing it would have been the appearance of
// privacy rather than privacy.
//
// **What that costs, stated rather than hidden.** Anonymous enrolment is open
// enrolment, so this is rate limited per address. The exposure is registration
// spam and nothing more: the relay carries signalling, never audio. Media is
// DTLS-SRTP between the endpoints and is not available here even to an operator
// with root on this box.
func (r *relay) handleEnrol(w http.ResponseWriter, req *http.Request) {
	if len(r.rootKey) == 0 {
		// Said plainly rather than 500ing: a relay running without a root key
		// is a deployment that has not been given one, and the operator reading
		// this log line is the person who can fix it.
		log.Printf("enrolment refused: this relay was started without -root-key-file")
		http.Error(w, "enrolment is not available on this relay", http.StatusNotImplemented)
		return
	}
	if !r.enrolments.allow(clientAddress(req)) {
		http.Error(w, "too many enrolments; try again later", http.StatusTooManyRequests)
		return
	}

	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		http.Error(w, "could not mint an identity", http.StatusInternalServerError)
		return
	}
	id := hex.EncodeToString(raw)
	secret := rendezvous.DeriveApplianceSecret(r.rootKey, id)

	log.Printf("enrolled appliance %s", id)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"id":     id,
		"secret": hex.EncodeToString(secret),
	})
}

// clientAddress is the address to rate limit, honouring one proxy hop.
//
// `X-Forwarded-For` is attacker-controlled where nothing strips it, so only the
// last hop is trusted — the value this relay's own front door appended. Behind
// no proxy the header is absent and RemoteAddr is the truth.
func clientAddress(req *http.Request) string {
	if forwarded := req.Header.Get("X-Forwarded-For"); forwarded != "" {
		parts := strings.Split(forwarded, ",")
		return strings.TrimSpace(parts[len(parts)-1])
	}
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		return req.RemoteAddr
	}
	return host
}

func (r *relay) authenticate(w http.ResponseWriter, req *http.Request) (string, bool) {
	credential := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")

	// The minted path: one derivation and one comparison, whoever the caller
	// is. `Identify` below checks the credential against every secret the relay
	// holds, which is linear in the number of owners on every request — fine for
	// the handful of hand-provisioned testers it was written for, and not a way
	// to run a product.
	if id := req.Header.Get("X-Sage-Appliance"); id != "" && len(r.rootKey) > 0 {
		secret := rendezvous.DeriveApplianceSecret(r.rootKey, id)
		if rendezvous.VerifyAppliance(secret, credential, time.Now(), 5*time.Minute) {
			return id, true
		}
		http.Error(w, "not authorised", http.StatusUnauthorized)
		return "", false
	}

	// The hand-provisioned path, kept so the Macs already carrying a secret from
	// the file on this server keep working across this deploy.
	who, ok := rendezvous.Identify(r.secrets, credential, time.Now(), 5*time.Minute)
	if !ok {
		http.Error(w, "not authorised", http.StatusUnauthorized)
		return "", false
	}
	return who, true
}

// handleListen parks an appliance until someone calls it.
//
// Long-polling rather than a WebSocket. The exchange is one offer and one answer
// per call, so a persistent framed protocol buys nothing over a held request —
// and it costs a dependency, a ping/pong keepalive, and a reconnect state
// machine, each of which is a way for the owner's appliance to be quietly
// unreachable.
func (r *relay) handleListen(w http.ResponseWriter, req *http.Request) {
	who, ok := r.authenticate(w, req)
	if !ok {
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
		// Issuing a link revokes the last one.
		//
		// An appliance has exactly one live token, because the owner assumes the
		// most recent link they were sent is the only one that works — and a
		// call link is a live microphone. Without this, every //call left its
		// predecessor serving a page forever, and old links in a Signal thread
		// stayed usable indefinitely.
		for token, other := range r.appliances {
			if other.owner == who {
				delete(r.appliances, token)
				log.Printf("appliance %s issued a new link; the previous one is revoked", who)
			}
		}
		waiting = &appliance{offers: make(chan *call, 1), owner: who}
		r.appliances[body.Token] = waiting
		log.Printf("appliance %s is listening", who)
	} else if waiting.owner != who {
		// Somebody else's token. Refused rather than shared: two appliances on
		// one token means whichever polls first takes the call, which is a
		// wiretap wearing a race condition.
		r.mu.Unlock()
		log.Printf("appliance %s tried to claim a token belonging to %s", who, waiting.owner)
		http.Error(w, "not authorised", http.StatusUnauthorized)
		return
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
	if _, ok := r.authenticate(w, req); !ok {
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
			// The app's own icon is inlined as a data URI; nothing is fetched.
			"img-src data:; "+
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
