#!/usr/bin/env bash
# One command from a clean checkout to a notarized, verified DMG.
#
#   scripts/release.sh                        # ad-hoc build, no notarization
#   MYNAH_NOTARIZE=1 \
#   SAGE_VOICE_CODESIGN_IDENTITY="Developer ID Application: …" \
#     scripts/release.sh                      # the real thing
#
# Order matters and is not arbitrary:
#   tests before build   — a release that fails its own suite should never reach
#                          a signing key
#   build before package — package-app.sh copies binaries, it does not make them
#   package before dmg   — create-dmg.sh refuses an unsigned bundle
#   notarize before dmg  — the ticket staples to the .app; an image built before
#                          that carries an unstapled bundle and needs the network
#                          on first launch. Notarizing the image instead does not
#                          work at all: notarize.sh takes a bundle, not a file.
#   dmg last             — so the image is built around a stapled bundle and its
#                          .sha256 describes the bytes that actually ship
#   verify after staple  — the only check that answers "will this launch on a Mac
#                          that has never seen it"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NOTARIZE="${MYNAH_NOTARIZE:-0}"
SIGN_IDENTITY="${SAGE_VOICE_CODESIGN_IDENTITY:--}"
export SAGE_VOICE_CODESIGN_IDENTITY="$SIGN_IDENTITY"

step() { printf '\n=== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# Fail before the slow part rather than after it. Notarization with an ad-hoc
# signature is rejected by Apple minutes into the submission, and the useful
# time to learn that is now.
if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]]; then
  [[ "$SIGN_IDENTITY" != "-" ]] \
    || die "MYNAH_NOTARIZE=1 needs SAGE_VOICE_CODESIGN_IDENTITY set to a Developer ID Application identity.
Apple will not notarize an ad-hoc signature."
  [[ -n "${MYNAH_NOTARY_PROFILE:-}" || -n "${MYNAH_APPLE_ID:-}" ]] \
    || die "MYNAH_NOTARIZE=1 needs MYNAH_NOTARY_PROFILE (or MYNAH_APPLE_ID + MYNAH_TEAM_ID + MYNAH_APP_PASSWORD).
See scripts/notarize.sh for how to store a keychain profile."
fi

step "tests"
swift test

step "release build"
swift build -c release --arch arm64

# The call endpoint, which package-app.sh requires and this script never built.
#
# It went unnoticed because every release so far was cut from the working repo,
# where `.build/sage-voice-webrtc` was left behind by an earlier manual run.
# Building from a clean checkout is what surfaced it: package-app.sh stops with
# "Required call endpoint is missing", naming the file and not the reason this
# script did not produce it.
#
# Separate from `swift build` because the endpoint is Go with cgo and a static
# libopus, so it is built one architecture at a time — see the trap documented
# in the script itself, where a Rosetta Go toolchain silently emits an Intel
# binary that cannot link an arm64 archive.
step "call endpoint"
bash webrtc/scripts/build-endpoint.sh

step "provision signed speech assets"
bash scripts/provision-asr-assets.sh

step "provision signed Signal helper"
bash scripts/provision-signal-cli.sh

# The native voice's two binaries. package-app.sh requires both and this script
# would otherwise never produce them — the same omission the call endpoint above
# documents, which stayed hidden for several releases because the working repo
# happened to have the artifact lying around from a manual run.
#
# espeak-ng is built from source rather than downloaded, so this is the slowest
# step here by some margin. It is skipped on a repeat run: both scripts stop
# early when their output is already staged.
step "provision ONNX Runtime for the native voice"
bash scripts/provision-onnxruntime.sh

step "provision espeak-ng for the native voice"
bash scripts/provision-espeak-ng.sh

step "package + sign"
bash scripts/package-app.sh

# Notarize BEFORE the disk image, not after.
#
# This used to run create-dmg.sh first and then hand the .dmg to notarize.sh,
# which fails outright: notarize.sh guards with `[[ -d "$APP" ]]` and a disk
# image is a file, so every notarized run died on "No app at …/Mynah.dmg". The
# one-command path in this script's own header had therefore never once
# produced a notarized release; every real one was assembled by hand.
#
# Two more things went wrong in that order even after the argument was right:
#
#   * Stapling the app does not staple a disk image built before it, so the
#     image shipped an unstapled bundle and first launch needed the network —
#     the exact thing the old comment here claimed to be preventing.
#   * create-dmg.sh writes the .sha256 as it builds. Attaching a ticket
#     afterwards rewrites the image, so the recorded checksum described a file
#     that no longer existed and verify-dmg.sh failed on its first check.
#
# Notarizing the bundle first settles all three: the ticket is stapled to the
# app, the image is then built around an already-stapled bundle, and the
# checksum is written last, over the bytes that actually ship.
if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]]; then
  step "notarize + staple"
  bash scripts/notarize.sh "$ROOT/dist/Mynah.app"
fi

step "disk image"
DMG="$(bash scripts/create-dmg.sh | head -1)"
[[ -f "$DMG" ]] || die "create-dmg.sh did not produce an image"

step "verify"
if ! bash scripts/verify-dmg.sh "$DMG"; then
  if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]]; then
    die "a notarized release failed verification — do not publish this"
  fi
  echo
  echo "note: Gatekeeper/staple checks fail for an ad-hoc build. Expected."
  echo "      Set MYNAH_NOTARIZE=1 with a Developer ID identity for a real release."
fi

echo
echo "Artifact:"
ls -lh "$DMG" "$DMG.sha256"
