#!/usr/bin/env bash
# Builds SAGE Voice Bridge.app with SAGE vendored inside it.
#
# The whole point of this script is the codesign order at the bottom. macOS
# requires nested code to be signed BEFORE the bundle that contains it: sign the
# outer bundle first and the later inner signature invalidates it, producing an
# app that launches on the build machine and is refused on every other one.
#
# So: inner helpers, then the nested SAGE.app, then our executable, then the
# outer bundle, then verify --deep --strict, which is the only step that would
# actually catch a mistake in that order.
#
# Ported from QuietType's scripts/package-app.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${SAGE_VOICE_APP_PATH:-$ROOT/dist/SAGE Voice Bridge.app}"

RELEASE_BIN="$ROOT/.build/arm64-apple-macosx/release/sage-voiced"
DEBUG_BIN="$ROOT/.build/arm64-apple-macosx/debug/sage-voiced"

# Ad-hoc by default so a dev build needs no identity. Release passes a real one:
#   SAGE_VOICE_CODESIGN_IDENTITY="Developer ID Application: ..." scripts/package-app.sh
SIGN_IDENTITY="${SAGE_VOICE_CODESIGN_IDENTITY:--}"
# Hardened runtime is required for notarization.
SIGN_OPTIONS="${SAGE_VOICE_CODESIGN_OPTIONS:---options runtime}"
ENTITLEMENTS="${SAGE_VOICE_ENTITLEMENTS:-$ROOT/resources/SageVoiceBridge.entitlements}"

BUNDLE_SAGE="${SAGE_VOICE_BUNDLE_SAGE:-1}"
SAGE_APP_SOURCE="${SAGE_APP_SOURCE:-$ROOT/vendor/SAGE.app}"
SAGE_EXPECTED_BUNDLE_ID="${SAGE_EXPECTED_BUNDLE_ID:-com.sage.brain}"
SAGE_EXPECTED_ARCH="${SAGE_EXPECTED_ARCH:-arm64}"

APP_VERSION="${SAGE_VOICE_VERSION:-}"
APP_BUILD="${SAGE_VOICE_BUILD:-}"
RELEASE_LABEL="${SAGE_VOICE_RELEASE_LABEL:-}"

EXPECTED_BUNDLE_ID="local.sage.voicebridge"

require_sage_app() {
  local sage_app="$1"
  local executable="$sage_app/Contents/MacOS/sage-gui"
  local plist="$sage_app/Contents/Info.plist"

  [[ -d "$sage_app" ]] || { echo "Missing SAGE app bundle: $sage_app" >&2; exit 1; }
  [[ -f "$plist" ]] || { echo "SAGE app is missing Info.plist: $plist" >&2; exit 1; }

  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  if [[ -n "$SAGE_EXPECTED_BUNDLE_ID" && "$bundle_id" != "$SAGE_EXPECTED_BUNDLE_ID" ]]; then
    echo "Unexpected SAGE bundle identifier '$bundle_id'; expected '$SAGE_EXPECTED_BUNDLE_ID'." >&2
    exit 1
  fi

  [[ -x "$executable" ]] || { echo "Bundled SAGE is not runnable: $executable" >&2; exit 1; }

  if [[ -n "$SAGE_EXPECTED_ARCH" ]] && ! file "$executable" | grep -q "$SAGE_EXPECTED_ARCH"; then
    echo "Bundled SAGE executable does not contain '$SAGE_EXPECTED_ARCH': $executable" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- build input

if [[ -x "$RELEASE_BIN" ]]; then
  BIN="$RELEASE_BIN"
elif [[ -x "$DEBUG_BIN" ]]; then
  BIN="$DEBUG_BIN"
  echo "WARN  packaging a DEBUG build; run 'swift build -c release --arch arm64' for a release" >&2
else
  echo "Missing arm64 binary. Run: swift build -c release --arch arm64" >&2
  exit 1
fi

# ---------------------------------------------------------------- lay it out

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"

[[ -n "$APP_VERSION" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
[[ -n "$APP_BUILD" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP/Contents/Info.plist"
[[ -n "$RELEASE_LABEL" ]] && /usr/libexec/PlistBuddy -c "Set :SageVoiceBridgeReleaseLabel $RELEASE_LABEL" "$APP/Contents/Info.plist"

# The bundle id is the key macOS files TCC grants under. Shipping a build with
# the wrong one silently resets microphone and automation permissions for every
# existing owner, who then has to re-grant them with no explanation.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Unexpected bundle identifier '$BUNDLE_ID'; refusing to package because this would reset macOS permissions." >&2
  exit 1
fi

cp "$BIN" "$APP/Contents/MacOS/sage-voiced"
chmod +x "$APP/Contents/MacOS/sage-voiced"

if [[ "$BUNDLE_SAGE" != "0" && "$BUNDLE_SAGE" != "false" ]]; then
  if [[ ! -d "$SAGE_APP_SOURCE" ]]; then
    echo "SAGE.app not vendored at $SAGE_APP_SOURCE — run scripts/vendor-sage.sh first." >&2
    exit 1
  fi
  require_sage_app "$SAGE_APP_SOURCE"
  cp -R "$SAGE_APP_SOURCE" "$APP/Contents/Resources/SAGE.app"
  # Verify the copy, not just the source: cp through a filesystem that drops
  # the executable bit is a real way to ship a bundle that cannot start.
  require_sage_app "$APP/Contents/Resources/SAGE.app"
fi

[[ -f "$ENTITLEMENTS" ]] || { echo "Missing entitlements: $ENTITLEMENTS" >&2; exit 1; }

# ------------------------------------------------------------------ codesign
# Inside out. See the header comment — this order is the script.

if [[ -d "$APP/Contents/Resources/SAGE.app" ]]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" $SIGN_OPTIONS "$APP/Contents/Resources/SAGE.app" >/dev/null
  codesign --verify --deep --strict "$APP/Contents/Resources/SAGE.app"
fi

codesign --force --sign "$SIGN_IDENTITY" $SIGN_OPTIONS \
  --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/sage-voiced" >/dev/null

codesign --force --sign "$SIGN_IDENTITY" $SIGN_OPTIONS \
  --entitlements "$ENTITLEMENTS" "$APP" >/dev/null

codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP"
