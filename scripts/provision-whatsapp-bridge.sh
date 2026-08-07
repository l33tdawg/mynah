#!/usr/bin/env bash
# Installs the WhatsApp bridge's dependencies, and refuses to leave behind a
# tree that cannot ship.
#
# **Why this is not just `npm install`.** Everything else inside Mynah.app is
# one self-contained native binary plus data — signal-cli is a 121 MB arm64
# native-image, pandoc and typst and espeak-ng are single binaries. A plain
# install here produces 55 MB across 73 packages including `sharp`, which drags
# in libvips and is the one genuinely native thing in the tree. A native .node
# addon inside a hardened-runtime bundle is its own signing and notarisation
# problem, and it buys us thumbnails.
#
# `--legacy-peer-deps` is what removes it: sharp is declared as a NON-optional
# peer dependency of Baileys, so npm 7+ installs it automatically, and npm 6
# semantics do not. Measured 7 Aug 2026: 32 MB, zero .node files, and the
# bridge still reaches a pairing QR.
#
# `--ignore-scripts` because a postinstall hook is arbitrary code from 135
# packages running on the build Mac. Nothing in this tree needs one — verified
# by the start check at the bottom, which is the only proof that matters.
#
# The checks below are not belt-and-braces. Each one has a specific failure it
# is there to catch, named in its own message.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="${SAGE_VOICE_WHATSAPP_DIR:-$ROOT/whatsapp}"
EXPECTED_NODE_MAJOR="${SAGE_VOICE_NODE_MAJOR:-22}"

die() { echo "error: $*" >&2; exit 1; }

[[ -f "$BRIDGE_DIR/package.json" ]] \
  || die "no bridge at $BRIDGE_DIR — expected package.json beside bridge.js"

# --- the runtime ------------------------------------------------------------
#
# Checked before the install rather than after, because npm's own error for a
# too-old Node is about engines and does not say what to do about it.
NODE="$(command -v node || true)"
[[ -n "$NODE" ]] || die \
"node is not on PATH, and the WhatsApp bridge is a Node process.

Install Node $EXPECTED_NODE_MAJOR (nvm install $EXPECTED_NODE_MAJOR) and run this again."

NODE_VERSION="$("$NODE" --version)"          # e.g. v22.22.0
NODE_MAJOR="${NODE_VERSION#v}"; NODE_MAJOR="${NODE_MAJOR%%.*}"
[[ "$NODE_MAJOR" -ge "$EXPECTED_NODE_MAJOR" ]] || die \
"node is $NODE_VERSION; the bridge needs $EXPECTED_NODE_MAJOR or newer.

Baileys 7 uses WebAssembly and modern ESM. Run: nvm install $EXPECTED_NODE_MAJOR"

echo "node $NODE_VERSION at $NODE"

# --- the tree ---------------------------------------------------------------
npm install \
  --prefix "$BRIDGE_DIR" \
  --legacy-peer-deps \
  --ignore-scripts \
  --no-audit --no-fund

MODULES="$BRIDGE_DIR/node_modules"
[[ -d "$MODULES" ]] || die "npm install finished but produced no node_modules at $MODULES"

# --- nothing native ---------------------------------------------------------
#
# The whole reason for --legacy-peer-deps. If this ever fires, a dependency has
# started shipping a native addon and the single-bundle plan needs revisiting
# BEFORE somebody discovers it at codesign time in the middle of a release.
NATIVE="$(find "$MODULES" -name '*.node' -type f)"
if [[ -n "$NATIVE" ]]; then
  echo "$NATIVE" >&2
  die \
"the dependency tree now contains native addons (listed above).

Everything in Mynah.app is signed, and a nested .node inside a hardened-runtime
bundle needs its own codesign pass and its own notarisation. Either exclude the
package that pulled it in, or decide deliberately to sign it and update
scripts/package-app.sh — do not let it ship unnoticed."
fi

if [[ -d "$MODULES/sharp" || -d "$MODULES/@img" ]]; then
  die \
"sharp was installed after all — --legacy-peer-deps did not exclude it.

npm's peer-dependency behaviour has changed, or something now depends on sharp
directly. See whatsapp/package.json 'comment:sharp' for why it is excluded, then
either restore the exclusion or accept the 27 MB and the native addon knowingly."
fi

# --- it actually starts -----------------------------------------------------
#
# The only check here that could have caught a broken tree. A dependency graph
# that resolves is not a program that runs: an ESM import that fails resolves
# fine on disk and throws at first execution, and every check above would still
# have passed. So: start it, wait for it to say it is listening, kill it.
#
# It talks to WhatsApp — anonymously, asking for a pairing QR. Nothing is paired
# without somebody scanning that QR with a phone, which no script can do.
PROBE_SESSION="$(mktemp -d)"
PROBE_LOG="$(mktemp)"
PROBE_PORT="${SAGE_VOICE_WHATSAPP_PROBE_PORT:-39931}"
cleanup() { rm -rf "$PROBE_SESSION" "$PROBE_LOG"; }
trap cleanup EXIT

set +e
WHATSAPP_MODE=self-chat WHATSAPP_ALLOWED_USERS=0000000000 \
  "$NODE" "$BRIDGE_DIR/bridge.js" \
    --port "$PROBE_PORT" \
    --session "$PROBE_SESSION" \
  >"$PROBE_LOG" 2>&1 &
PROBE_PID=$!
set -e

# Fifteen seconds. It listened in well under one on the machine this was
# written on; the headroom is for a cold WebAssembly compile, not for hope.
for _ in $(seq 1 150); do
  grep -q "bridge listening on port" "$PROBE_LOG" && break
  kill -0 "$PROBE_PID" 2>/dev/null || break
  sleep 0.1
done

kill "$PROBE_PID" 2>/dev/null || true
wait "$PROBE_PID" 2>/dev/null || true

if ! grep -q "bridge listening on port" "$PROBE_LOG"; then
  echo "--- bridge output ---" >&2
  cat "$PROBE_LOG" >&2
  die \
"the bridge did not start (output above).

The dependency tree installed but the program does not run. Most likely an ESM
import that resolves on disk and throws at execution — check the first stack
frame above. Do not stage this into a release."
fi

echo "bridge starts, no native addons, $(du -sh "$MODULES" | cut -f1) installed"
echo "$BRIDGE_DIR"
