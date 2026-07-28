#!/usr/bin/env bash
# Checks a built DMG the way a stranger's Mac will.
#
# Exists because every failure this catches is invisible on the machine that
# built it: the signature validates against a local keychain, and the
# notarization ticket is only consulted when Gatekeeper cannot phone home. The
# only honest check is to mount the image and assess the app inside it.
set -euo pipefail

DMG="${1:?usage: verify-dmg.sh <path-to-dmg>}"
die() { echo "error: $*" >&2; exit 1; }

[[ -f "$DMG" ]] || die "no such file: $DMG"

echo "== checksum"
( cd "$(dirname "$DMG")" && shasum -a 256 -c "$(basename "$DMG").sha256" ) \
  || die "checksum does not match $DMG.sha256"

echo "== disk image"
hdiutil verify "$DMG" >/dev/null || die "hdiutil rejected the image"

MOUNT="$(mktemp -d)"
cleanup() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$MOUNT"; }
trap cleanup EXIT
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null \
  || die "could not mount $DMG"

APP="$MOUNT/Mynah.app"
[[ -d "$APP" ]] || die "no Mynah.app inside the image"
[[ -L "$MOUNT/Applications" ]] || die "no /Applications symlink — nothing to drag onto"

echo "== signature"
codesign --verify --deep --strict --verbose=2 "$APP" || die "signature is not valid"

echo "== gatekeeper"
# The real question: would this launch on a Mac that has never seen it? `spctl`
# answers it, and it is the check that fails when notarization was skipped or
# the ticket was never stapled.
if spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee /dev/stderr | grep -q "accepted"; then
  echo "   accepted by Gatekeeper"
else
  echo "   NOT accepted — unsigned, unnotarized, or the ticket is not stapled" >&2
  echo "   (expected for an ad-hoc local build; a release build must pass)" >&2
  exit 1
fi

echo "== notarization ticket"
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "   stapled"
else
  echo "   NOT stapled — the app needs the network to launch the first time" >&2
  exit 1
fi

echo
echo "OK: $DMG"
