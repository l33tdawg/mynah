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
#
# 11.18.14 -> 11.18.22 on 20 Aug 2026. The hold at .14 was the owner's — "we
# wait for next sage release before we vendor in a new one" — and eight
# releases have shipped since. .22 is the newest published, checked by sorting
# the releases API on published_at rather than trusting its order, which does
# NOT return newest first and once made 11.17.5 look newer than 11.18.11. It is
# also exactly what is installed on the build Mac, so the vendored brain and the
# one the appliance actually runs are the same build for once.
#
# 11.18.22 -> 11.18.25 on 21 Aug 2026, cutting 2.3.4, and the floor matters more
# than the newness. That release gives the model `sage_message_handoff`, whose
# own schema says "Pre-v11.18.24 federated claims are surfaced as legacy" — so
# .22 would have shipped a tool that cannot complete a federated handoff, which
# is the exact recovery the owner asked for. Anything below .24 is now wrong,
# not merely old.
#
# .25 rather than the .24 that was verified end to end four hours earlier:
# three SAGE releases landed inside sixteen hours, and pinning the newest at the
# moment of the cut is what stops Mynah shipping a brain that was superseded
# while its DMG uploaded. Sorted on published_at, again, not on API order.
#
# 11.18.25 -> 11.18.27 on 22 Aug 2026, cutting 2.4.0. Two releases had landed
# since the .25 pin and neither was noticed by anything in this repository —
# .26 the same afternoon 2.3.6 shipped. The tell was `notarytool history`, run
# only to check that the notary credential was alive, which listed
# SAGE-v11.18.27-macOS-arm64.dmg accepted the previous evening. That is twice
# now that a diagnostic aimed at something else has been the only thing to catch
# a stale pin, which says the checking should not depend on somebody reading the
# whole of an unrelated command's output.
#
# Both releases were read against `BrainPrompts.voiceToolAllowlist` before
# bumping, because a SAGE release is what stales the exclusions there and
# nothing re-reads them: .26 is dependency bumps plus "bind tokens to approved
# managed identities", .27 discloses domain index-completeness on an empty
# recall. Neither offers a tool or retires a reason, so the one remaining
# deliberate exclusion — `sage_message_replies`, withheld because
# `sage_message_history(folder:"outbox")` already answers the same question —
# still stands. Recorded so the next bump knows this was checked rather than
# assumed.
#
# The floor from the .25 note is unchanged and still binding: anything below
# .24 ships a `sage_message_handoff` that cannot finish a federated handoff.
#
# Re-vendoring requires SAGE_FORCE_DOWNLOAD=1. Changing this line alone does
# nothing while a bundle is already staged, which is the whole trap above.
TAG="${SAGE_RELEASE_TAG:-v11.18.27}"
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

# **Is the pin behind? Asked here rather than left to be noticed.**
#
# Twice now the only thing that caught a stale pin was `notarytool history`, run
# to check the notary credential was alive, listing SAGE's own DMGs in passing.
# That is luck wearing the costume of a process: 2.3.6 shipped .25 the same
# afternoon .26 was published, and 2.4.0 nearly shipped .25 with .27 already
# out. The block above says "bump this deliberately", and a comment cannot check
# its own condition — the same lesson `BrainPrompts` learned when an exclusion
# wrote down its own expiry trigger, the trigger fired, and nothing was watching.
#
# Modelled on scripts/assert-test-run.sh's rot check: rot arrives as a build
# failure carrying the new number rather than as a silent hole. It runs before
# both paths below, because force-downloading a stale TAG is still stale — which
# is exactly the near-miss this is written for.
#
# **Unreachable is not stale.** No network, a rate limit, or an API answering
# something other than a release list all say "could not check" and continue. A
# release that cannot be cut because GitHub is down is a worse failure than the
# one this prevents.
#
# Sorted on published_at, never on API order, for the reason the block above
# gives: this endpoint once returned 11.17.5 ahead of 11.18.11.
newest_published_tag() {
  local json="$TMP/releases.json"
  # `${auth[@]+...}` rather than a bare `"${auth[@]}"`. Under `set -u` an empty
  # array is an unbound variable in bash 3.2, which is what /bin/bash still is on
  # macOS — and the failure lands inside the `|| return 1` below, so the check
  # reports "could not reach the API" and waves the build through. A guard that
  # silently does not run is precisely what this replaced, and it did exactly
  # that the first time it was run.
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL --max-time 20 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: SAGEVoiceBridge-Vendor" \
    ${auth[@]+"${auth[@]}"} \
    "https://api.github.com/repos/$REPO/releases?per_page=100" \
    -o "$json" 2>/dev/null || return 1
  python3 -c 'import json,sys
releases = json.load(open(sys.argv[1]))
if not isinstance(releases, list):
    raise SystemExit(1)
published = [r for r in releases if not r.get("draft") and r.get("published_at")]
if not published:
    raise SystemExit(1)
print(max(published, key=lambda r: r["published_at"])["tag_name"])' "$json" 2>/dev/null || return 1
}

if [[ "$TAG" != "latest" && "${SAGE_ALLOW_STALE_PIN:-0}" != "1" ]]; then
  if NEWEST="$(newest_published_tag)" && [[ -n "$NEWEST" ]]; then
    if [[ "$NEWEST" != "$TAG" ]]; then
      cat >&2 <<MSG
error: this repository pins SAGE $TAG and $NEWEST is the newest published release.

Bump it deliberately, in scripts/vendor-sage.sh, and re-vendor:

  TAG="\${SAGE_RELEASE_TAG:-$NEWEST}"
  SAGE_FORCE_DOWNLOAD=1 bash scripts/vendor-sage.sh

SAGE_FORCE_DOWNLOAD=1 is not optional. This script keeps an already-staged
bundle, so changing the tag alone leaves the old brain in vendor/ and says
nothing — which is how Mynah 2.0.0 shipped a brain five releases behind.

Read the new release notes against BrainPrompts.voiceToolAllowlist first. A SAGE
release is what makes the exclusions there go stale, nothing re-reads them, and
the owner finds out by being told a tool does not exist.

If shipping the older brain is deliberate — the owner has held a pin before, and
there is a floor at 11.18.24 that matters more than newness — say so rather than
editing this check away:

  SAGE_ALLOW_STALE_PIN=1 bash scripts/vendor-sage.sh
MSG
      exit 1
    fi
    echo "SAGE pin $TAG is the newest published release."
  else
    # Said out loud, because a check that silently did not run is the thing this
    # replaced.
    echo "note: could not reach the GitHub releases API, so whether $TAG is still" >&2
    echo "      the newest published SAGE was not checked." >&2
  fi
fi

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
