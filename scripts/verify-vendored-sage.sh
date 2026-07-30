#!/usr/bin/env bash
# Checks that the vendored SAGE is one Mynah is allowed to start.
#
# `vendor-sage.sh` proves the bundle is genuine SAGE — right identifier, right
# architecture, right digest. This proves something different and later: that
# the build inside it carries the first-party companion contract Mynah depends
# on, and is new enough that its Companion can actually recall.
#
# Both questions have already been answered wrongly by inspection alone. The
# vendored 11.14.1 looked fine and contained no `SAGE_VENDORED_AGENT_KEY_FILE`
# string at all — it would have ignored the contract and minted chains that can
# never be given one, because SAGE refuses to retrofit it. And 11.15.1 seeded a
# correct app-v23 genesis, reported its Companion ready and committed a first
# memory at height 8, while every read failed with "Memory classification state
# is unavailable" at heights 8 and 13 alike.
#
# So this asserts the floor by version AND the contract by symbol. Run it after
# every `vendor-sage.sh`, before packaging.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/vendor/SAGE.app}"
EXE="$APP/Contents/MacOS/sage-gui"
PLIST="$APP/Contents/Info.plist"

# Must match SageNodeSupervisor.minimumBootstrapCapableVersion. Two places, and
# the Swift one is what actually gates starting a node at runtime — this is the
# build-time guard that stops a DMG being cut against a bundle the app would
# then refuse to start.
MIN_MAJOR=11
MIN_MINOR=16

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

[[ -d "$APP" ]] || fail "no vendored SAGE.app at $APP (run scripts/vendor-sage.sh)"
[[ -x "$EXE" ]] || fail "vendored SAGE is not runnable: $EXE"

echo "Verifying $APP"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
[[ -n "$version" ]] || fail "vendored SAGE has no CFBundleShortVersionString"

major="${version%%.*}"
rest="${version#*.}"
minor="${rest%%.*}"
[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || fail "unparseable vendored version '$version'"

if (( major < MIN_MAJOR )) || { (( major == MIN_MAJOR )) && (( minor < MIN_MINOR )); }; then
  fail "vendored SAGE $version is below the $MIN_MAJOR.$MIN_MINOR floor.
      Below it the Companion either cannot be enrolled at genesis (<= 11.14.x)
      or is enrolled but cannot recall (11.15.x). SageNodeSupervisor refuses to
      start such a node, so this DMG would ship a brain that never answers."
fi
ok "version $version is at or above the $MIN_MAJOR.$MIN_MINOR floor"

# Symbols, not just a version string: a renamed or rebuilt bundle can carry any
# version it likes. These are the two halves of the contract the app relies on.
strings -a "$EXE" | grep -q "SAGE_VENDORED_AGENT_KEY_FILE" \
  || fail "vendored SAGE does not read SAGE_VENDORED_AGENT_KEY_FILE — it would
      ignore the companion contract and mint an un-bootstrappable chain."
ok "reads the vendored companion bootstrap environment"

strings -a "$EXE" | grep -q "first-party app-v23 companion" \
  || fail "vendored SAGE has no app-v23 companion readiness path"
ok "carries the app-v23 companion readiness gate"

# Advisory rather than fatal: app-v24 is what makes the Companion become ready
# after activation, but the exact string is SAGE's to name and a rename here
# should not block a release on its own.
if strings -a "$EXE" | grep -q "app-v24"; then
  ok "carries app-v24"
else
  echo "  WARNING: no app-v24 string found. 11.16+ is expected to govern"
  echo "           Companion readiness through app-v24 — confirm with the SAGE"
  echo "           team before shipping this bundle."
fi

id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
[[ "$id" == "com.sage.brain" ]] || fail "unexpected bundle identifier '$id'"
ok "bundle identifier $id"

echo "Vendored SAGE $version is fit to ship."
