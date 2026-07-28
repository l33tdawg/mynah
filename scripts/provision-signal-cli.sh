#!/usr/bin/env bash
# Stages the Signal native helper as a release input.
#
# This runs on the build Mac, never the owner's Mac. The resulting binary is
# copied inside Mynah.app and signed with the rest of the bundle, so opening the
# phone screen can proceed directly to a QR code without Homebrew or Terminal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${SAGE_VOICE_SIGNAL_CLI:-$ROOT/vendor/signal/bin/signal-cli}"
EXPECTED_VERSION="${SAGE_VOICE_SIGNAL_CLI_VERSION:-0.14.6}"

die() { echo "error: $*" >&2; exit 1; }

if [[ -x "$DEST" ]]; then
  FOUND="$("$DEST" --version 2>/dev/null || true)"
  [[ "$FOUND" == *"$EXPECTED_VERSION"* ]] \
    || die "vendored signal-cli is '$FOUND'; expected $EXPECTED_VERSION"
  exit 0
fi

SOURCE="$(command -v signal-cli || true)"
if [[ -z "$SOURCE" ]]; then
  BREW="$(command -v brew || true)"
  [[ -n "$BREW" ]] || die \
"signal-cli $EXPECTED_VERSION is not staged and Homebrew is unavailable on this build Mac.
Install the pinned helper on the release machine, then rerun this script."
  NONINTERACTIVE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install signal-cli
  SOURCE="$(command -v signal-cli || true)"
fi

[[ -x "$SOURCE" ]] || die "signal-cli did not become executable after installation"
FOUND="$("$SOURCE" --version 2>/dev/null || true)"
[[ "$FOUND" == *"$EXPECTED_VERSION"* ]] \
  || die "build Mac has '$FOUND'; this release requires signal-cli $EXPECTED_VERSION"

mkdir -p "$(dirname "$DEST")"
cp "$SOURCE" "$DEST"
chmod 0755 "$DEST"
echo "$DEST"
