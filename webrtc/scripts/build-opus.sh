#!/bin/bash
#
# Builds a static libopus for the appliance.
#
# The call endpoint has to decode what the phone sends and encode what the agent
# says, and there is no Opus codec in macOS. A dynamic library would mean the
# appliance depending on Homebrew — which the Mac mini does not have and should
# not need — so this produces a static archive that links into the binary. One
# file gets deployed and it works on a machine with no toolchain at all.
#
# Not vendored as a binary: an .a in a git repository is unreviewable, and its
# provenance is whoever committed it. This fetches from upstream and checks the
# hash, so what goes into the appliance is verifiable from the source tree.
#
#   ./scripts/build-opus.sh          # builds for this machine's architecture
#   ARCH=arm64 ./scripts/build-opus.sh
set -euo pipefail

VERSION="1.5.2"
# From downloads.xiph.org. Pinned rather than trusted per-fetch: this archive is
# compiled and shipped inside a signed appliance, so a substituted tarball is a
# substituted appliance.
SHA256="65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1"

ARCH="${ARCH:-$(uname -m)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$ROOT/third_party/opus"
BUILD="$ROOT/.opus-build"

if [ -f "$PREFIX/lib/libopus.a" ]; then
  existing="$(lipo -info "$PREFIX/lib/libopus.a" 2>/dev/null || true)"
  if [[ "$existing" == *"$ARCH"* ]]; then
    echo "libopus for $ARCH is already built at $PREFIX"
    exit 0
  fi
  echo "rebuilding: existing archive is not $ARCH"
fi

mkdir -p "$BUILD"
cd "$BUILD"

if [ ! -f "opus-$VERSION.tar.gz" ]; then
  echo "fetching opus $VERSION"
  curl -fsSL --max-time 300 \
    "https://downloads.xiph.org/releases/opus/opus-$VERSION.tar.gz" \
    -o "opus-$VERSION.tar.gz"
fi

echo "verifying"
actual="$(shasum -a 256 "opus-$VERSION.tar.gz" | cut -d' ' -f1)"
if [ "$actual" != "$SHA256" ]; then
  echo "error: opus-$VERSION.tar.gz has hash $actual, expected $SHA256" >&2
  echo "refusing to build an archive that will be linked into a signed appliance" >&2
  exit 1
fi

rm -rf "opus-$VERSION"
tar xzf "opus-$VERSION.tar.gz"
cd "opus-$VERSION"

echo "building for $ARCH"
# Deployment target matches the appliance's floor, so the archive cannot pull in
# symbols the target macOS lacks.
./configure \
  --host="${ARCH}-apple-darwin" \
  --prefix="$PREFIX" \
  --enable-static --disable-shared \
  --disable-doc --disable-extra-programs \
  CFLAGS="-arch $ARCH -mmacosx-version-min=13.0 -O2" \
  >/dev/null

make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null

echo "built $(lipo -info "$PREFIX/lib/libopus.a")"
