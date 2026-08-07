# Where this came from, and what was changed

Vendored from **NousResearch/hermes-agent**, `scripts/whatsapp-bridge/`, MIT.

| | |
|---|---|
| Upstream repository | https://github.com/NousResearch/hermes-agent |
| Last commit touching `scripts/whatsapp-bridge/` | `947fdeab3bdef53bb3ff856a4bce0e6e6235122a` — 2026-08-03, *"fix(whatsapp): guard bridge reconnect against hangs and unhandled rejections"* |
| Upstream `main` when this was taken | `55505be152e3a18c7338c533c286dac655b701ec` — 2026-08-07 |
| Licence | MIT — full text in `LICENSE.hermes`, attribution in the repository `NOTICE` |
| Taken on | 7 August 2026 |

SHA-256 of the files **as they arrived**, before any local edit. Verify a
re-sync against these rather than trusting that a `git diff` is complete:

```
420b7cccf0888069de195825d726da76cc2dcf3f1fbd2e4ee163138eff83f9fb  allowlist.js
6830e1f5ecbf547070040865cd49cb92f932b0c213df77caf87f1e3ed4615172  bridge.js
08703e9f3e45b7ac82aca8814a5a3543d54b5375baad7f7264bb20d5eb334ffa  bridge_helpers.js
d022374c0a055eb4b8b60232ee4a6b1c749b78fe828e0b67bcb864e2917d8680  outbound_ids.js
c1388cfa100d662ca04bca72e003e94c5ec56d87288a7a27ccbbaf6bd8b5f8af  owner_message_gate.js
```

Every local change carries a `MYNAH:` comment. `grep -n 'MYNAH:' *.js` is the
whole diff from upstream, without needing an upstream checkout to read it.

## What was deliberately NOT taken

Hermes' own agent. `gateway/platforms/whatsapp*.py`, `plugins/platforms/whatsapp/adapter.py`
and `gateway/whatsapp_identity.py` are the Hermes runtime's half of this
conversation, and Mynah already has a runtime: `Sources/SageVoiceCore`, which
is the same brain that answers on Signal, in the window and on a call. Taking
the Python half would have meant running two agents and choosing between them
per channel.

WhatsApp is a transport here. Nothing in this directory decides what to say.

## What was changed

**Default paths.** `~/.hermes/…` → `~/Library/Application Support/SAGE Voice Bridge/WhatsApp/…`,
where the rest of this app's state lives. The reason is in the comment at the
change: the owner may well run the real Hermes on this Mac, and two WhatsApp
clients sharing one Baileys auth directory silently break each other's
decryption. The `HERMES_*` env var *names* are untouched so a re-sync stays a
clean diff.

## Measured here, 7 August 2026

Run against Node v22.22.0 on this Mac, before any Swift was written, because
every one of these could have killed the plan:

- **The bridge runs unmodified and reaches a live pairing QR in ~8 seconds.**
  Only the phone scan is missing, and only the owner can do that.
- **73 packages, 55 MB installed.** Of that, 27 MB is `sharp` and its libvips.
- **`sharp` is the only native binary in the tree** (`@img/sharp-darwin-arm64`).
  Everything else — including `whatsapp-rust-bridge`, which is Rust compiled to
  WebAssembly and inlined into a 2 MB `dist/index.js` — is portable.
- **With `sharp` and `@img` deleted outright, the bridge still starts and still
  reaches a QR.** So the tree can be one esbuild bundle with nothing native to
  codesign. Note the limit of that claim: it *starts*. Whether media sends need
  sharp for thumbnails is untested and belongs to the media phase.
- `sharp` is declared as a **non-optional peer dependency** of Baileys
  (`peerDependenciesMeta` marks `audio-decode`, `jimp` and `link-preview-js`
  optional; `sharp` is not among them), so npm installs it unless it is
  explicitly excluded. That is a deliberate exclusion to write down, not an
  accident to rely on.

This matters because of how everything else ships inside Mynah.app: one
self-contained native binary plus data. signal-cli is a 121 MB arm64
native-image; pandoc, typst and espeak-ng are single binaries. `node` is 112 MB
and is one binary, so *node + one bundled .js* keeps that pattern. A 500-file
`node_modules` tree going through `codesign` would not.

## Known shape mismatch, not yet fixed

Upstream's inbound path is `GET /messages` doing
`messageQueue.splice(0, messageQueue.length)` — drain and destroy, at most once.
A crash between the HTTP read and the agent accepting the turn loses the
message with no trace, and the queue also drops its oldest entry past
`MAX_QUEUE_SIZE`.

That is the defect shape this codebase spent 1.8.3, 1.8.5 and 1.9.0 removing:
*"I could not look"* must never reach the owner as *"there was nothing there"*.
It is fine for Hermes, whose consumer is a co-supervised Python process. It is
not fine here.

Two ways out, to be decided before the Swift consumer is written:

1. **Acknowledge.** `/messages` stops destroying on read; a second call
   confirms the turn was accepted. Smallest diff from upstream.
2. **Push instead of poll.** The bridge writes newline-delimited JSON to a
   UNIX socket, at which point `Sources/SageVoiceCore/Transport/SignalLineSocket.swift`
   is reusable verbatim and WhatsApp arrives on the same wire shape as Signal.
   Bigger diff, better fit, and it drops the loopback TCP port — which on a
   multi-user Mac is worse than a `0600` socket even with the Host-header
   check upstream added for GHSA-ppp5-vxwm-4cf7.

## The risk, stated once

Baileys emulates WhatsApp Web. It is not the WhatsApp Business API, and it is
not authorised by WhatsApp — its own README says the maintainers do not condone
use that violates WhatsApp's Terms of Service. Linking a personal number to an
automation can get that number banned. Which number to pair is the owner's
call, and the pairing itself needs his phone.
