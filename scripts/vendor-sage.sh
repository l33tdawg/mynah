#!/usr/bin/env bash
# Vendors SAGE.app into this repo so the app can ship a node inside itself.
#
# This is a BUILD-TIME step, not something a user's machine ever runs. The
# packaging script copies the result into
# SAGE Voice Bridge.app/Contents/Resources/SAGE.app and codesigns it as part of
# our bundle, so it inherits our notarization and launches with no Gatekeeper
# prompt and nothing for the owner to install.
#
# Ported from QuietType's scripts/download-sage-gui.sh, which has shipped this
# arrangement for a while. The verification below is the point of the script:
# everything after the download is refusing to vendor something we cannot
# identify.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${SAGE_GITHUB_REPO:-l33tdawg/sage}"
# Pinned, not `latest`. Two reasons, and the second one is why this line
# changed: a release should vendor the same brain today and in six months,
# and `latest` silently did not even mean latest. This script keeps an
# existing vendored SAGE rather than re-fetching (see the message below),
# so once vendor/SAGE.app was staged, `latest` resolved to whatever was
# already on disk forever. Mynah 2.0.0 shipped 11.17.15 that way, five
# releases behind, and nothing anywhere said so. Bump this deliberately.
TAG="${SAGE_RELEASE_TAG:-v11.18.11}"
OUT="${SAGE_APP_SOURCE:-$ROOT/vendor/SAGE.app}"
EXPECTED_BUNDLE_ID="${SAGE_EXPECTED_BUNDLE_ID:-com.sage.brain}"
# Apple Silicon only: WhisperKit runs on the Neural Engine, so an x86 build
# would be the wrong answer rather than a fallback.
EXPECTED_ARCH="${SAGE_EXPECTED_ARCH:-arm64}"
EXPECTED_SHA256="${SAGE_ASSET_SHA256:-}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sage-voice-vendor.XXXXXX")"
cleanup() {
  if [[ -d "$TMP/mount" ]]; then
    hdiutil detach "$TMP/mount" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# $2 is where the bundle came from: "vendored" for the copy already in the repo,
# "downloaded" for one just fetched. The checks are identical; only the advice
# differs, and the advice is the whole value of the message.
require_sage_app() {
  local sage_app="$1"
  local origin="${2:-downloaded}"
  local executable="$sage_app/Contents/MacOS/sage-gui"
  local plist="$sage_app/Contents/Info.plist"

  [[ -d "$sage_app" ]] || { echo "SAGE.app not found at $sage_app" >&2; exit 1; }
  [[ -f "$plist" ]] || { echo "SAGE.app is missing Info.plist: $plist" >&2; exit 1; }

  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  if [[ -n "$EXPECTED_BUNDLE_ID" && "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Unexpected SAGE bundle identifier '$bundle_id'; expected '$EXPECTED_BUNDLE_ID'." >&2
    exit 1
  fi

  if [[ "$TAG" != "latest" ]]; then
    local version expected_version
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
    expected_version="${TAG#v}"
    if [[ "$version" != "$TAG" && "$version" != "$expected_version" ]]; then
      if [[ "$origin" == "vendored" ]]; then
        # The common case, and the one whose old wording sent the reader off to
        # check the release. Nothing was downloaded: this script found a SAGE
        # already in the repo and stopped, because re-downloading every build
        # would make it non-reproducible. The bundle is simply the previous
        # version, and one variable replaces it.
        cat >&2 <<EOF
The SAGE already vendored at $sage_app is $version, and $TAG was asked for.

Nothing was downloaded — this script keeps an existing vendored SAGE rather than
re-fetching it on every build. To replace it with $TAG:

  SAGE_RELEASE_TAG=$TAG SAGE_FORCE_DOWNLOAD=1 scripts/vendor-sage.sh
EOF
      else
        echo "The SAGE downloaded for $TAG reports version '$version'." >&2
        echo "That is the release's own contents, so check the assets on $TAG"\
             "before vendoring it." >&2
      fi
      exit 1
    fi
  fi

  [[ -x "$executable" ]] || { echo "SAGE.app is not runnable; missing $executable" >&2; exit 1; }

  if [[ -n "$EXPECTED_ARCH" ]] && ! file "$executable" | grep -q "$EXPECTED_ARCH"; then
    echo "SAGE executable does not contain '$EXPECTED_ARCH': $executable" >&2
    exit 1
  fi
}

# Already vendored: verify and stop. Re-downloading on every build would make
# the build non-reproducible and would rate-limit CI.
if [[ -d "$OUT" && "${SAGE_FORCE_DOWNLOAD:-0}" != "1" ]]; then
  require_sage_app "$OUT" vendored
  echo "$OUT"
  exit 0
fi

API_URL="https://api.github.com/repos/$REPO/releases/latest"
if [[ "$TAG" != "latest" ]]; then
  API_URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi

METADATA="$TMP/release.json"
curl -fsSL \
  -H "Accept: application/vnd.github+json" \
  -H "User-Agent: SAGEVoiceBridge-Vendor" \
  "$API_URL" \
  -o "$METADATA"

ASSET_URL="$(python3 - "$METADATA" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    release = json.load(handle)

preferred, fallback = [], []
for asset in release.get("assets", []):
    name = asset.get("name", "").lower()
    url = asset.get("browser_download_url", "")
    if not url or not name.endswith((".dmg", ".zip")):
        continue
    is_macos = "macos" in name or "darwin" in name or name.endswith(".dmg")
    is_arm64 = "arm64" in name or "aarch64" in name
    if not is_macos:
        continue
    fallback.append(url)
    if "sage" in name and is_arm64:
        preferred.append(url)

choice = preferred or fallback
if not choice:
    raise SystemExit("No SAGE macOS DMG/ZIP asset found in release.")
print(choice[0])
PY
)"

ASSET_NAME="$(basename "${ASSET_URL%%\?*}")"
ASSET="$TMP/$ASSET_NAME"
curl -fL \
  -H "Accept: application/octet-stream" \
  -H "User-Agent: SAGEVoiceBridge-Vendor" \
  "$ASSET_URL" \
  -o "$ASSET"

if [[ -n "$EXPECTED_SHA256" ]]; then
  ACTUAL_SHA256="$(shasum -a 256 "$ASSET" | awk '{print $1}')"
  EXPECTED_LOWER="$(printf "%s" "$EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
  if [[ "$ACTUAL_SHA256" != "$EXPECTED_LOWER" ]]; then
    echo "SAGE asset checksum mismatch for $ASSET_NAME" >&2
    echo "Expected: $EXPECTED_LOWER" >&2
    echo "Actual:   $ACTUAL_SHA256" >&2
    exit 1
  fi
fi

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"

case "$(printf "%s" "$ASSET_NAME" | tr '[:upper:]' '[:lower:]')" in
  *.dmg)
    mkdir -p "$TMP/mount"
    hdiutil attach "$ASSET" -nobrowse -readonly -mountpoint "$TMP/mount" -quiet
    SAGE_APP="$(find "$TMP/mount" -maxdepth 3 -name "SAGE.app" -type d | head -n 1)"
    [[ -n "$SAGE_APP" ]] || { echo "SAGE.app not found in $ASSET_NAME" >&2; exit 1; }
    cp -R "$SAGE_APP" "$OUT"
    ;;
  *.zip)
    unzip -q "$ASSET" -d "$TMP/unzip"
    SAGE_APP="$(find "$TMP/unzip" -maxdepth 4 -name "SAGE.app" -type d | head -n 1)"
    [[ -n "$SAGE_APP" ]] || { echo "SAGE.app not found in $ASSET_NAME" >&2; exit 1; }
    cp -R "$SAGE_APP" "$OUT"
    ;;
  *)
    echo "Unsupported SAGE asset: $ASSET_NAME" >&2
    exit 1
    ;;
esac

require_sage_app "$OUT"
echo "$OUT"
