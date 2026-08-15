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
DEVICE=""
cleanup() {
  local original_status=$?
  local detached=0
  trap - EXIT

  if [[ -n "$DEVICE" ]]; then
    # Spotlight and Gatekeeper can keep a freshly inspected image busy for a
    # moment. Retry the exact device, not a path which may already have been
    # reused; reserve force for the final attempt.
    for attempt in 1 2 3; do
      if [[ "$attempt" -eq 3 ]]; then
        hdiutil detach "$DEVICE" -force -quiet 2>/dev/null && detached=1 && break
      else
        hdiutil detach "$DEVICE" -quiet 2>/dev/null && detached=1 && break
      fi
      sleep 1
    done
  fi

  # Never recurse into a live read-only volume. This exact mistake made the
  # beta.10 release command exit non-zero after every verification had passed.
  if /sbin/mount | grep -F " on $MOUNT (" >/dev/null 2>&1; then
    echo "error: could not detach $DEVICE; leaving mounted image at $MOUNT" >&2
    exit 1
  fi
  rm -rf "$MOUNT"
  [[ "$detached" -eq 1 || -z "$DEVICE" ]] || original_status=1
  exit "$original_status"
}

trap cleanup EXIT
ATTACH_OUTPUT="$(hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT")" \
  || die "could not mount $DMG"
DEVICE="$(awk '$1 ~ /^\/dev\/disk[0-9]+$/ { print $1; exit }' <<<"$ATTACH_OUTPUT")"
case "$DEVICE" in
  /dev/disk[0-9]*) ;;
  *) die "mounted $DMG but could not identify its device" ;;
esac

APP="$MOUNT/Mynah.app"
[[ -d "$APP" ]] || die "no Mynah.app inside the image"
[[ -L "$MOUNT/Applications" ]] || die "no /Applications symlink — nothing to drag onto"

echo "== signature"
codesign --verify --deep --strict --verbose=2 "$APP" || die "signature is not valid"

echo "== gatekeeper"
# The real question: would this launch on a Mac that has never seen it? `spctl`
# answers it, and it is the check that fails when notarization was skipped or
# the ticket was never stapled.
#
# Captured into a variable, and read from `spctl`'s own exit status rather than
# by grepping its text. This is the same bug c93496b fixed in
# verify-vendored-sage.sh: under `set -o pipefail`, `| tee /dev/stderr | grep -q`
# fails a check that passed, because `grep -q` exits at the first match, `tee`
# then dies of SIGPIPE, and pipefail reports the whole pipeline as failed.
#
# Worse than the earlier instance because it is a race rather than a certainty —
# whether `tee` has finished writing when `grep` leaves decides it. The 1.1.0
# release verified and 1.1.1 did not, from builds that were both correctly
# signed, notarized and stapled. A release gate that fails intermittently on
# good artifacts is one that gets ignored, which is the real damage.
if ASSESSMENT="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)"; then
  echo "$ASSESSMENT"
  echo "   accepted by Gatekeeper"
else
  echo "$ASSESSMENT" >&2
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
