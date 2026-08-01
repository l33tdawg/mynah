package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/l33tdawg/mynah/webrtc/internal/rendezvous"
)

// serveViaRelay answers calls that arrive through the relay.
//
// The appliance never accepts a connection. It holds a request open at the
// relay and waits; when someone opens the call link, the offer comes back as
// that request's response. No port forwarded, no certificate, no address that
// has to stay reachable — and, decisively, no self-signed certificate on the
// origin the browser is judging, which is what broke direct calls: a browser
// will not persist a media permission for an untrusted origin, and without a
// persisted permission Chrome hides the phone's real ICE candidates behind
// random .local names. The two ends sit on the same Wi-Fi unable to name each
// other.
//
// The media path is unaffected by any of this. The relay carries the offer and
// the answer; the candidates inside them describe routes between the phone and
// this Mac, and on a shared network ICE picks the host pair.
func serveViaRelay(ctx context.Context, endpoint, token, applianceID string, secret []byte, calls *callServer) error {
	client := &http.Client{
		// Comfortably longer than the relay holds a poll. A timeout shorter than
		// the poll window would sever every idle wait and read as an outage.
		Timeout: 2 * time.Minute,
	}

	log.Printf("waiting for a call at %s/%s", endpoint, token)

	// A link that is never used must not stay usable.
	//
	// The endpoint kept polling after a call ended, so a link sent over Signal
	// remained a live microphone indefinitely — an old message in the thread was
	// still an open door. Exiting takes the token with it: the relay serves 404
	// for a token nobody is listening on.
	//
	// Generous enough to survive a dropped call and a reconnect, short enough
	// that a forgotten link is not a standing invitation.
	idle := time.Now()
	var backoff time.Duration
	for {
		if err := ctx.Err(); err != nil {
			return nil
		}
		if backoff > 0 {
			select {
			case <-time.After(backoff):
			case <-ctx.Done():
				return nil
			}
		}

		if time.Since(idle) > idleLifetime {
			log.Printf("no call in %s; this link is now closed", idleLifetime)
			return nil
		}

		incoming, err := poll(ctx, client, endpoint, token, applianceID, secret)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return nil
			}
			// Retried rather than fatal. The relay restarting, or a phone
			// switching networks mid-call, must not leave the appliance
			// permanently unreachable — the owner would have no way to tell
			// besides a link that stops working.
			backoff = nextBackoff(backoff)
			log.Printf("relay unreachable (%v); retrying in %s", err, backoff)
			continue
		}
		backoff = 0
		if incoming == nil {
			continue // Nobody called. Poll again.
		}

		idle = time.Now()
		log.Println("a call is coming in")
		answer, err := calls.answerOffer(incoming.Offer, incoming.iceServers())
		if err != nil {
			log.Printf("could not answer: %v", err)
			continue
		}
		if err := sendAnswer(ctx, client, endpoint, applianceID, secret, incoming.Call, answer); err != nil {
			log.Printf("could not deliver the answer: %v", err)
		}
	}
}

// How long a link survives with nobody using it.
const idleLifetime = 15 * time.Minute

// nextBackoff grows the wait between failed polls, to a ceiling.
//
// Capped low on purpose: this is the owner's own appliance waiting for the
// owner's own call, so the worst case that matters is how long after the relay
// recovers before a call can get through. Half a minute is the most that should
// ever be.
func nextBackoff(current time.Duration) time.Duration {
	switch {
	case current == 0:
		return time.Second
	case current >= 30*time.Second:
		return 30 * time.Second
	default:
		return current * 2
	}
}

type incomingCall struct {
	Call  string             `json:"call"`
	Offer string             `json:"offer"`
	ICE   []webrtc.ICEServer `json:"ice"`
}

// iceServers is what this Mac should try when connecting back to the caller.
//
// Taken from the relay rather than configured here, so the TURN credentials both
// ends use are minted in one place and expire together. An appliance holding a
// stale credential fails in the least visible way there is: calls that work at
// home and not anywhere else.
func (c *incomingCall) iceServers() []webrtc.ICEServer {
	return c.ICE
}

func poll(ctx context.Context, client *http.Client, endpoint, token, applianceID string, secret []byte) (*incomingCall, error) {
	body, err := json.Marshal(map[string]string{"token": token})
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/appliance/listen", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+rendezvous.ApplianceCredential(secret, time.Now()))
	// Present when this appliance minted its own identity, absent when it
	// carries a secret added to the relay's file by hand. The relay reads it as
	// "derive exactly this one secret" instead of scanning every secret it holds.
	if applianceID != "" {
		request.Header.Set("X-Sage-Appliance", applianceID)
	}

	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	switch response.StatusCode {
	case http.StatusNoContent:
		return nil, nil // Nobody called within the window.
	case http.StatusOK:
		var incoming incomingCall
		if err := json.NewDecoder(io.LimitReader(response.Body, 256<<10)).Decode(&incoming); err != nil {
			return nil, err
		}
		return &incoming, nil
	case http.StatusUnauthorized:
		// Worth its own message. This is a shared secret that does not match, or
		// a clock that has drifted past tolerance — neither of which looks like
		// anything from the owner's side except a link that never rings.
		return nil, errors.New("the relay rejected this appliance's credentials: " +
			"check the shared secret and this Mac's clock")
	default:
		return nil, fmt.Errorf("the relay answered %s", response.Status)
	}
}

func sendAnswer(ctx context.Context, client *http.Client, endpoint, applianceID string, secret []byte, callID, answer string) error {
	body, err := json.Marshal(map[string]string{"call": callID, "answer": answer})
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/appliance/answer", bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+rendezvous.ApplianceCredential(secret, time.Now()))
	// Present when this appliance minted its own identity, absent when it
	// carries a secret added to the relay's file by hand. The relay reads it as
	// "derive exactly this one secret" instead of scanning every secret it holds.
	if applianceID != "" {
		request.Header.Set("X-Sage-Appliance", applianceID)
	}

	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4<<10))
	if response.StatusCode >= 300 {
		return fmt.Errorf("the relay answered %s", response.Status)
	}
	return nil
}
