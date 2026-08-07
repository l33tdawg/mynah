#!/usr/bin/env bash
# Shows a WhatsApp pairing QR and keeps the bridge running once it is scanned.
#
#     scripts/pair-whatsapp.sh 60123456789
#
# The number is the one allowed to talk to Mynah — digits only, country code
# first, no `+`. For the Message-Yourself setup in the plan, that is your own
# number: you message yourself, and Mynah answers in that thread.
#
# **No default number, ever.** SignalSenderAllowlist has the same rule and says
# why: "There is no way to construct a Configuration without one, and no way to
# construct an allowlist that matches everybody." An allowlist that can be
# forgotten is an allowlist that will be. This one has to be typed.
#
# Pairing is a one-time act and it survives restarts. Session state lands in
# ~/Library/Application Support/SAGE Voice Bridge/WhatsApp/session and is worth
# exactly as much as the account: anyone holding it is logged in as you. It is
# outside the repository on purpose.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="${SAGE_VOICE_WHATSAPP_DIR:-$ROOT/whatsapp}"
PORT="${SAGE_VOICE_WHATSAPP_PORT:-39930}"
SESSION_DIR="${SAGE_VOICE_WHATSAPP_SESSION:-$HOME/Library/Application Support/SAGE Voice Bridge/WhatsApp/session}"
# Derived from the session directory rather than hardcoded, so overriding the
# session with SAGE_VOICE_WHATSAPP_SESSION does not leave the chmod below
# pointing at a directory this run never touches.
STATE_DIR="$(dirname "$SESSION_DIR")"

die() { echo "error: $*" >&2; exit 1; }

ALLOWED="${1:-${WHATSAPP_ALLOWED_USERS:-}}"
[[ -n "$ALLOWED" ]] || die \
"no number given, so nobody would be allowed to talk to Mynah.

    scripts/pair-whatsapp.sh <number>

Digits only, country code first, no '+' and no spaces — 60123456789, not
+60 12-345 6789. Several numbers can be given comma-separated.
For the Message-Yourself setup, use your own number."

[[ "$ALLOWED" =~ ^[0-9,]+$ ]] || die \
"'$ALLOWED' is not a bare number list.

WhatsApp identifies people by digits: country code then number, no '+', no
spaces, no dashes. Comma-separate several. A '+' here does not fail loudly —
it fails as an allowlist that never matches, so your own messages would be
ignored and it would look like the bridge was broken."

[[ -d "$BRIDGE_DIR/node_modules" ]] || die \
"the bridge's dependencies are not installed.

Run: scripts/provision-whatsapp-bridge.sh"

# Refuse rather than fight over the port. Two bridges on one Baileys session
# directory is the collision described in whatsapp/PROVENANCE.md — they
# invalidate each other's keys and both stop decrypting, silently.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die \
"something is already listening on port $PORT — most likely a bridge you
started earlier.

Find it with:  lsof -nP -iTCP:$PORT -sTCP:LISTEN
Stop that one before starting another. Two bridges sharing one session
directory invalidate each other's keys and both quietly stop decrypting."
fi

mkdir -p "$SESSION_DIR"
chmod 700 "$STATE_DIR" "$SESSION_DIR"

if [[ -f "$SESSION_DIR/creds.json" ]]; then
  echo "Already paired — this session is in $SESSION_DIR."
  echo "Starting the bridge. There will be no QR; that is what paired means."
  echo "To pair a different number, delete that directory first."
else
  cat <<'BANNER'

  Before you scan.

  This links your WhatsApp account to an automated client, the same way
  WhatsApp Web does. It is Baileys, which emulates WhatsApp Web — it is not
  the official Business API, and WhatsApp has not authorised it. Accounts
  have been banned for automation. Whether that is a risk worth taking on
  this particular number is your call, not this script's.

  Nothing is linked until you scan. Ctrl-C now costs nothing.

BANNER
  echo "  On the phone: WhatsApp → Settings → Linked Devices → Link a Device"
  echo "  Then point it at the QR below."
  echo
fi

echo "  Allowed: $ALLOWED"
echo "  Session: $SESSION_DIR"
echo "  Bridge:  http://127.0.0.1:$PORT  (loopback only)"
echo

# self-chat is the plan's Message-Yourself setup: one number, and Mynah answers
# in the thread you already talk to yourself in. `bot` mode is for a bridge with
# its own separate number, which is the better shape long-term and needs a
# second SIM.
exec env \
  WHATSAPP_MODE="${WHATSAPP_MODE:-self-chat}" \
  WHATSAPP_ALLOWED_USERS="$ALLOWED" \
  node "$BRIDGE_DIR/bridge.js" --port "$PORT" --session "$SESSION_DIR"
