package main

import (
	"context"
	"testing"
	"time"
)

const (
	token = "0123456789abcdef0123456789abcdef"
	other = "fedcba9876543210fedcba9876543210"
)

// A `ps` line for each process a Mac could be running, so the matcher is judged
// against the shapes it will actually meet rather than against strings written to
// make it pass. The glasses endpoint and the call endpoint differ by one flag and
// must never be confused for each other: they serve different links, and the
// endpoint that kills the wrong one takes the owner's call down with it.
func TestOnlyTheSameLinkIsASibling(t *testing.T) {
	lines := []string{
		`/Applications/Mynah.app/Contents/MacOS/sage-voice-webrtc -relay https://call.sage.delivery -relay-secret-file /Users/me/.sage/call-relay.secret -token ` + token + ` -appliance /Users/me/Library/Application Support/SAGE Voice Bridge/call.sock -screen-only`,
		`/Applications/Mynah.app/Contents/MacOS/sage-voice-webrtc -relay https://call.sage.delivery -relay-secret-file /Users/me/.sage/call-relay.secret -token ` + token + ` -appliance /Users/me/Library/Application Support/SAGE Voice Bridge/call.sock`,
		`/Applications/Mynah.app/Contents/MacOS/sage-voice-webrtc -relay https://call.sage.delivery -relay-secret-file /Users/me/.sage/call-relay.secret -token ` + other + ` -appliance /Users/me/Library/Application Support/SAGE Voice Bridge/call.sock -screen-only`,
		`/Applications/Mynah.app/Contents/MacOS/sage-voiced daemon --allow +60123456789`,
		`/Users/me/nodejs-projects/sage-voice-bridge/.build/sage-voice-webrtc -relay https://call.sage.delivery -token ` + token + ` -screen-only -appliance /tmp/call.sock`,
		`-zsh`,
	}
	// Only line 0 is the glasses endpoint for this token.
	want := []bool{true, false, false, false, true, false}
	for index, line := range lines {
		_, command, ok := parseProcessLine("  4242 " + line)
		if !ok {
			t.Fatalf("line %d did not parse: %q", index, line)
		}
		if got := isSiblingEndpoint(command, token, true); got != want[index] {
			t.Errorf("line %d: sibling = %v, want %v\n%s", index, got, want[index], command)
		}
	}
}

// The kind matters in both directions: a glasses endpoint must not be reaped by
// a spoken call, and a spoken call must not be reaped by the glasses pairing.
func TestTheOtherKindIsNotASibling(t *testing.T) {
	glasses := `sage-voice-webrtc -relay https://x -token ` + token + ` -screen-only`
	call := `sage-voice-webrtc -relay https://x -token ` + token
	if isSiblingEndpoint(call, token, true) {
		t.Fatal("a spoken call was treated as the glasses pairing")
	}
	if isSiblingEndpoint(glasses, token, false) {
		t.Fatal("the glasses pairing was treated as a spoken call")
	}
	if !isSiblingEndpoint(call, token, false) || !isSiblingEndpoint(glasses, token, true) {
		t.Fatal("a process serving this exact link was not recognised")
	}
}

func TestParseProcessLineRejectsWhatCannotBeAPid(t *testing.T) {
	for _, line := range []string{"", "   ", "not-a-pid sage-voice-webrtc", "0 sage-voice-webrtc", "42"} {
		if _, _, ok := parseProcessLine(line); ok {
			t.Errorf("%q was read as a process", line)
		}
	}
}

// The daemon that started this endpoint is gone, so the endpoint goes too.
//
// This is the half that stops leftovers being *created*: without it, a crash or
// a force quit leaves a process polling the owner's link with an old build's
// command set, and the next question is answered by it.
func TestAParentThatGoesAwayStopsTheEndpoint(t *testing.T) {
	parent := 400
	stopped := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go watchParent(ctx, func() int { return parent }, func() { close(stopped) }, time.Millisecond)
	select {
	case <-stopped:
		t.Fatal("stopped while its parent was still there")
	case <-time.After(20 * time.Millisecond):
	}
	parent = 1 // reparented to launchd
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("an orphaned endpoint kept polling the relay")
	}
}

// A daemon that is still there keeps its endpoint, and a cancelled context ends
// the watch without stopping anything.
func TestALivingParentKeepsTheEndpoint(t *testing.T) {
	stopped := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	go watchParent(ctx, func() int { return 400 }, func() { close(stopped) }, time.Millisecond)
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case <-stopped:
		t.Fatal("a living parent's endpoint was stopped")
	case <-time.After(20 * time.Millisecond):
	}
}
