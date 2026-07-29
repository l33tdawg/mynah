package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/l33tdawg/sage-voice-bridge/webrtc/internal/rendezvous"
)

// mintingRelay is a relay that can hand out identities, which the hand-provisioned
// one in relay_test.go deliberately cannot.
func mintingRelay() *relay {
	r := testRelay()
	r.rootKey = []byte("a root key that never leaves this host")
	r.enrolments = newEnrolmentLimiter(8, time.Hour)
	return r
}

func enrol(t *testing.T, server *httptest.Server) (string, []byte) {
	t.Helper()
	response, err := http.Post(server.URL+"/appliance/enrol", "application/json", nil)
	if err != nil {
		t.Fatalf("enrol: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("enrol: status %d", response.StatusCode)
	}
	var minted struct {
		ID     string `json:"id"`
		Secret string `json:"secret"`
	}
	if err := json.NewDecoder(response.Body).Decode(&minted); err != nil {
		t.Fatalf("enrol: decode: %v", err)
	}
	// **Verbatim, exactly as the endpoint uses it.** This decoded the hex and
	// that is precisely why it passed while every real appliance got a 401: it
	// signed with the relay's decoded digest, where the endpoint signs with the
	// bytes it read out of the file. A test that reproduces the server's
	// arithmetic instead of the client's is not an end-to-end test.
	return minted.ID, []byte(minted.Secret)
}

// TestAMintedApplianceCanListen is the whole point: an owner who has never been
// added to this host's secret file gets a working credential on their own.
func TestAMintedApplianceCanListen(t *testing.T) {
	server := httptest.NewServer(mintingRelay().routes())
	defer server.Close()

	id, secret := enrol(t, server)
	if id == "" || len(secret) == 0 {
		t.Fatal("enrolment returned nothing usable")
	}

	request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/listen", nil)
	request.Header.Set("X-Sage-Appliance", id)
	request.Header.Set("Authorization", "Bearer "+rendezvous.ApplianceCredential(secret, time.Now()))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer response.Body.Close()

	// A missing token is a bad request; being told so means the credential was
	// accepted, which is what this is checking.
	if response.StatusCode == http.StatusUnauthorized {
		t.Fatal("a freshly minted appliance was refused by the relay that minted it")
	}
}

// The secret must be recomputable from the id alone, which is what lets the
// relay keep no record of anybody.
func TestTheRelayKeepsNoRecordAndDerivesTheSecretAgain(t *testing.T) {
	r := mintingRelay()
	server := httptest.NewServer(r.routes())
	defer server.Close()

	id, secret := enrol(t, server)

	derived := rendezvous.DeriveApplianceSecret(r.rootKey, id)
	if string(derived) != string(secret) {
		t.Fatal("the relay cannot re-derive a secret it just issued")
	}
	if len(r.secrets) != 2 {
		t.Fatalf("enrolment grew the stored secret list to %d; it must store nothing", len(r.secrets))
	}
}

// An id with a credential minted from a different root key is not somebody
// else's appliance — it is nobody's.
func TestACredentialFromAnotherRootKeyIsRefused(t *testing.T) {
	server := httptest.NewServer(mintingRelay().routes())
	defer server.Close()

	id, _ := enrol(t, server)
	forged := rendezvous.DeriveApplianceSecret([]byte("some other root key"), id)

	request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/listen", nil)
	request.Header.Set("X-Sage-Appliance", id)
	request.Header.Set("Authorization", "Bearer "+rendezvous.ApplianceCredential(forged, time.Now()))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a forged credential got %d, want 401", response.StatusCode)
	}
}

// Claiming an id you cannot authenticate as must fail rather than falling
// through to the hand-provisioned scan, where a tester's shared secret would let
// anybody wear any id.
func TestAnIdWithSomebodyElsesSecretDoesNotFallThroughToTheScan(t *testing.T) {
	server := httptest.NewServer(mintingRelay().routes())
	defer server.Close()

	id, _ := enrol(t, server)

	request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/listen", nil)
	request.Header.Set("X-Sage-Appliance", id)
	// A credential that IS valid — for a hand-provisioned secret in the file.
	request.Header.Set("Authorization", authorised())
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a valid secret was allowed to claim another appliance's id (%d)", response.StatusCode)
	}
}

// Every Mac provisioned by hand before minting existed must survive the deploy
// that adds it.
func TestAHandProvisionedApplianceStillWorksOnAMintingRelay(t *testing.T) {
	server := httptest.NewServer(mintingRelay().routes())
	defer server.Close()

	request, _ := http.NewRequest(http.MethodPost, server.URL+"/appliance/listen", nil)
	request.Header.Set("Authorization", authorised())
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusUnauthorized {
		t.Fatal("adding minting broke the appliances that were already provisioned")
	}
}

// A relay started without a root key says so rather than 500ing or, worse,
// minting from a zero key.
func TestARelayWithNoRootKeyRefusesToEnrol(t *testing.T) {
	server := httptest.NewServer(testRelay().routes())
	defer server.Close()

	response, err := http.Post(server.URL+"/appliance/enrol", "application/json", nil)
	if err != nil {
		t.Fatalf("enrol: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusNotImplemented {
		t.Fatalf("got %d, want 501 so the app can tell this from a refusal", response.StatusCode)
	}
}

// Anonymous enrolment is open enrolment, so the limit is the only thing between
// this and a script minting identities in a loop.
func TestEnrolmentIsRateLimitedPerAddress(t *testing.T) {
	r := mintingRelay()
	r.enrolments = newEnrolmentLimiter(2, time.Hour)
	server := httptest.NewServer(r.routes())
	defer server.Close()

	for attempt := 1; attempt <= 3; attempt++ {
		response, err := http.Post(server.URL+"/appliance/enrol", "application/json", nil)
		if err != nil {
			t.Fatalf("enrol %d: %v", attempt, err)
		}
		response.Body.Close()

		want := http.StatusOK
		if attempt == 3 {
			want = http.StatusTooManyRequests
		}
		if response.StatusCode != want {
			t.Fatalf("enrol %d: got %d, want %d", attempt, response.StatusCode, want)
		}
	}
}

// The limiter must forget addresses as they age out, or a relay somebody points
// a scanner at grows a map entry per source forever.
func TestTheLimiterForgetsAddressesAsTheyAgeOut(t *testing.T) {
	limiter := newEnrolmentLimiter(1, 20*time.Millisecond)

	if !limiter.allow("198.51.100.7") {
		t.Fatal("the first enrolment was refused")
	}
	if limiter.allow("198.51.100.7") {
		t.Fatal("the limit did not hold inside the window")
	}
	time.Sleep(40 * time.Millisecond)
	if !limiter.allow("198.51.100.7") {
		t.Fatal("the window never reopened")
	}
	if len(limiter.seen) != 1 {
		t.Fatalf("the limiter is holding %d addresses; stale ones are not being dropped", len(limiter.seen))
	}
}

// Two enrolments are two appliances. Colliding ids would put two owners on one
// credential, and the relay keys appliances by token — so the second holder
// could take delivery of the first one's call.
func TestEveryEnrolmentIsADifferentAppliance(t *testing.T) {
	server := httptest.NewServer(mintingRelay().routes())
	defer server.Close()

	first, firstSecret := enrol(t, server)
	second, secondSecret := enrol(t, server)

	if first == second {
		t.Fatal("two enrolments produced the same identity")
	}
	if string(firstSecret) == string(secondSecret) {
		t.Fatal("two appliances were given the same secret")
	}
}

// X-Forwarded-For is attacker-controlled where nothing strips it, so only the
// hop this relay's own front door appended may be trusted.
func TestOnlyTheLastForwardedHopIsTrusted(t *testing.T) {
	request, _ := http.NewRequest(http.MethodPost, "/appliance/enrol", nil)
	request.RemoteAddr = "10.0.0.1:5000"
	request.Header.Set("X-Forwarded-For", "203.0.113.9, 198.51.100.4")

	if got := clientAddress(request); got != "198.51.100.4" {
		t.Fatalf("trusted %q; a caller could spend somebody else's quota or dodge their own", got)
	}
}
