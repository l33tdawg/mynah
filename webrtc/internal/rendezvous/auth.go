// Package rendezvous holds what the appliance and the relay must agree on.
//
// Both ends of a remote call are separate programs on separate machines that
// have to derive identical credentials from a shared secret. Any drift between
// two copies of that arithmetic is an authentication failure that looks like a
// network problem, so there is one copy and both import it.
package rendezvous

import (
	"crypto/hmac"
	"crypto/sha1" //nolint:gosec // Mandated by RFC 5389/8489 for TURN MESSAGE-INTEGRITY.
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

// ApplianceCredential proves an appliance holds the shared secret.
//
// A signed timestamp rather than a bearer token: the relay is on the public
// internet and anything replayable that it accepts, it accepts forever. This
// expires on its own, so a credential captured in a log is worthless by the time
// anyone reads the log.
//
// It authenticates the appliance to the relay and nothing else — it confers no
// ability to read a call, which is protected by DTLS-SRTP between the endpoints
// and never available to the relay at all.
func ApplianceCredential(secret []byte, now time.Time) string {
	stamp := strconv.FormatInt(now.Unix(), 10)
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(stamp))
	return stamp + "." + hex.EncodeToString(mac.Sum(nil))
}

// Identify checks a credential against every issued secret and reports which
// one it was.
//
// Several secrets rather than one, because a single shared secret cannot be
// distributed. Every copy of the app would hold the same credential, and the
// relay keys appliances by token — so a second holder polling the same token
// joins the same queue and can take delivery of somebody else's call. One
// secret per appliance makes that impossible and makes revoking a single tester
// possible without touching anyone else.
//
// Returns an opaque, stable identifier rather than the secret or its index: it
// goes in logs and is compared against a registered token's owner, and neither
// use should be able to leak the credential.
func Identify(secrets [][]byte, credential string, now time.Time, tolerance time.Duration) (string, bool) {
	for _, secret := range secrets {
		if VerifyAppliance(secret, credential, now, tolerance) {
			sum := sha256.Sum256(secret)
			return hex.EncodeToString(sum[:6]), true
		}
	}
	return "", false
}

// VerifyAppliance checks a credential against the secret and the clock.
//
// Tolerance runs both directions because the appliance's clock is not the
// relay's, and a Mac that woke from sleep can be seconds out. Compared in
// constant time: an early return on a mismatched prefix tells an attacker how
// much of their guess was right.
func VerifyAppliance(secret []byte, credential string, now time.Time, tolerance time.Duration) bool {
	stamp, signature, found := strings.Cut(credential, ".")
	if !found {
		return false
	}
	seconds, err := strconv.ParseInt(stamp, 10, 64)
	if err != nil {
		return false
	}
	drift := now.Sub(time.Unix(seconds, 0))
	if drift < 0 {
		drift = -drift
	}
	if drift > tolerance {
		return false
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(stamp))
	expected := hex.EncodeToString(mac.Sum(nil))
	return subtle.ConstantTimeCompare([]byte(signature), []byte(expected)) == 1
}

// TURNCredential mints a time-limited username and password for a relay.
//
// The standard REST scheme from the TURN drafts: the username is the expiry and
// the password is its HMAC-SHA1 under a secret only the two servers know. It
// exists because the page is served to a phone, and any password baked into a
// page is a password everyone who opens it keeps.
//
// SHA-1 is not a choice — RFC 5389 fixes it for TURN's MESSAGE-INTEGRITY, and
// the property being relied on is HMAC's, which does not rest on SHA-1's
// collision resistance.
func TURNCredential(secret []byte, expiry time.Time) (username, password string) {
	username = strconv.FormatInt(expiry.Unix(), 10)
	mac := hmac.New(sha1.New, secret)
	mac.Write([]byte(username))
	return username, base64.StdEncoding.EncodeToString(mac.Sum(nil))
}
