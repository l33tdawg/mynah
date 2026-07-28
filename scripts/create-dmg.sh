#!/usr/bin/env bash
# Builds the distributable disk image from an already-packaged, already-signed
# Mynah.app.
#
# Deliberately does NOT sign or notarize the app — scripts/package-app.sh owns
# the signing order, and doing it twice is how a bundle ends up with a stale
# inner signature that only fails on someone else's Mac. This step wraps what it
# is given and refuses if that is not ready.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${SAGE_VOICE_APP_PATH:-$ROOT/dist/Mynah.app}"
SIGN_IDENTITY="${SAGE_VOICE_CODESIGN_IDENTITY:-}"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$APP" ]] || die "no app bundle at $APP
Run scripts/package-app.sh first."

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION="${MYNAH_VERSION:-$(plist CFBundleShortVersionString)}"
BUILD="${MYNAH_BUILD:-$(plist CFBundleVersion)}"
[[ -n "$VERSION" ]] || die "no CFBundleShortVersionString in $APP/Contents/Info.plist"

LABEL="${MYNAH_RELEASE_LABEL:-}"
SUFFIX=""
VOLUME_SUFFIX=""
if [[ -n "$LABEL" ]]; then
  SUFFIX="-$LABEL"
  VOLUME_SUFFIX=" $LABEL"
fi

DMG_NAME="Mynah-${VERSION}${SUFFIX}-macOS-arm64.dmg"
DMG="$ROOT/dist/$DMG_NAME"
TMP_DMG="$ROOT/dist/.tmp-$DMG_NAME"
STAGING="$ROOT/dist/dmg-staging"

# The app must already be signed and sealed. Shipping an unsigned or broken
# bundle inside a signed DMG passes every check here and fails on first launch
# for the person who downloaded it, which is the worst place to find out.
codesign --verify --deep --strict "$APP" \
  || die "$APP is not correctly signed — run scripts/package-app.sh"

rm -rf "$STAGING" "$DMG" "$TMP_DMG"
mkdir -p "$STAGING" "$ROOT/dist"
cp -R "$APP" "$STAGING/Mynah.app"
# The drag-to-install target. Without it the window is a single icon and the
# owner is expected to know what to do with it.
ln -s /Applications "$STAGING/Applications"

# Licences travel with the disk image, not only inside the app.
#
# Most of what Mynah bundles is satisfied by the credit in its About panel.
# signal-cli is not: it is GPL 3.0, it ships unmodified inside the app, and
# whoever receives this disk image is entitled to its source. Mynah runs it as a
# separate process over a socket, so nothing of Mynah's own becomes copyleft —
# but the obligation to offer source travels with the copy, and a notice only
# reachable by launching the app is a poor way to discharge it.
LICENCES="$STAGING/Licences"
mkdir -p "$LICENCES"
cat > "$LICENCES/README.txt" <<'NOTICE'
Mynah bundles software written by other people.

Every component and its licence is listed in the app under Settings -> About.

signal-cli (https://github.com/AsamK/signal-cli) is licensed under the GNU
General Public License version 3 and is included here unmodified. You are
entitled to its complete corresponding source code. It is available from the
address above, and on request from the contact address shown in Settings ->
About.

The full text of the GPL version 3 is in GPL-3.0.txt beside this file.
NOTICE

if [[ -f "$ROOT/resources/licences/GPL-3.0.txt" ]]; then
  cp "$ROOT/resources/licences/GPL-3.0.txt" "$LICENCES/GPL-3.0.txt"
else
  die "resources/licences/GPL-3.0.txt is missing.
A disk image containing signal-cli must carry the GPL text it is distributed under."
fi

hdiutil create -volname "Mynah ${VERSION}${VOLUME_SUFFIX}" -srcfolder "$STAGING" \
  -ov -format UDRW "$TMP_DMG" >/dev/null
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$STAGING" "$TMP_DMG"

# A signed DMG is what lets Gatekeeper name the developer before the disk image
# is even opened. Skipped for an ad-hoc local build, which cannot be notarized
# anyway.
if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" >/dev/null
fi

hdiutil verify "$DMG" >/dev/null

# Relative path inside the checksum file, so `shasum -c` works from the
# directory the owner downloaded into rather than only from this machine.
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" ) > "$DMG.sha256"

echo "$DMG"
echo "$DMG.sha256"
