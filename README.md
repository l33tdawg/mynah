# Mynah

A private voice appliance. It runs on a Mac you already own — a Mac mini left
switched on, typically — and you reach it from your phone two ways: by messaging
yourself on Signal, and by calling it.

It is an agent, not a dictation tool. It has persistent memory, it can search the
web, write notes and keep a backlog, and it runs the model either on the same Mac
or through an API key you supply. Nothing about it is a service. There is no
account, no server of ours, and nothing to sign into.

## The two ways in

**Signal Note-to-Self.** You message yourself; Mynah answers in the same thread.
Text, voice notes and photos all work. The thread is end-to-end encrypted between
your own devices, and Mynah is a linked device on your own Signal account — the
same mechanism Signal Desktop uses. Nothing is exposed to the internet.

**Calls.** You send `//call`, get a link back, tap it, and talk. It is a real
conversation: full duplex, you can cut it off mid-sentence and it stops. The link
opens a web page, so there is nothing to install on the phone.

## What it runs on

- macOS 14 or later, Apple Silicon.
- Signal, on a phone. Mynah links as a secondary device; your number and your
  primary phone are unchanged.
- A model. Either local, via Ollama on the same Mac, or an API key you provide.
- [SAGE](https://github.com/l33tdawg/sage), which is where its memory lives. The
  app bundles a copy.

Calls additionally need a small relay on a host you rent. See below for why, and
for what it does and does not see.

## How the pieces fit

    Mynah.app          setup, status, pause, memories. Installs and supervises
                       the two background services below.

    signal-cli         a linked Signal device, run as a LaunchAgent. Speaks
                       JSON-RPC to sage-voiced over a unix socket.

    sage-voiced        the appliance itself. Signal in, recognition, the agent
                       loop, speech, Signal out.

    SAGE.app           memory, tasks, backlog. Driven over MCP as a child
                       process. Vendored into the bundle.

    sage-voice-webrtc  the call endpoint. Started on demand by //call, dials out
                       to the relay, owns the audio.

    sage-call-relay    serves the call page and introduces the two ends. Runs on
                       a host you rent. Not in the call.

    sage-turn          relays call media when no direct path exists. Optional,
                       and effectively required on cellular.

The Swift half is one library, `SageVoiceCore`, with two front ends: the app and
`sage-voiced`. Neither is a reimplementation of the other. The Go half is
separate because there is no WebRTC in Foundation and vendoring libwebrtc is a
build system unto itself; Pion is pure Go and already in this project's
dependency graph through SAGE.

## A turn, in detail

1. signal-cli receives the message and hands it over the socket. The sender is
   checked before anything else looks at it. The allowlist cannot be constructed
   empty, and a sync envelope with no account is denied rather than falling back
   to a weaker check. It fails closed.
2. Voice notes are transcribed on this Mac.
3. Messages arriving within 2.5 seconds of each other are merged, up to five, so
   a thought sent as three messages is answered once. Order is preserved: a later
   message qualifies an earlier one.
4. An opening line goes back immediately — "Let me have a look" — derived from
   your own words rather than from the model, because the model has not been
   called yet. Short messages and small talk get no opener. A reply that arrives
   in two seconds does not need one.
5. The agent loop runs: at most 10 iterations, a 300-second wall clock, three
   tool calls honoured per iteration, tool output truncated at 6,000 characters.
   The deadline is checked between iterations and predicts from the turn's own
   worst model call, so the turn stops in time to say something rather than being
   cut off mid-thought.
6. If the turn is slow, a progress line goes out at most every 45 seconds and at
   most three times. Each one has to have something new to say; a tick with no
   news does not spend one of the three.
7. The answer is sent, with any notes written during the turn attached to the
   same message.
8. The turn is recorded in SAGE, and every tenth turn it reflects on what worked
   and what did not.

Every reply carries a short bracketed label, because Signal draws Note-to-Self as
one column of your own outgoing bubbles — there is no incoming side to render on
the left, so no styling or alignment trick can separate the two speakers. The
real fix is giving the appliance its own number.

History is 16 turns or six hours, persisted after every turn. Tool calls and
their results are stripped from it, deliberately: retaining them made later turns
call no tools and recycle a stale answer. URLs survive, so "send me those links
again" works.

## Calls

`//call` is a slash command and not something the model classifies. "Call me" is
a thing you might say about someone else, and the cost of getting it wrong is a
microphone opening on your phone. It is anchored, so a message that merely
mentions `//call` is a question.

It refuses when the model is local. A 4B model on this hardware takes the best
part of a minute to produce a first token. In a message that is a wait; in a call
it is a dead line. The refusal names the model and says what to do about it.

What happens when you send it:

1. The Mac starts the call endpoint, which dials the relay and registers an
   unguessable 128-bit token. Issuing a link revokes the previous one — a call
   link is a live microphone, and you assume the last link you were sent is the
   only one that works.
2. The link is not sent to you until the relay actually serves it. A link that
   arrives half a second early is a 404 in your hand, which reads as a broken
   appliance rather than as being early.
3. While you are reading the message and tapping, the appliance builds its
   opening line through the same brain and tools as any other turn, so it can say
   what is actually open rather than something generic. `//call` is several
   seconds of warning, and it spends them.
4. The page asks for the microphone with echo cancellation, noise suppression and
   automatic gain. Those three constraints are most of the argument for using a
   browser at all: without echo cancellation the appliance hears its own voice
   through your phone's speaker and interrupts itself.
5. One offer, one answer, no trickle ICE. The answer is withheld until candidate
   gathering finishes, so every candidate travels inside the SDP. That costs a
   second of setup and removes a whole class of handshake failure.
6. ICE picks a route. On a home network that is phone-to-Mac across the room.

From there the endpoint owns everything with a deadline measured in milliseconds
and the appliance owns everything measured in seconds. A pause on the endpoint
side is a pause you hear; a pause on the appliance side is a delay in answering.

- **Hearing you.** Opus decoded at 48 kHz, then energy-based segmentation.
  Speech is 2.5x above a tracked noise floor; 40 ms opens an utterance, 700 ms of
  silence closes it, and 300 ms of audio from before detection is kept so the
  first consonant is not shaved off. Anything under 400 ms is a door or a breath,
  and is dropped. The floor is tracked rather than assumed because the phone's
  own gain control means the residual level differs per room and drifts within a
  single call.
- **Interrupting.** Cutting the appliance off costs more than starting to speak:
  three times the threshold, sustained for 240 ms. Browser echo cancellation is
  good and not perfect, and on speakerphone enough of the appliance's own voice
  returns to clear the ordinary bar — every reply was followed by an interruption
  the caller never made. When you do interrupt, queued audio is dropped within
  one frame and the appliance is told, so the model and the synthesiser stop too.
  Otherwise the rest of the abandoned answer arrives seconds later and is spoken
  over your new question.
- **Answering.** Each sentence is synthesised and spoken as it is ready rather
  than the whole answer at once, so it starts talking about as fast as a person
  would. Audio is paced out in 20 ms frames in real time; handing WebRTC the
  whole answer at once gets it delivered in a burst the phone plays as a
  chipmunk.

A call survives its brain restarting. If the daemon goes away mid-call the
endpoint redials for a few seconds rather than dropping a call that is otherwise
perfectly healthy.

### Why the page comes from a relay

The Mac served its own page first, and that is exactly what failed. A Mac on a
home network has no name a certificate authority will sign, so serving the page
from it means a self-signed certificate. Browsers do not merely warn about those.
They refuse to persist a media permission for the origin, and without a persisted
permission Chrome replaces the phone's real ICE candidates with random `.local`
names. Two machines on the same Wi-Fi, unable to name each other: a page that
says *Connected* and carries no audio. The certificate warning was never the
cost. The broken call was.

So the page comes from a host with a real certificate, and the Mac dials out and
waits. No port forwarded, no certificate to install, no address that has to stay
reachable.

One relay hostname serves every appliance and nothing is provisioned per owner.
Each appliance authenticates with its own secret, as a signed timestamp rather
than a replayable token. One shared secret across every copy would mean a second
holder could poll somebody else's token and take delivery of their call.

## What it can do

The model sees eighteen tools, and the number is deliberate. SAGE publishes 27;
measured over a fixed set of twelve utterances, the full catalogue routed
correctly 5–6 times out of 12 and a curated subset scored 12/12. So the loop
filters to a named allowlist and fails closed when nothing matches, rather than
widening to everything. That measurement is at short context; accuracy after
sixteen turns of history has not been measured.

- **Memory** — `sage_recall`, `sage_remember`, `sage_forget`, `sage_list`,
  `sage_timeline`, `sage_status`.
- **Work** — `sage_task`, `sage_backlog`, `sage_inbox`, `sage_reflect`.
- **Other agents** — `sage_find_agent`, `sage_pipe`, `sage_pipe_result`,
  `sage_federation`.
- **Notes** — `write_note`, `read_note`, `list_notes`. Stored on the Mac under
  `~/Library/Application Support/SAGE Voice Bridge/Notes`, owner-only. The model
  supplies a title and never a path, so traversal is unrepresentable rather than
  blocked — the same context holds transcription errors and text written by
  strangers on the internet.
- **The web** — `web_search`. Brave when `BRAVE_SEARCH_API_KEY` is set,
  DuckDuckGo otherwise, so it works with no key at all. Results are labelled to
  the model as third-party text to summarise and never as instructions. That
  raises the bar; it does not close the hole. What actually contains it is that a
  hijacked turn is visible to you, reading the reply.

The memory discipline itself — inception at boot, recording each turn, periodic
reflection — is performed by the daemon and not offered to the model. Those tools
are not in the allowlist. A model that forgets to record a turn produces a
failure that surfaces days later as "web search broke".

## Which model answers

Chosen at install time, not compile time. The setup screen probes what this Mac
can offer, ranks the options, and says per option where your words go.

- **Local** — Ollama, `qwen3.5:4b` by default. The app can install the runtime
  and pull the model. Needs Apple Silicon and at least 8 GB of memory; 16 GB or
  more is comfortable. This is what the setup screen recommends, because privacy
  is the product default. It is also the one option that cannot hold a call.
- **API** — Anthropic, OpenAI, Google Gemini, DeepSeek, Moonshot/Kimi, Groq, LM
  Studio, or any OpenAI-compatible endpoint. Keys are read from the environment
  or typed once and stored on disk at `0600`, deliberately not in the Keychain: a
  Keychain item prompts on first access after a restart, and this appliance
  restarts unattended on a machine nobody is sitting at. That would turn a reboot
  into a silent outage.

An API key already present in the environment ranks *below* a subscription you
are already paying for. Recommending a metered path over a flat-rate one is a
quiet way to spend your money.

The ranking is guidance and never a selection. A recommendation cannot be turned
into a choice; only you can make one, and only from options that are actually
available. Unavailable options stay on screen with the reason — "needs at least
8.6 GB of memory, this Mac has 4.3 GB" tells you what to buy.

## Speech

**Recognition** runs on this Mac. WhisperKit large-v3 via a bundled helper on a
loopback port, with whisper.cpp as a fallback. The transcriber refuses any
endpoint that is not loopback, and refuses to follow redirects: URLSession
re-sends the body on a 3xx, so a hostile local process answering `307` would be
handed your transcript.

Whisper fills silence with confabulation, and on a call it did — a silent moment
came back as Japanese and the appliance answered it. Known filler is discarded:
"thanks for watching", "subtitles by the Amara.org community", and the Japanese
equivalents, guarded by audio length so someone who genuinely says one is not
ignored.

**Synthesis** is Kokoro, an 82M-parameter Apache-2.0 model, spoken over loopback
HTTP. It is not bundled and nothing in this repository starts it; see *Not
shipped* below. When it is not running, macOS `say` answers instead. A robotic
voice is a complaint; silence is a fault.

The voice is `am_michael`, after `am_puck` read as irritated on ordinary
sentences. An appliance that answers questions all day should sound even, because
the expression is not tracking anything real.

## Privacy

The argument for this product is that your words stay on your machine, so the
places where that is not exactly true are worth stating precisely.

- **Signal messages** are end-to-end encrypted and stay within your own account.
  Mynah is a linked device, Note-to-Self only, enforced in the client before the
  daemon sees anything. Group messages are refused.
- **Recognition and synthesis** run on this Mac. Audio does not leave it.
- **The model** is where it depends on your choice. Local means your words stay
  here. An API means your words go to that provider under their terms. The setup
  screen says which, per option, rather than making you infer it.
- **Calls: the page and the signalling** go through the relay. It carries the
  offer and the answer, and an SDP describes routes — so the relay learns that a
  call happened, when, and between which addresses. That is a real cost, and it
  is why the relay is a binary you run on a host you rent rather than a service
  anyone is asked to trust.
- **Calls: the media** does not go through the relay. ICE negotiates a direct
  path, and on a home network that is your phone and the Mac across the room.
- **When no direct path exists** — symmetric NAT, which is common on cellular —
  TURN relays the media. It stays sealed under DTLS-SRTP so the relay cannot
  listen to it, but it does see that a call happened, for how long, and between
  which addresses. Running your own TURN server keeps even that metadata in your
  hands, which is why the endpoint takes a URL rather than shipping someone
  else's.
- **STUN defaults to Google's public server.** Point it elsewhere if that matters
  to you.
- **The call page** loads nothing external — no CDN, no font, no analytics —
  under a policy that permits connections only back to the relay and to the ICE
  servers.
- **Search** goes to Brave or DuckDuckGo, and it is a plain search query.

## Build

Swift, with no external dependencies. Go, for the audio.

    swift build -c release --arch arm64
    swift test

The call endpoint links a static libopus, so it needs cgo and must be built for
the architecture it runs on:

    webrtc/scripts/build-opus.sh
    webrtc/scripts/build-endpoint.sh

The relay and the TURN server are plain Go builds:

    cd webrtc && go build ./cmd/sage-call-relay && go build ./cmd/sage-turn

Packaging into a signed app and a DMG:

    scripts/vendor-sage.sh            # fetches SAGE.app
    scripts/provision-asr-assets.sh   # builds the ASR helpers, fetches the model
    scripts/provision-signal-cli.sh   # stages signal-cli 0.14.6
    scripts/release.sh                # test, build, package, sign, dmg

Signing runs inside out — helpers first, then the nested SAGE.app, then the app —
because signing an outer bundle first invalidates it the moment anything inside
is touched. The bundle carries exactly one entitlement, `device.audio-input`, and
the packaging script asserts it survived signing rather than discovering
otherwise on a stranger's Mac.

Running the relay and TURN, on the host you rent:

    sage-call-relay -domain call.example.com \
      -secret-file /etc/sage/relay.secret \
      -turn turn.example.com:3478 -turn-secret-file /etc/sage/turn.secret

    sage-turn -public-ip 203.0.113.10 -secret "$(openssl rand -hex 32)"

The relay obtains its own certificate. The appliance reads its own secret from
`~/.sage/call-relay.secret`.

`sage-voiced` is the debugging surface for all of it — `transcribe`, `brain`,
`search`, `setup`, `verify-sage`, `key`, `daemon`. Run it with no arguments for
usage.

## Not shipped

Stated plainly, because "builds and has tests" is not the same as "works":

- **No release has been published.** There are no tags and no releases on the
  repository. The DMG is built locally by `scripts/release.sh` and has not been
  uploaded anywhere.
- **Notarisation has never been submitted to Apple.** `scripts/notarize.sh` is
  written and its preflight checks are verified; the submission itself has never
  run.
- **`package-app.sh` does not stage the call endpoint into the bundle.** The
  daemon looks for `sage-voice-webrtc` beside `sage-gui` inside the vendored
  SAGE.app, and nothing in the release path puts it there. On a bundle built by
  these scripts, `//call` reports that the endpoint is not installed rather than
  pretending. Build it and place it there by hand until this is fixed.
- **Kokoro is installed separately.** `scripts/kokoro_server.py` is the server;
  its model weights are not in this repository and nothing fetches them or starts
  it. Without it, replies are spoken by macOS `say`.
- **The relay and the TURN server have no deployment tooling** — no unit file, no
  deploy script. What they need is documented in their own package comments.
- **The Go tests are not run by CI.** The release script runs `swift test` only.
  There is an end-to-end test that places a real call through a live relay
  (`webrtc/integration_test.go`); it is skipped unless `SAGE_CALL_LINK` is set.
- **`docs/RELEASE.md` describes an older pipeline** — a zip artifact and a
  version number that no longer match what the scripts produce.

## Layout

    Sources/SageVoiceCore     the appliance, as a library
      Brain/                  backends, the tool loop, MCP client, notes, search
      Call/                   answering a spoken turn
      Setup/                  environment probe, brain ranking, installers
      Speech/                 synthesis, voice notes, WAV
      Transport/              signal-cli client, sender allowlist, SETUP.md
    Sources/MynahMac          the app's screens, as a library so they are testable
    Sources/Mynah             @main, and nothing else
    Sources/sage-voiced       the daemon and the debugging CLI
    webrtc/                   the call endpoint, the relay, TURN, Opus, the VAD
    scripts/                  provisioning, packaging, signing, notarisation
    Tests/                    Swift tests; the Go tests live beside their packages

Setting Signal up by hand, without the app, is documented in
`Sources/SageVoiceCore/Transport/SETUP.md`.

## License

Apache 2.0. The speech-to-text code is lifted from
[QuietType](https://github.com/l33tdawg/quiettype), same author. The ASR runtime
depends on argmax-oss-swift (WhisperKit), MIT.
