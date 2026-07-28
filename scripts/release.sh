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
#   notarize the DMG     — that is what Apple staples, and what the owner
#                          actually downloads
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

step "provision signed speech assets"
bash scripts/provision-asr-assets.sh

step "provision signed Signal helper"
bash scripts/provision-signal-cli.sh

step "package + sign"
bash scripts/package-app.sh

step "disk image"
DMG="$(bash scripts/create-dmg.sh | head -1)"
[[ -f "$DMG" ]] || die "create-dmg.sh did not produce an image"

if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]]; then
  step "notarize + staple"
  # The DMG, not the app: it is the artifact that gets downloaded, and stapling
  # it means first launch works with no network.
  bash scripts/notarize.sh "$DMG"
fi

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
