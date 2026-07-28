#!/usr/bin/env bash
# Builds Mynah.app: the GUI, the CLI beside it, and SAGE vendored inside it.
#
# This script does NOT compile anything. It packages what is already in
# .build/arm64-apple-macosx/release, so run this first:
#
#   swift build -c release --arch arm64
#
# The whole point of the bottom half is the codesign order. macOS requires
# nested code to be signed BEFORE the bundle containing it, because the outer
# signature seals a hash of everything inside: sign the outer bundle first and
# the next inner signature silently invalidates it. The result is the worst
# possible failure mode — it launches fine on the machine that built it,
# because that machine already trusts the developer, and is refused on every
# other Mac with "the application is damaged".
#
# So, strictly inside out:
#   1. helpers inside SAGE.app, then SAGE.app itself
#   2. our CLI helper in Contents/MacOS
#   3. our main executable
#   4. the outer bundle
#   5. codesign --verify --deep --strict, which is the only step that would
#      actually catch a mistake in that order
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${SAGE_VOICE_APP_PATH:-$ROOT/dist/Mynah.app}"

BUILD_DIR="$ROOT/.build/arm64-apple-macosx"

# What the owner double-clicks, and what CFBundleExecutable must name.
APP_PRODUCT="Mynah"
# Ships alongside it as the debugging surface: same SageVoiceCore, no window.
# Not a second copy of the app — it is how a problem gets diagnosed over a call
# without asking a non-technical owner to read a log.
CLI_PRODUCT="sage-voiced"

# Ad-hoc by default so a dev build needs no identity. Release passes a real one:
#   SAGE_VOICE_CODESIGN_IDENTITY="Developer ID Application: ..." scripts/package-app.sh
SIGN_IDENTITY="${SAGE_VOICE_CODESIGN_IDENTITY:--}"
# Hardened runtime is required for notarization.
SIGN_OPTIONS="${SAGE_VOICE_CODESIGN_OPTIONS:---options runtime}"
ENTITLEMENTS="${SAGE_VOICE_ENTITLEMENTS:-$ROOT/resources/SageVoiceBridge.entitlements}"
ICON_SOURCE="${SAGE_VOICE_ICON:-$ROOT/resources/Mynah.icns}"

BUNDLE_SAGE="${SAGE_VOICE_BUNDLE_SAGE:-1}"
SAGE_APP_SOURCE="${SAGE_APP_SOURCE:-$ROOT/vendor/SAGE.app}"
SAGE_EXPECTED_BUNDLE_ID="${SAGE_EXPECTED_BUNDLE_ID:-com.sage.brain}"
SAGE_EXPECTED_ARCH="${SAGE_EXPECTED_ARCH:-arm64}"

# Speech engines are release inputs, not things an owner installs. They are
# staged before signing so Gatekeeper verifies the exact helpers we launch.
ASR_ROOT="${SAGE_VOICE_ASR_ROOT:-$ROOT/vendor/asr}"
ARGMAX_CLI_SOURCE="${SAGE_VOICE_ARGMAX_CLI:-$ASR_ROOT/bin/argmax-cli}"
WHISPER_CLI_SOURCE="${SAGE_VOICE_WHISPER_CLI:-$ASR_ROOT/bin/whisper-cli}"
WHISPERKIT_MODEL_SOURCE="${SAGE_VOICE_WHISPERKIT_MODEL:-$ASR_ROOT/models/openai_whisper-large-v3-v20240930_626MB}"
WHISPER_CPP_MODEL_SOURCE="${SAGE_VOICE_WHISPER_CPP_MODEL:-$ASR_ROOT/models/ggml-small.en.bin}"
REQUIRE_ASR_ASSETS="${SAGE_VOICE_REQUIRE_ASR_ASSETS:-1}"

APP_VERSION="${SAGE_VOICE_VERSION:-}"
APP_BUILD="${SAGE_VOICE_BUILD:-}"
RELEASE_LABEL="${SAGE_VOICE_RELEASE_LABEL:-}"

EXPECTED_BUNDLE_ID="local.sage.voicebridge"

# A real identity gets a trusted timestamp, which notarization requires and
# which is what keeps the signature valid after the certificate expires. Ad-hoc
# signing cannot be timestamped at all, so asking for one there is just an
# error message on a dev build.
TIMESTAMP_OPT="--timestamp"
[[ "$SIGN_IDENTITY" == "-" ]] && TIMESTAMP_OPT=""

die() { echo "$*" >&2; exit 1; }

# Reads a command's output into a string instead of piping it into grep.
#
# `set -o pipefail` is on, and `grep -q` exits the moment it matches, which
# sends SIGPIPE to whatever is upstream. The pipeline then reports 141 and the
# check fails *because it succeeded* — non-deterministically, depending on
# whether the writer had already finished. Every content check below therefore
# captures first and matches second.
capture() { "$@" 2>&1 || true; }

# ------------------------------------------------------------------ signing

# sign <path> [extra codesign args…]
#
# $SIGN_OPTIONS and $TIMESTAMP_OPT are intentionally unquoted: both hold
# multiple flags that must word-split.
sign() {
  local target="$1"; shift
  codesign --force --sign "$SIGN_IDENTITY" $SIGN_OPTIONS $TIMESTAMP_OPT "$@" "$target" >/dev/null
}

# Signs one app bundle inside out: its helper executables, then its main
# executable, then the bundle.
#
# Deliberately not `codesign --deep`. Apple describes --deep as an emergency
# repair tool, and it is: it applies one set of flags to everything it finds,
# including things that should not have them, and it silently succeeds on
# layouts it does not really understand. Enumerating is longer and is the
# reason the failure below can exist at all.
sign_app_bundle() {
  local bundle="$1"
  local macos="$bundle/Contents/MacOS"
  local main_name
  main_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"

  # A nested framework or XPC service needs its own inside-out pass with its own
  # rules, and guessing at one produces a bundle that verifies here and is
  # rejected by Gatekeeper. Refuse instead, loudly enough to be fixed.
  local nested
  nested="$(find "$bundle" -mindepth 1 \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print -quit)"
  [[ -z "$nested" ]] || die "Unhandled nested bundle inside $(basename "$bundle"): $nested
This script only knows how to sign flat helper executables. Teach sign_app_bundle
about this layout before shipping it."

  # Helpers first, main executable last: same rule as the outer bundle, one
  # level down.
  local helper
  while IFS= read -r helper; do
    [[ -n "$helper" ]] || continue
    [[ "$(basename "$helper")" != "$main_name" ]] || continue
    sign "$helper"
  done < <(find "$macos" -type f -perm -u+x | sort)

  [[ -f "$macos/$main_name" ]] || die "$(basename "$bundle") declares CFBundleExecutable '$main_name' but there is no such file in Contents/MacOS."
  sign "$macos/$main_name"
  sign "$bundle"
  codesign --verify --deep --strict "$bundle"
}

# ---------------------------------------------------------------- SAGE input

require_sage_app() {
  local sage_app="$1"
  local executable="$sage_app/Contents/MacOS/sage-gui"
  local plist="$sage_app/Contents/Info.plist"

  [[ -d "$sage_app" ]] || die "Missing SAGE app bundle: $sage_app"
  [[ -f "$plist" ]] || die "SAGE app is missing Info.plist: $plist"

  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  if [[ -n "$SAGE_EXPECTED_BUNDLE_ID" && "$bundle_id" != "$SAGE_EXPECTED_BUNDLE_ID" ]]; then
    die "Unexpected SAGE bundle identifier '$bundle_id'; expected '$SAGE_EXPECTED_BUNDLE_ID'."
  fi

  [[ -x "$executable" ]] || die "Bundled SAGE is not runnable: $executable"

  if [[ -n "$SAGE_EXPECTED_ARCH" ]]; then
    local described
    described="$(capture file "$executable")"
    [[ "$described" == *"$SAGE_EXPECTED_ARCH"* ]] \
      || die "Bundled SAGE executable does not contain '$SAGE_EXPECTED_ARCH': $executable"
  fi
}

# ---------------------------------------------------------------- build input

# resolve_product <name> -> path, preferring release
resolve_product() {
  local name="$1"
  if [[ -x "$BUILD_DIR/release/$name" ]]; then
    echo "$BUILD_DIR/release/$name"
  elif [[ -x "$BUILD_DIR/debug/$name" ]]; then
    echo "WARN  packaging a DEBUG build of $name" >&2
    echo "$BUILD_DIR/debug/$name"
  else
    die "Missing arm64 binary for $name. Run: swift build -c release --arch arm64"
  fi
}

APP_BIN="$(resolve_product "$APP_PRODUCT")"
CLI_BIN="$(resolve_product "$CLI_PRODUCT")"

[[ -f "$ENTITLEMENTS" ]] || die "Missing entitlements: $ENTITLEMENTS"
[[ -f "$ICON_SOURCE" ]] || die "Missing app icon: $ICON_SOURCE
Run scripts/make-icon.sh and commit the result. Shipping without it gives the
owner a blank sheet of paper in their Dock."

# ---------------------------------------------------------------- lay it out

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"

# Some of Finder and LaunchServices still reads PkgInfo, and it costs 8 bytes.
printf 'APPL????' > "$APP/Contents/PkgInfo"

[[ -n "$APP_VERSION" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
[[ -n "$APP_BUILD" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP/Contents/Info.plist"
[[ -n "$RELEASE_LABEL" ]] && /usr/libexec/PlistBuddy -c "Set :SageVoiceBridgeReleaseLabel $RELEASE_LABEL" "$APP/Contents/Info.plist"

# The bundle id is the key macOS files TCC grants under. Shipping a build with
# the wrong one silently resets microphone and automation permissions for every
# existing owner, who then has to re-grant them with no explanation.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  die "Unexpected bundle identifier '$BUNDLE_ID'; refusing to package because this would reset macOS permissions."
fi

# Both binaries live in Contents/MacOS. The GUI is the bundle executable; the
# CLI is a helper next to it, which is also where Bundle.url(forAuxiliaryExecutable:)
# looks — the same lookup LocalASRDiscovery uses for whisper-cli.
cp "$APP_BIN" "$APP/Contents/MacOS/$APP_PRODUCT"
cp "$CLI_BIN" "$APP/Contents/MacOS/$CLI_PRODUCT"
chmod +x "$APP/Contents/MacOS/$APP_PRODUCT" "$APP/Contents/MacOS/$CLI_PRODUCT"

if [[ -x "$ARGMAX_CLI_SOURCE" ]]; then
  cp "$ARGMAX_CLI_SOURCE" "$APP/Contents/MacOS/argmax-cli"
  chmod +x "$APP/Contents/MacOS/argmax-cli"
elif [[ "$REQUIRE_ASR_ASSETS" == "1" || "$REQUIRE_ASR_ASSETS" == "true" ]]; then
  die "Required WhisperKit helper is missing: $ARGMAX_CLI_SOURCE
Run scripts/provision-asr-assets.sh before packaging."
fi

if [[ -x "$WHISPER_CLI_SOURCE" ]]; then
  cp "$WHISPER_CLI_SOURCE" "$APP/Contents/MacOS/whisper-cli"
  chmod +x "$APP/Contents/MacOS/whisper-cli"
elif [[ "$REQUIRE_ASR_ASSETS" == "1" || "$REQUIRE_ASR_ASSETS" == "true" ]]; then
  die "Required whisper.cpp fallback is missing: $WHISPER_CLI_SOURCE
Run scripts/provision-asr-assets.sh before packaging."
fi

if [[ -d "$WHISPERKIT_MODEL_SOURCE" ]]; then
  for item in AudioEncoder.mlmodelc MelSpectrogram.mlmodelc TextDecoder.mlmodelc \
      config.json generation_config.json tokenizer.json tokenizer_config.json
  do
    [[ -e "$WHISPERKIT_MODEL_SOURCE/$item" ]] \
      || die "WhisperKit model is incomplete; missing $WHISPERKIT_MODEL_SOURCE/$item"
  done
  mkdir -p "$APP/Contents/Resources/WhisperKit"
  cp -R "$WHISPERKIT_MODEL_SOURCE" "$APP/Contents/Resources/WhisperKit/"
elif [[ "$REQUIRE_ASR_ASSETS" == "1" || "$REQUIRE_ASR_ASSETS" == "true" ]]; then
  die "Required WhisperKit model is missing: $WHISPERKIT_MODEL_SOURCE
Run scripts/provision-asr-assets.sh before packaging."
fi

if [[ -f "$WHISPER_CPP_MODEL_SOURCE" ]]; then
  mkdir -p "$APP/Contents/Resources/Models"
  cp "$WHISPER_CPP_MODEL_SOURCE" "$APP/Contents/Resources/Models/ggml-small.en.bin"
elif [[ "$REQUIRE_ASR_ASSETS" == "1" || "$REQUIRE_ASR_ASSETS" == "true" ]]; then
  die "Required whisper.cpp fallback model is missing: $WHISPER_CPP_MODEL_SOURCE
Run scripts/provision-asr-assets.sh before packaging."
fi

# A plist that names a file that is not there is a bundle that opens nothing at
# all, with no error the owner can see. Check both directions.
DECLARED_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[[ "$DECLARED_EXEC" == "$APP_PRODUCT" ]] || die "CFBundleExecutable is '$DECLARED_EXEC' but this script stages '$APP_PRODUCT' as the app. Double-clicking would open nothing."

cp "$ICON_SOURCE" "$APP/Contents/Resources/Mynah.icns"
DECLARED_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
[[ -f "$APP/Contents/Resources/${DECLARED_ICON%.icns}.icns" ]] || die "CFBundleIconFile is '$DECLARED_ICON' but no such icns was staged."

if [[ "$BUNDLE_SAGE" != "0" && "$BUNDLE_SAGE" != "false" ]]; then
  [[ -d "$SAGE_APP_SOURCE" ]] || die "SAGE.app not vendored at $SAGE_APP_SOURCE — run scripts/vendor-sage.sh first."
  require_sage_app "$SAGE_APP_SOURCE"
  cp -R "$SAGE_APP_SOURCE" "$APP/Contents/Resources/SAGE.app"
  # Verify the copy, not just the source: cp through a filesystem that drops
  # the executable bit is a real way to ship a bundle that cannot start.
  require_sage_app "$APP/Contents/Resources/SAGE.app"
fi

# Quarantine flags and Finder metadata that arrived with the vendored bundle are
# resources codesign will try to seal, and it fails on some of them with a
# message about resource forks that names no file.
xattr -cr "$APP"

# ------------------------------------------------------------------ codesign
# Inside out. See the header comment — this order is the script.

# 1. The nested app, deepest first.
if [[ -d "$APP/Contents/Resources/SAGE.app" ]]; then
  # No entitlements: SAGE is a separate process with its own job, and it has no
  # business holding this app's microphone permission.
  sign_app_bundle "$APP/Contents/Resources/SAGE.app"
fi

# 2. Our CLI helper. Also no entitlements — it never opens an audio device.
[[ ! -f "$APP/Contents/MacOS/argmax-cli" ]] || sign "$APP/Contents/MacOS/argmax-cli"
[[ ! -f "$APP/Contents/MacOS/whisper-cli" ]] || sign "$APP/Contents/MacOS/whisper-cli"
sign "$APP/Contents/MacOS/$CLI_PRODUCT"

# 3. The main executable. Entitlements attach here and to the bundle below;
#    this is also the last chance to fail before a signature exists.
sign "$APP/Contents/MacOS/$APP_PRODUCT" --entitlements "$ENTITLEMENTS"

# 4. The outer bundle, which seals everything above.
sign "$APP" --entitlements "$ENTITLEMENTS"

# ------------------------------------------------------------------- verify

codesign --verify --deep --strict --verbose=2 "$APP"

# --verify says the seals match. It does not say the entitlements survived, and
# a signature that quietly dropped the microphone entitlement produces an app
# that is killed the first time the owner holds the talk button.
GRANTED="$(capture codesign --display --entitlements :- "$APP")"
[[ "$GRANTED" == *"com.apple.security.device.audio-input"* ]] \
  || die "The signed bundle has no microphone entitlement. Check $ENTITLEMENTS."

# Notarization rejects any executable in the bundle without the hardened
# runtime, and it rejects it *after* the upload, minutes later. Catch it here.
for binary in \
  "$APP/Contents/MacOS/$APP_PRODUCT" \
  "$APP/Contents/MacOS/$CLI_PRODUCT" \
  "$APP/Contents/MacOS/argmax-cli" \
  "$APP/Contents/MacOS/whisper-cli" \
  "$APP/Contents/Resources/SAGE.app/Contents/MacOS/sage-gui" \
  "$APP/Contents/Resources/SAGE.app/Contents/MacOS/sage-tray"
do
  [[ -f "$binary" ]] || continue
  DESCRIBED="$(capture codesign --display --verbose=2 "$binary")"
  [[ "$DESCRIBED" == *"flags="*"runtime"* ]] || die \
"$(basename "$binary") is not signed with the hardened runtime; notarization
would reject this build. Set SAGE_VOICE_CODESIGN_OPTIONS to '--options runtime'
(that is the default — something overrode it)."
done

echo "$APP"
