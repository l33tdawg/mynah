#!/usr/bin/env bash
# Stages the ONNX Runtime the native voice runs on.
#
# Version-pinned and SHA-256 verified, like every other opaque binary this
# repo vendors. A release-machine step; the owner never runs it, and the dylib
# is codesigned along with the rest of the bundle.
#
# Why a prebuilt rather than a source build like whisper.cpp: ONNX Runtime takes
# the better part of an hour to compile and Microsoft publish an official
# arm64 macOS binary. whisper.cpp is built from source because we want Metal
# switched on, which their releases do not carry; here the CPU provider is
# enough — the Python path reaches a real-time factor of 0.16 on CPU alone.
#
# MIT licensed. LICENSE and ThirdPartyNotices.txt are copied beside the dylib so
# the attribution ships with the thing it covers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORT_ROOT="${SAGE_VOICE_ORT_ROOT:-$ROOT/vendor/onnxruntime}"

ORT_VERSION="1.28.0"
# Verified against the release on 2026-07-29; the URL served exactly 32396562
# bytes and this digest.
ORT_ARCHIVE_SHA="1268b359718099bde2cedb55787f182a130067bc4f31e8c88478c445b850d3d8"
ORT_ARCHIVE="onnxruntime-osx-arm64-${ORT_VERSION}.tgz"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${ORT_ARCHIVE}"

SOURCE_ROOT="$ORT_ROOT/src"
mkdir -p "$SOURCE_ROOT" "$ORT_ROOT/lib" "$ORT_ROOT/include"

verify_sha() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "SHA-256 mismatch for $file" >&2
    echo "expected $expected" >&2
    echo "actual   $actual" >&2
    exit 1
  }
}

ARCHIVE_PATH="$SOURCE_ROOT/$ORT_ARCHIVE"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  curl -L --fail --retry 3 "$ORT_URL" -o "$ARCHIVE_PATH"
fi
verify_sha "$ARCHIVE_PATH" "$ORT_ARCHIVE_SHA"

UNPACKED="$SOURCE_ROOT/onnxruntime-osx-arm64-${ORT_VERSION}"
if [[ ! -d "$UNPACKED" ]]; then
  tar -xzf "$ARCHIVE_PATH" -C "$SOURCE_ROOT"
fi

# The real file, not the symlink chain. A bundle carrying
# libonnxruntime.dylib -> libonnxruntime.1.28.0.dylib gains a dangling link the
# moment one of the two is signed and the other is not.
cp "$UNPACKED/lib/libonnxruntime.${ORT_VERSION}.dylib" "$ORT_ROOT/lib/libonnxruntime.dylib"
chmod +x "$ORT_ROOT/lib/libonnxruntime.dylib"

# Rewritten to @rpath so the copy inside Mynah.app/Contents/Frameworks resolves
# without an absolute path to whatever machine built it. Left alone, the install
# name points at the release-machine layout and the app cannot launch anywhere
# else.
install_name_tool -id "@rpath/libonnxruntime.dylib" "$ORT_ROOT/lib/libonnxruntime.dylib"

# The whole include tree, not a hand-picked subset.
#
# `onnxruntime_c_api.h` includes siblings — `onnxruntime_error_code.h` among
# them — so copying only the entry point produces a header that cannot be
# parsed. The C++ headers come along and are simply never included: the module
# map names the C entry point, and nothing reaches `onnxruntime_cxx_api.h` and
# its <string>/<vector> dependencies.
rsync -a --delete "$UNPACKED/include/" "$ORT_ROOT/include/"
cp "$UNPACKED/LICENSE" "$UNPACKED/ThirdPartyNotices.txt" "$ORT_ROOT/"
echo "$ORT_VERSION" > "$ORT_ROOT/VERSION"

echo "$ORT_ROOT"
