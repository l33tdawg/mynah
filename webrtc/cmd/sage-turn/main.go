// Command sage-turn relays call media for peers that cannot reach each other.
//
// STUN is enough for most home routers: it tells each side what its public
// address looks like from outside, and the two connect directly. It is not
// enough for symmetric NAT, which allocates a different external port per
// destination — so the address one side learns is useless to the other. That is
// common on cellular networks, which is precisely where the owner is when they
// want to call their Mac.
//
// A TURN server fixes it the blunt way: both sides connect out to it, and it
// forwards. Media stays end-to-end encrypted under DTLS-SRTP, so the relay
// cannot listen — but it does see that a call happened, when, how long, and
// between which addresses. On a product whose argument is that the owner's words
// stay on their machine, that metadata belongs to the owner too, which is why
// this is a binary they run rather than a service they trust.
//
// # Credentials
//
// Ephemeral, not static. The page is served to a phone, so any password baked
// into it is a password anyone who opens the page keeps. This implements the
// usual time-limited scheme: the username is an expiry timestamp and the
// password is its HMAC under a shared secret. The Mac and the relay both know
// the secret; the phone gets a credential that stops working in an hour.
//
//	sage-turn -public-ip 65.108.81.134 -secret "$(openssl rand -hex 32)"
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/pion/turn/v4"

	"github.com/l33tdawg/mynah/webrtc/internal/rendezvous"
)

func main() {
	var (
		publicIP   = flag.String("public-ip", "", "the address peers reach this host on (required)")
		port       = flag.Int("port", 3478, "listen port for UDP and TCP")
		realm      = flag.String("realm", "mynah", "TURN realm; must match the client")
		secret     = flag.String("secret", "", "shared secret for time-limited credentials")
		secretFile = flag.String("secret-file", "", "file holding the shared secret (preferred over -secret)")
		minPort    = flag.Int("min-port", 49160, "lowest relay port")
		maxPort    = flag.Int("max-port", 49200, "highest relay port")
	)
	flag.Parse()

	// A secret in a flag is a secret in the process table, readable by every
	// user on the host and preserved in whatever supervises this. A file at
	// least has permissions.
	if *secretFile != "" {
		raw, err := os.ReadFile(*secretFile)
		if err != nil {
			log.Fatalf("secret file: %v", err)
		}
		*secret = strings.TrimSpace(string(raw))
		if *secret == "" {
			log.Fatalf("secret file: %s is empty", *secretFile)
		}
	}

	if *publicIP == "" || *secret == "" {
		fmt.Fprintln(os.Stderr, `error: -public-ip and -secret are required.

  sage-turn -public-ip 203.0.113.10 -secret-file /etc/sage/turn.secret

The public IP is what candidates are advertised as. Get it wrong — a private
address, or the wrong interface — and every relayed call fails while the server
reports itself healthy.`)
		os.Exit(2)
	}
	if net.ParseIP(*publicIP) == nil {
		fmt.Fprintf(os.Stderr, "error: -public-ip %q is not an IP address\n", *publicIP)
		os.Exit(2)
	}

	udpListener, err := net.ListenPacket("udp4", "0.0.0.0:"+strconv.Itoa(*port))
	if err != nil {
		log.Fatalf("listen udp/%d: %v", *port, err)
	}
	// TCP as well as UDP. Restrictive networks — hotel Wi-Fi, corporate guest
	// networks — block UDP outright, and a relay that only speaks UDP is no
	// relay at all on exactly the connections that need one most.
	tcpListener, err := net.Listen("tcp4", "0.0.0.0:"+strconv.Itoa(*port))
	if err != nil {
		log.Fatalf("listen tcp/%d: %v", *port, err)
	}

	sharedSecret := []byte(*secret)
	server, err := turn.NewServer(turn.ServerConfig{
		Realm: *realm,
		// Credentials are derived, never stored. Nothing here has a list of
		// users to leak.
		AuthHandler: func(username, realm string, _ net.Addr) ([]byte, bool) {
			return authenticate(username, realm, sharedSecret)
		},
		PacketConnConfigs: []turn.PacketConnConfig{{
			PacketConn: udpListener,
			RelayAddressGenerator: &turn.RelayAddressGeneratorPortRange{
				RelayAddress: net.ParseIP(*publicIP),
				Address:      "0.0.0.0",
				MinPort:      uint16(*minPort),
				MaxPort:      uint16(*maxPort),
			},
		}},
		ListenerConfigs: []turn.ListenerConfig{{
			Listener: tcpListener,
			RelayAddressGenerator: &turn.RelayAddressGeneratorPortRange{
				RelayAddress: net.ParseIP(*publicIP),
				Address:      "0.0.0.0",
				MinPort:      uint16(*minPort),
				MaxPort:      uint16(*maxPort),
			},
		}},
	})
	if err != nil {
		log.Fatalf("turn server: %v", err)
	}

	log.Printf("relaying on %s:%d (udp+tcp), media ports %d-%d, realm %q",
		*publicIP, *port, *minPort, *maxPort, *realm)
	log.Printf("clients use:  turn:%s:%d", *publicIP, *port)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	log.Println("shutting down")
	if err := server.Close(); err != nil {
		log.Printf("close: %v", err)
	}
}

// authenticate checks a time-limited credential.
//
// The username is `<unix-expiry>` or `<unix-expiry>:<label>`, and the password
// is HMAC-SHA1 of the username under the shared secret, base64 encoded. Pion
// wants the long-term key rather than the password, so this returns that.
//
// Expiry is checked before the HMAC and both are checked in constant time: a
// handler that returns early on a bad signature leaks how much of it was right.
func authenticate(username, realm string, secret []byte) ([]byte, bool) {
	expiry := username
	if colon := strings.IndexByte(username, ':'); colon >= 0 {
		expiry = username[:colon]
	}
	seconds, err := strconv.ParseInt(expiry, 10, 64)
	if err != nil {
		return nil, false
	}
	if time.Now().Unix() > seconds {
		return nil, false
	}

	password := credentialFor(username, secret)
	return turn.GenerateAuthKey(username, realm, password), true
}

// credentialFor derives the password a client must present.
//
// One line, because the arithmetic itself lives in the package the relay mints
// credentials with. Two copies of it would be two things to keep identical, and
// any difference between them is an authentication failure that presents as a
// network fault.
func credentialFor(username string, secret []byte) string {
	_, password := rendezvous.TURNCredential(secret, timeFromUsername(username))
	return password
}

// timeFromUsername recovers the expiry a username encodes.
//
// The username *is* the expiry, so this round-trips rather than reformats: it
// keeps TURNCredential the single definition of the scheme instead of having
// this file re-derive half of it.
func timeFromUsername(username string) time.Time {
	seconds, err := strconv.ParseInt(username, 10, 64)
	if err != nil {
		return time.Time{}
	}
	return time.Unix(seconds, 0)
}
