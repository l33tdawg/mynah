# signal-cli setup for the SAGE voice bridge

Operator runbook for the Mac mini (`ssh sage-mini`). Steps 1–3 are one-time and interactive —
they need the owner's phone in hand. Step 4 makes the daemon permanent.

Everything below was written against **signal-cli 0.14.6** (Homebrew stable as of 2026-07).
Reference: `signal-cli(1)` and `signal-cli-jsonrpc(5)` in
<https://github.com/AsamK/signal-cli/tree/master/man>.

---

## 0. Facts about the target box (checked 2026-07-27)

* `signal-cli` is **not installed** and no `~/.local/share/signal-cli` exists yet.
* There is **no JRE on the box** (`/usr/libexec/java_home` finds nothing) — and none is
  needed: the Homebrew bottle of signal-cli 0.14.6 is a GraalVM **native image** with an
  empty runtime-dependency list. Do not install a JDK for this.
* Homebrew 6.0.12 at `/opt/homebrew`, user `ableton`, uid 501.
* `XDG_RUNTIME_DIR` is **empty**, which is why every command below passes an explicit
  `--socket=PATH` instead of relying on signal-cli's default socket location.

## 1. Install

```sh
brew install signal-cli
signal-cli --version          # expect: signal-cli 0.14.6 or newer
```

## 2. Link as a secondary device (one time, needs the phone)

signal-cli joins the owner's existing Signal account as a **linked device**, exactly like
Signal Desktop. The phone stays the primary device. No business account, no re-registration,
no new phone number.

```sh
brew install qrencode                       # to render the linking URI as a QR code

# Prints an sgnl://linkdevice?uuid=...&pub_key=... URI and then BLOCKS, waiting for the phone.
signal-cli link -n "sage-voice-bridge"
```

In a second terminal, turn the printed URI into a QR code and scan it:

```sh
qrencode -t UTF8 'sgnl://linkdevice?uuid=XXXX&pub_key=YYYY'
```

On the phone: **Signal → Settings → Linked devices → Link New Device → scan the QR code.**

The URI expires after a couple of minutes; if it times out, re-run `signal-cli link`.

Then pull down contacts and groups, and confirm the account is live:

```sh
signal-cli -a +COUNTRYCODENUMBER receive          # runs once, syncs and exits
signal-cli -a +COUNTRYCODENUMBER listGroups       # should print without error
signal-cli -a +COUNTRYCODENUMBER send -m "bridge online" +COUNTRYCODENUMBER   # Note to Self
```

Notes:

* A newly linked device does **not** get message history. Only messages sent from the moment
  of linking onward reach it.
* Account state lives in `~/.local/share/signal-cli/` (`$XDG_DATA_HOME/signal-cli` when set).
  Back that directory up; losing it means re-linking. It contains long-term Signal keys —
  keep it `chmod 700`.

## 3. Smoke-test the JSON-RPC daemon by hand

```sh
mkdir -p ~/.local/share/signal-cli
chmod 700 ~/.local/share/signal-cli

signal-cli -a +COUNTRYCODENUMBER daemon \
    --socket="$HOME/.local/share/signal-cli/daemon.socket" \
    --receive-mode=on-start \
    --no-receive-stdout
```

From another shell, poke it (one JSON object per line, in and out):

```sh
echo '{"jsonrpc":"2.0","method":"listGroups","id":"1"}' \
  | nc -U ~/.local/share/signal-cli/daemon.socket
```

Now send yourself a **voice note** in Signal (Note to Self). The daemon emits a line like:

```json
{"jsonrpc":"2.0","method":"receive","params":{"envelope":{
  "source":"+60123456789","sourceNumber":"+60123456789","sourceUuid":"5b1f…","sourceDevice":1,
  "timestamp":1753600000000,
  "syncMessage":{"sentMessage":{
    "destination":"+60123456789","destinationNumber":"+60123456789","timestamp":1753600000000,
    "message":"","expiresInSeconds":0,"viewOnce":false,
    "attachments":[{"contentType":"audio/aac","filename":null,"id":"n7Yl3s+Rk/0aQ==",
                    "size":18342,"width":null,"height":null,"caption":null,
                    "uploadTimestamp":1753599999000}]}}},
  "account":"+60123456789"}}
```

and the decrypted audio appears under `~/.local/share/signal-cli/attachments/`.

Two things about that envelope that the code depends on:

* **Note to Self arrives as `syncMessage.sentMessage`, not `dataMessage`.** A message the
  owner sends from their phone reaches this linked device as a *sync* of their own outgoing
  message. `SignalClient` handles both shapes; the allowlist requires the sync *destination*
  to be allowlisted too, which is what keeps "the owner texted somebody else" out of the
  agent loop.
* **The JSON has no file path.** `JsonAttachment` is only
  `contentType, filename, id, size, width, height, caption, uploadTimestamp`. signal-cli
  writes the file as `attachments/<sanitised-id><ext>`, where the id is sanitised with
  `[^A-Za-z0-9_.-] -> _` and the extension is taken from the sender's filename or *guessed*
  from the MIME type (voice notes are `audio/aac` with no filename, so it may be `.aac` or
  nothing at all). `SignalAttachmentLocator` reproduces that and falls back to scanning the
  directory, so don't hardcode a name.

`Ctrl-C` the daemon when you are done.

## 4. Run it under launchd

`~/Library/LaunchAgents/com.sage.signal-cli.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.sage.signal-cli</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/signal-cli</string>
    <string>-a</string><string>+COUNTRYCODENUMBER</string>
    <string>daemon</string>
    <string>--socket=/Users/ableton/.local/share/signal-cli/daemon.socket</string>
    <string>--receive-mode=on-start</string>
    <string>--no-receive-stdout</string>
    <string>--ignore-stories</string>
    <string>--ignore-stickers</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/ableton/Library/Logs/signal-cli.log</string>
  <key>StandardErrorPath</key><string>/Users/ableton/Library/Logs/signal-cli.err.log</string>
</dict>
</plist>
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sage.signal-cli.plist
launchctl print gui/$(id -u)/com.sage.signal-cli | head
```

Do **not** pass `--ignore-attachments`: it stops voice notes being downloaded, which is the
entire point of this bridge.

## 5. Point the Swift client at it

```swift
import SageVoiceCore

// No default-open mode: this throws if the list is empty or unparseable.
let allowlist = try SignalSenderAllowlist.fromEnvironment("SAGE_SIGNAL_ALLOWLIST")

let client = SignalClient(configuration: .init(
    allowlist: allowlist,
    endpoint: .unixSocket(path: NSHomeDirectory() + "/.local/share/signal-cli/daemon.socket"),
    account: nil,                       // set only if the daemon runs multi-account (no -a)
    receiveMode: .automatic             // matches --receive-mode=on-start
))
await client.start()

for await message in client.incomingMessages {
    // Only allowlisted senders get here.
    if let audio = message.voiceNoteURL {
        // hand to WhisperKitServerTranscriber
    }
    try await client.reply(to: message, text: "…")
}
```

Set the allowlist in the daemon's own launchd plist:

```xml
<key>EnvironmentVariables</key>
<dict><key>SAGE_SIGNAL_ALLOWLIST</key><string>+COUNTRYCODENUMBER</string></dict>
```

The owner's own number is normally the only entry — that is what makes Note to Self the
command channel.

## 6. Operational notes

* **Socket path length.** `sun_path` is 104 bytes on Darwin. Keep the socket under a short
  path; `SignalClient` reports `socketPathTooLong` rather than truncating.
* **Prefer the UNIX socket over `--tcp`.** `--tcp=127.0.0.1:7583` is reachable by every local
  process and every user on the box; the socket file inherits directory permissions. Keep
  `~/.local/share/signal-cli` at mode 700.
* **Receive modes.** With `--receive-mode=on-start` (used above) notifications arrive
  unsolicited on every connected client — use `receiveMode: .automatic`. With
  `--receive-mode=manual`, use `receiveMode: .manual` and the client issues `subscribeReceive`
  on every (re)connect, including after a reconnect.
* **Restarts.** `SignalClient` reconnects on its own with exponential backoff plus jitter
  (0.5s → 30s), so `launchctl kickstart -k` on the daemon is safe.
* **Attachment housekeeping.** signal-cli never prunes
  `~/.local/share/signal-cli/attachments/`. Add a cleanup job once voice traffic is routine.
* **Voice-note replies (later phase).** Signal has no protocol-level "voice note" flag that
  signal-cli exposes on send; a voice reply is just an `audio/*` attachment:
  `client.send(text: nil, attachmentPaths: ["/tmp/reply.m4a"], to: recipient)`. The file must
  be readable by the *signal-cli* process, which is why both run as the same user.
* **Group traffic is refused by default** (`SignalSenderAllowlist.Policy.allowGroupMessages`).
  Turning it on means anyone in a shared group can address the agent fleet; do it deliberately.
