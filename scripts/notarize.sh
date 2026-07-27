#!/usr/bin/env bash
# Notarizes, staples and verifies Mynah.app.
#
#   scripts/notarize.sh [path/to/Mynah.app]
#
# Notarization is Apple scanning the build and issuing a ticket that says "this
# is not malware". Without it, the owner's first experience of Mynah is macOS
# refusing to open it — and on recent macOS there is no "open anyway" in the
# dialog, so a non-technical person is simply stuck. Stapling attaches the
# ticket to the bundle so the check also works on a Mac that is offline.
#
# Credentials come from the environment. Nothing is written to this file, ever;
# an app-specific password in a repo is an Apple ID handed to anyone who clones
# it. Pick ONE of:
#
#   1. A keychain profile (best — the secret lives in the login keychain):
#        export MYNAH_NOTARY_PROFILE=MYNAH_NOTARY
#      Created once with:
#        xcrun notarytool store-credentials MYNAH_NOTARY \
#          --apple-id you@example.com --team-id ABCDE12345 \
#          --password <app-specific-password-from-appleid.apple.com>
#
#   2. An App Store Connect API key (best for CI — revocable, no Apple ID):
#        export MYNAH_NOTARY_KEY=/path/AuthKey_XXXXXXXX.p8
#        export MYNAH_NOTARY_KEY_ID=XXXXXXXX
#        export MYNAH_NOTARY_ISSUER=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
#
#   3. Apple ID + app-specific password directly:
#        export MYNAH_APPLE_ID=you@example.com
#        export MYNAH_TEAM_ID=ABCDE12345
#        export MYNAH_APP_PASSWORD=abcd-efgh-ijkl-mnop
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${SAGE_VOICE_APP_PATH:-$ROOT/dist/Mynah.app}}"

die() { echo "" >&2; echo "$*" >&2; exit 1; }
capture() { "$@" 2>&1 || true; }   # see package-app.sh: pipefail + grep -q = SIGPIPE

command -v xcrun >/dev/null || die "xcrun not found — install Xcode (the full app, not just the command line tools)."

[[ -d "$APP" ]] || die "No app at $APP
Build and package it first:
  swift build -c release --arch arm64
  SAGE_VOICE_CODESIGN_IDENTITY=\"Developer ID Application: …\" scripts/package-app.sh"

# ------------------------------------------------------- credentials

AUTH=()
if [[ -n "${MYNAH_NOTARY_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$MYNAH_NOTARY_PROFILE")
  echo "Authenticating with keychain profile $MYNAH_NOTARY_PROFILE"
elif [[ -n "${MYNAH_NOTARY_KEY:-}" && -n "${MYNAH_NOTARY_KEY_ID:-}" && -n "${MYNAH_NOTARY_ISSUER:-}" ]]; then
  [[ -f "$MYNAH_NOTARY_KEY" ]] || die "MYNAH_NOTARY_KEY points at nothing: $MYNAH_NOTARY_KEY"
  AUTH=(--key "$MYNAH_NOTARY_KEY" --key-id "$MYNAH_NOTARY_KEY_ID" --issuer "$MYNAH_NOTARY_ISSUER")
  echo "Authenticating with App Store Connect API key $MYNAH_NOTARY_KEY_ID"
elif [[ -n "${MYNAH_APPLE_ID:-}" && -n "${MYNAH_TEAM_ID:-}" && -n "${MYNAH_APP_PASSWORD:-}" ]]; then
  AUTH=(--apple-id "$MYNAH_APPLE_ID" --team-id "$MYNAH_TEAM_ID" --password "$MYNAH_APP_PASSWORD")
  echo "Authenticating as $MYNAH_APPLE_ID (team $MYNAH_TEAM_ID)"
else
  die "No notarization credentials in the environment.

Set one of these groups (see the comment at the top of this script):
  MYNAH_NOTARY_PROFILE
  MYNAH_NOTARY_KEY + MYNAH_NOTARY_KEY_ID + MYNAH_NOTARY_ISSUER
  MYNAH_APPLE_ID + MYNAH_TEAM_ID + MYNAH_APP_PASSWORD"
fi

# ------------------------------------------------------- preflight
#
# Every check here is something Apple would also catch — but only after the
# upload, the queue and the scan, which is minutes of waiting to be told
# something visible in one second locally.

echo "Checking the signature before uploading…"

SIG="$(capture codesign --display --verbose=4 "$APP")"

case "$SIG" in
  *"Signature=adhoc"*)
    die "$(basename "$APP") is ad-hoc signed. Apple will reject it.

Re-package with a real identity:
  security find-identity -v -p codesigning        # list what you have
  SAGE_VOICE_CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" \\
    scripts/package-app.sh

A 'Developer ID Application' certificate is the one for apps distributed
outside the App Store. 'Apple Development' and 'Mac App Distribution' are
different certificates and neither can be notarized this way." ;;
esac

case "$SIG" in
  *"Authority=Developer ID Application"*) ;;
  *) die "$(basename "$APP") is not signed with a Developer ID Application certificate.

codesign reports:
$(echo "$SIG" | grep -E '^(Authority|TeamIdentifier)=' || echo '  (no authority at all)')

Only 'Developer ID Application' can be notarized for distribution outside the
App Store. Re-package with SAGE_VOICE_CODESIGN_IDENTITY set to one." ;;
esac

case "$SIG" in
  *"flags="*"runtime"*) ;;
  *) die "$(basename "$APP") is not signed with the hardened runtime, which
notarization requires.

scripts/package-app.sh passes '--options runtime' by default, so something
overrode SAGE_VOICE_CODESIGN_OPTIONS. Unset it and package again." ;;
esac

case "$SIG" in
  *"Timestamp="*) ;;
  *) die "$(basename "$APP") has no secure timestamp.

A timestamp needs network access at signing time, so this usually means the
signing machine was offline or behind a proxy that blocks
timestamp.apple.com. Get online and package again — package-app.sh passes
--timestamp automatically for real identities." ;;
esac

echo "Verifying seals…"
codesign --verify --deep --strict --verbose=2 "$APP" \
  || die "The bundle's own signature does not verify, so notarization cannot help.

This almost always means something was modified after signing, or the pieces
were signed in the wrong order. Re-run scripts/package-app.sh, which signs
strictly inside out, rather than re-signing by hand."

# ------------------------------------------------------- submit

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "0")"
LABEL="$(/usr/libexec/PlistBuddy -c 'Print :SageVoiceBridgeReleaseLabel' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
SUFFIX=""
[[ -n "$LABEL" ]] && SUFFIX="-$LABEL"

OUT_DIR="$(dirname "$APP")"
ZIP="$OUT_DIR/Mynah-${VERSION}${SUFFIX}-macOS-arm64.zip"

# notarytool takes a .zip, .dmg or .pkg — never a bare .app. ditto is the only
# zipper that preserves symlinks and extended attributes correctly; `zip -r`
# mangles the bundle and the upload is rejected for a corrupt signature.
# Braces are load-bearing: bash folds the following multibyte ellipsis into the
# variable name and the script dies with "unbound variable" under `set -u`.
echo "Packing ${ZIP}…"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"

echo "Submitting to Apple. This usually takes a few minutes."
SUBMIT_JSON="$OUT_DIR/.notary-submit.json"
set +e
xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait --output-format json > "$SUBMIT_JSON" 2>"$OUT_DIR/.notary-submit.err"
SUBMIT_STATUS=$?
set -e

if [[ $SUBMIT_STATUS -ne 0 && ! -s "$SUBMIT_JSON" ]]; then
  ERR="$(cat "$OUT_DIR/.notary-submit.err" 2>/dev/null || true)"
  case "$ERR" in
    *"HTTP status code: 401"*|*"HTTP status code: 403"*|*Unauthorized*|*"Invalid credentials"*)
      die "Apple rejected the credentials.

$ERR

  - An app-specific password is NOT your Apple ID password. Make one at
    appleid.apple.com -> Sign-In and Security -> App-Specific Passwords.
  - MYNAH_TEAM_ID must be the 10-character team id, visible at
    developer.apple.com/account under Membership.
  - If you use a keychain profile, re-create it: the stored password does not
    survive an Apple ID password change." ;;
    *)
      die "notarytool could not submit the build.

$ERR" ;;
  esac
fi

read -r STATUS SUBMISSION_ID <<<"$(python3 - "$SUBMIT_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
print(result.get("status", "Unknown"), result.get("id", ""))
PY
)"

echo "Apple says: $STATUS (submission $SUBMISSION_ID)"

if [[ "$STATUS" != "Accepted" ]]; then
  echo ""
  echo "The full report from Apple:"
  echo "--------------------------------------------------------------------"
  xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" 2>&1 || true
  echo "--------------------------------------------------------------------"
  cat >&2 <<'GUIDE'

What the common ones mean:

  "The signature does not include a secure timestamp"
      Signed while offline. Get online, re-run scripts/package-app.sh.

  "The executable does not have the hardened runtime enabled"
      A binary was signed without --options runtime. package-app.sh signs every
      executable it stages; if this names something else, that file is being
      added outside the script.

  "The binary is not signed with a valid Developer ID certificate"
      An ad-hoc or Apple Development signature. See SAGE_VOICE_CODESIGN_IDENTITY.

  "The signature of the binary is invalid"
      The file changed after it was signed. The usual cause is signing the outer
      bundle before something inside it. Never re-sign one piece by hand — run
      scripts/package-app.sh, which goes strictly inside out.

  "The binary is not signed"
      A helper got staged after the signing pass. Add it to package-app.sh.

  "You must first sign the relevant contracts online"
      Nothing to do with this build: log in to developer.apple.com and accept
      the updated agreement, then re-submit.
GUIDE
  die "Notarization did not pass. Nothing was stapled; $ZIP is not distributable."
fi

rm -f "$SUBMIT_JSON" "$OUT_DIR/.notary-submit.err"

# ------------------------------------------------------- staple + verify

# The ticket is attached to the .app, not to the zip — a zip cannot hold one.
# The zip made above was only a transport for the upload; the distributable one
# is rebuilt below, from the stapled bundle.
echo "Stapling the ticket to the app…"
xcrun stapler staple "$APP" \
  || die "Apple accepted the build but the ticket would not attach.

This is nearly always a propagation delay — the ticket exists but Apple's
service has not published it yet. Wait a minute and run:
  xcrun stapler staple \"$APP\""

echo "Verifying…"
xcrun stapler validate "$APP" || die "The stapled ticket does not validate. Do not ship this build."

# The real question: would Gatekeeper open it on a Mac that has never seen it?
# This is the check that fails when notarization succeeded but the app is still
# refused in the field.
GATEKEEPER="$(capture spctl --assess --type exec --verbose=4 "$APP")"
case "$GATEKEEPER" in
  *accepted*) echo "Gatekeeper: accepted" ;;
  *)
    echo "$GATEKEEPER" >&2
    die "Gatekeeper refuses this build even though it is notarized and stapled.

Check the 'source=' line above. 'Unnotarized Developer ID' means the ticket did
not attach to what Gatekeeper is looking at — re-staple. Anything else means
the bundle was modified after stapling." ;;
esac

echo "Repacking the stapled app…"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
( cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")" ) > "$ZIP.sha256"

echo ""
echo "Notarized, stapled and accepted by Gatekeeper:"
echo "$APP"
echo "$ZIP"
echo "$ZIP.sha256"
