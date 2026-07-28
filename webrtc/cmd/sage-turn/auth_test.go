package main

import (
	"strconv"
	"testing"
	"time"
)

// Time-limited credentials, because the page is served to a phone: any password
// baked into it is a password kept by anyone who opens the page.
func TestACredentialStopsWorkingWhenItExpires(t *testing.T) {
	secret := []byte("shared-secret")

	valid := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	if _, ok := authenticate(valid, "mynah", secret); !ok {
		t.Error("a credential that has not expired was refused")
	}

	expired := strconv.FormatInt(time.Now().Add(-time.Minute).Unix(), 10)
	if _, ok := authenticate(expired, "mynah", secret); ok {
		t.Error("an expired credential still relays media")
	}
}

func TestAMalformedUsernameIsRefused(t *testing.T) {
	secret := []byte("shared-secret")
	for _, username := range []string{"", "not-a-timestamp", ":", "abc:def"} {
		if _, ok := authenticate(username, "mynah", secret); ok {
			t.Errorf("%q was accepted as a credential", username)
		}
	}
}

// A label after the colon is allowed so a relay operator can tell calls apart,
// but it must not be able to smuggle a different expiry past the check.
func TestALabelDoesNotChangeTheExpiry(t *testing.T) {
	secret := []byte("shared-secret")
	expired := strconv.FormatInt(time.Now().Add(-time.Hour).Unix(), 10)
	if _, ok := authenticate(expired+":mynah-call", "mynah", secret); ok {
		t.Error("a label let an expired credential through")
	}
	valid := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	if _, ok := authenticate(valid+":mynah-call", "mynah", secret); !ok {
		t.Error("a labelled credential was refused")
	}
}

// The derivation has to be stable and secret-dependent, or the relay and the
// page cannot agree and every call fails authentication.
func TestTheCredentialIsDerivedFromTheSecret(t *testing.T) {
	username := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	first := credentialFor(username, []byte("secret-one"))
	again := credentialFor(username, []byte("secret-one"))
	other := credentialFor(username, []byte("secret-two"))

	if first != again {
		t.Error("the same inputs produced different passwords")
	}
	if first == other {
		t.Error("the secret does not affect the password, so anyone can mint one")
	}
	if first == "" {
		t.Error("empty password")
	}
}
