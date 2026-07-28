package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/l33tdawg/sage-voice-bridge/webrtc/internal/rendezvous"
)

func init() {
	// The suite registers appliances; a real poll window would make every such
	// test wait it out at Close().
	pollWindow = 200 * time.Millisecond
}

func testRelay() *relay {
	return &relay{
		secrets:    [][]byte{[]byte("shared"), []byte("another tester")},
		stunURL:    "stun:stun.example.com:19302",
		appliances: map[string]*appliance{},
		pending:    map[string]*call{},
	}
}

func authorised() string {
	return "Bearer " + rendezvous.ApplianceCredential([]byte("shared"), time.Now())
}

// listen registers an appliance and returns once it is holding a poll, so a test
// that posts an offer next is not racing the registration.
func listen(t *testing.T, server *httptest.Server, token string) chan *http.Response {
	t.Helper()
	done := make(chan *http.Response, 1)
	ready := make(chan struct{})
	go func() {
		request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/listen",
			strings.NewReader(`{"token":"`+token+`"}`))
		request.Header.Set("Authorization", authorised())
		close(ready)
		response, err := server.Client().Do(request)
		if err != nil {
			done <- nil
			return
		}
		done <- response
	}()
	<-ready
	// The registration happens inside the handler, so wait for it to appear
	// rather than for the request to be sent.
	for i := 0; i < 200; i++ {
		if server.Config.Handler != nil {
			time.Sleep(5 * time.Millisecond)
		}
		if len(done) > 0 {
			break
		}
		if hasAppliance(server, token) {
			break
		}
	}
	return done
}

func hasAppliance(server *httptest.Server, token string) bool {
	response, err := server.Client().Get(server.URL + "/health")
	if err != nil {
		return false
	}
	defer response.Body.Close()
	var health struct {
		Appliances int `json:"appliances"`
	}
	_ = json.NewDecoder(response.Body).Decode(&health)
	return health.Appliances > 0
}

// An offer reaches the waiting appliance and its answer reaches the caller.
//
// This is the whole reason the relay exists, reduced to its smallest form: a
// machine that never accepts a connection still receives a call.
func TestAnOfferReachesTheApplianceAndTheAnswerComesBack(t *testing.T) {
	relay := testRelay()
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	waiting := listen(t, server, "tok")

	// The caller.
	offered := make(chan *http.Response, 1)
	go func() {
		response, err := server.Client().Post(server.URL+"/tok/offer", "application/json",
			strings.NewReader(`{"sdp":"the caller's sdp"}`))
		if err != nil {
			offered <- nil
			return
		}
		offered <- response
	}()

	// The appliance's poll returns with the offer.
	select {
	case response := <-waiting:
		if response == nil {
			t.Fatal("the appliance's poll failed")
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("the appliance got %s, wanted the offer", response.Status)
		}
		var incoming struct {
			Call  string `json:"call"`
			Offer string `json:"offer"`
		}
		if err := json.NewDecoder(response.Body).Decode(&incoming); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if incoming.Offer != "the caller's sdp" {
			t.Fatalf("the appliance received %q", incoming.Offer)
		}

		body, _ := json.Marshal(map[string]string{"call": incoming.Call, "answer": "the mac's sdp"})
		request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/answer", bytes.NewReader(body))
		request.Header.Set("Authorization", authorised())
		if _, err := server.Client().Do(request); err != nil {
			t.Fatalf("answer: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the offer never reached the appliance")
	}

	select {
	case response := <-offered:
		if response == nil {
			t.Fatal("the caller's request failed")
		}
		defer response.Body.Close()
		var answer struct {
			SDP string `json:"sdp"`
		}
		if err := json.NewDecoder(response.Body).Decode(&answer); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if answer.SDP != "the mac's sdp" {
			t.Fatalf("the caller received %q", answer.SDP)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the answer never reached the caller")
	}
}

// A token nobody is listening on is not a page.
//
// Serving one anyway would let the host be swept for live calls by watching
// which paths render, and would hand the owner a link that loads, asks for a
// microphone and then fails.
func TestAnUnknownTokenIsNotAPage(t *testing.T) {
	server := httptest.NewServer(testRelay().routes())
	defer server.Close()

	response, err := server.Client().Get(server.URL + "/nobody-is-here")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("an unknown token rendered %s; it must not exist", response.Status)
	}
}

// The relay is on the public internet. Registration is the one thing that lets
// a stranger intercept an owner's call, by claiming their token first.
func TestAnUnauthenticatedApplianceCannotRegister(t *testing.T) {
	server := httptest.NewServer(testRelay().routes())
	defer server.Close()

	for _, credential := range []string{
		"",
		"Bearer nonsense",
		"Bearer 1.deadbeef",
		// A correct signature from an hour ago: expiry has to be enforced, or a
		// credential captured once works forever.
		"Bearer " + rendezvous.ApplianceCredential([]byte("shared"), time.Now().Add(-time.Hour)),
		// A well-formed credential under the wrong secret.
		"Bearer " + rendezvous.ApplianceCredential([]byte("not the secret"), time.Now()),
	} {
		request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/listen",
			strings.NewReader(`{"token":"tok"}`))
		if credential != "" {
			request.Header.Set("Authorization", credential)
		}
		response, err := server.Client().Do(request)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("credential %q was accepted with %s", credential, response.Status)
		}
	}
}

// A caller whose appliance is registered but not polling is told so, rather than
// watching a spinner until the answer window expires.
func TestACallToASleepingApplianceFailsFast(t *testing.T) {
	relay := testRelay()
	relay.appliances["tok"] = &appliance{offers: make(chan *call, 1), lastSeen: time.Now()}
	// Fill the slot, as an appliance already setting up a call would.
	relay.appliances["tok"].offers <- &call{id: "busy"}

	server := httptest.NewServer(relay.routes())
	defer server.Close()

	started := time.Now()
	response, err := server.Client().Post(server.URL+"/tok/offer", "application/json",
		strings.NewReader(`{"sdp":"x"}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("got %s, wanted a fast refusal", response.Status)
	}
	if elapsed := time.Since(started); elapsed > answerWindow/2 {
		t.Fatalf("took %s to refuse; the caller should not wait out the answer window", elapsed)
	}
}

// The page must carry TURN credentials that expire, and must name them in its
// connect-src.
//
// Chrome applies connect-src to ICE server URLs as well as to fetch, so a policy
// that omits the TURN URL removes the page's only route off the local network —
// silently, with no error the page can catch. That failure only appears when
// someone calls from outside the house, which is the hardest place to debug it.
func TestThePageCarriesFreshTurnCredentialsAndAllowsThem(t *testing.T) {
	relay := testRelay()
	relay.turnHost = "turn.example.com:3478"
	relay.turnSecret = []byte("turn secret")
	relay.appliances["tok"] = &appliance{offers: make(chan *call, 1), lastSeen: time.Now()}

	server := httptest.NewServer(relay.routes())
	defer server.Close()

	response, err := server.Client().Get(server.URL + "/tok")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer response.Body.Close()
	body := new(bytes.Buffer)
	_, _ = body.ReadFrom(response.Body)
	page := body.String()

	expectedUser, _ := rendezvous.TURNCredential(relay.turnSecret, time.Now().Add(turnCredentialTTL))
	if !strings.Contains(page, expectedUser) {
		t.Fatal("the page carries no TURN credential; calls from outside the house cannot be relayed")
	}
	if strings.Contains(page, "turn secret") {
		t.Fatal("the page contains the TURN shared secret itself")
	}

	policy := response.Header.Get("Content-Security-Policy")
	if !strings.Contains(policy, "turn:turn.example.com:3478") {
		t.Fatalf("connect-src omits the TURN server, so Chrome will block it: %q", policy)
	}
}

// One tester must not be able to take another's call.
//
// The relay routes by token, so before ownership was recorded any
// authenticated appliance could poll somebody else's token and join the same
// queue — whichever polled first took delivery. That is a wiretap wearing a
// race condition, and it is the reason a single shared secret cannot be
// distributed in a DMG.
func TestAnAppliuanceCannotClaimAnotherOwnersToken(t *testing.T) {
	relay := testRelay()
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	// The rightful owner registers.
	listen(t, server, "tok")

	// A different tester, with a valid credential of their own, tries the same
	// token.
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/listen",
		strings.NewReader(`{"token":"tok"}`))
	request.Header.Set("Authorization",
		"Bearer "+rendezvous.ApplianceCredential([]byte("another tester"), time.Now()))
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a second tester claimed a token they do not own (%s); "+
			"they would receive the owner's calls", response.Status)
	}
}

// Every issued secret has to work, or distributing one per tester is pointless.
func TestAnyIssuedSecretAuthenticates(t *testing.T) {
	relay := testRelay()
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	for i, secret := range [][]byte{[]byte("shared"), []byte("another tester")} {
		request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/listen",
			strings.NewReader(`{"token":"tok`+string(rune('a'+i))+`"}`))
		request.Header.Set("Authorization",
			"Bearer "+rendezvous.ApplianceCredential(secret, time.Now()))
		// Not waiting for the poll window; the registration is what is under test.
		go func() { _, _ = server.Client().Do(request) }()
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if relay.count() == 2 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("only %d of 2 secrets registered", relay.count())
}

// A new link revokes the previous one.
//
// The owner assumes the most recent link they were sent is the only one that
// works, and a call link is a live microphone. Before this, every //call left
// its predecessor serving a page for as long as anything kept polling it.
func TestIssuingALinkRevokesTheLast(t *testing.T) {
	relay := testRelay()
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	listen(t, server, "first")
	listen(t, server, "second")

	response, err := server.Client().Get(server.URL + "/first")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("the previous link still answers %s; it is still a live microphone",
			response.Status)
	}
}
