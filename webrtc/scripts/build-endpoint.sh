#!/bin/bash
#
# Builds the call endpoint for the appliance.
#
# There is a trap here worth naming. The endpoint links a static libopus, so it
# needs cgo, so it can only be built for one architecture at a time — and a Go
# toolchain installed under Rosetta reports amd64 on an Apple Silicon Mac and
# will happily produce an Intel binary that cannot link an arm64 archive. The
# error it gives is a hundred lines of "ignoring file ... found architecture
# arm64", which names the symptom and not the cause.
#
# So the architecture is explicit here rather than inherited, and the result is
# checked before it is handed over. The appliance is an M2 Mac mini; anything
# that is not arm64 is wrong regardless of what the toolchain defaults to.
#
#   ./scripts/build-endpoint.sh [output-path]
set -euo pipefail

ARCH="${ARCH:-arm64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/../.build/sage-voice-webrtc}"

ARCH="$ARCH" "$ROOT/scripts/build-opus.sh"

mkdir -p "$(dirname "$OUTPUT")"
cd "$ROOT"

echo "building the endpoint for $ARCH"
CGO_ENABLED=1 \
GOOS=darwin \
GOARCH="$ARCH" \
CC="clang -arch $ARCH" \
go build -trimpath -o "$OUTPUT" .

produced="$(lipo -info "$OUTPUT")"
if [[ "$produced" != *"$ARCH"* ]]; then
  echo "error: built $produced, wanted $ARCH" >&2
  exit 1
fi
echo "built $produced"
