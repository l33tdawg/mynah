package main

import (
	"context"
	"errors"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// One link, one endpoint process.
//
// The token in a pairing is written down, so the endpoint that serves it is
// started again with the *same* token every time — after a restart, after an
// update, after `//g2` is sent twice. Nothing about the relay's registration is
// exclusive, so if an endpoint process survives its daemon, both the leftover
// and the live one hold a poll for that token and the relay hands each offer to
// whichever happens to be waiting. They race, and the owner cannot see a race —
// they see one question work and the next one fail.
//
// **What a leftover endpoint is not is harmless.** An endpoint older than the
// queued-request command cannot read what the companion sends, so it answers
// `unknown control`, and the companion's own mapping turns that into "Your Mac's
// Mynah refused this recording. Update Mynah on the Mac, restart it…" — on a link
// that is perfectly healthy, from a Mac that was updated and restarted, because
// the process answering is not the process that was updated. `screenCapture`
// keeps its own state per *connection*, so an old endpoint that happens to take
// the second connection is exactly "the first one worked, the second was
// refused".
//
// Two rules, and they are the two halves of one thing:
//
//   - `reapSiblingEndpoints` runs before this endpoint starts polling, and stops
//     any other process serving this token. That cures a leftover which already
//     exists — including one from a build too old to know any of this.
//   - `-exit-with-parent` makes a new endpoint stop when the daemon that started
//     it goes away, so leftovers stop being created by a crash, a force quit or
//     an update landing on a running daemon.
//
// Neither rule touches an endpoint for a *different* token, which is what the
// call flow does: `//call` mints a new token each time and the relay revokes the
// previous one, so those endpoints are not siblings in any sense that matters.

// isSiblingEndpoint decides whether one `ps` line describes another process
// serving this exact link.
//
// Token **and** kind, because the two endpoints a Mac runs are different things:
// the persistent glasses pairing is `-screen-only`, and a spoken call is not. A
// process serving the same token with the other kind would be a bug of a
// different shape, and killing it on sight would hide that.
func isSiblingEndpoint(command, token string, screenOnly bool) bool {
	if !strings.Contains(command, "sage-voice-webrtc") {
		return false
	}
	if !strings.Contains(command, " -token "+token) {
		return false
	}
	return strings.Contains(command, " -screen-only") == screenOnly
}

// parseProcessLine reads `ps -axo pid=,command=`: a pid, then the command.
func parseProcessLine(line string) (int, string, bool) {
	fields := strings.Fields(strings.TrimSpace(line))
	if len(fields) < 2 {
		return 0, "", false
	}
	pid, err := strconv.Atoi(fields[0])
	if err != nil || pid <= 0 {
		return 0, "", false
	}
	return pid, strings.TrimSpace(line)[len(fields[0]):], true
}

// reapSiblingEndpoints stops every other process serving this token.
//
// Returns how many it stopped, for the log line and for the test.
func reapSiblingEndpoints(token string, screenOnly bool) int {
	output, err := exec.Command("/bin/ps", "-axo", "pid=,command=").Output()
	if err != nil {
		// Said plainly rather than silently skipped: this is the step that stops
		// an old endpoint answering the owner's glasses, and a Mac where it
		// cannot run is a Mac where that can still happen.
		log.Printf("could not look for other endpoints serving this link: %v", err)
		return 0
	}
	self := os.Getpid()
	stopped := 0
	for _, line := range strings.Split(string(output), "\n") {
		pid, command, ok := parseProcessLine(line)
		if !ok || pid == self || !isSiblingEndpoint(command, token, screenOnly) {
			continue
		}
		log.Printf("endpoint %d is already serving this link; stopping it before this one starts", pid)
		stopProcess(pid)
		stopped++
	}
	return stopped
}

// stopProcess asks first, then insists.
//
// SIGTERM, because these endpoints are expected to leave when asked — and
// SIGKILL three seconds later, because the reason a leftover is still here is
// usually that its shutdown did not finish, and a second process that cannot be
// told to leave is one that will answer the owner's next question with the wrong
// build's words.
func stopProcess(pid int) {
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return
	}
	for attempt := 0; attempt < 30; attempt++ {
		if !processIsRunning(pid) {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	log.Printf("endpoint %d did not stop when asked; killing it", pid)
	_ = syscall.Kill(pid, syscall.SIGKILL)
}

func processIsRunning(pid int) bool {
	err := syscall.Kill(pid, 0)
	// A signal of 0 tests for existence. `EPERM` means it exists and belongs to
	// somebody else, which for our own endpoint means it exists.
	return err == nil || errors.Is(err, syscall.EPERM)
}

// watchParent stops this endpoint when the daemon that started it goes away.
//
// Taken as a function rather than read once, so the loop can be tested without
// a test having to lose its own parent. macOS reparents an orphan to launchd, so
// the parent id changing at all is the signal — the value it changes to is not
// part of the contract.
func watchParent(ctx context.Context, parent func() int, stop func(), every time.Duration) {
	original := parent()
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(every):
		}
		if parent() == original {
			continue
		}
		log.Printf("the Mynah that started this endpoint is gone (parent %d); stopping", original)
		stop()
		return
	}
}
