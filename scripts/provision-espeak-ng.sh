#!/usr/bin/env bash
# Stages the grapheme-to-phoneme front end the native voice speaks through.
#
# ## Why a separate executable rather than a linked library
#
# espeak-ng is **GPLv3**. Linking `libespeak-ng` into Mynah would make the app a
# derivative work and put the whole bundle under GPLv3 — which is not a licence
# this project can ship under. So espeak-ng is vendored the same way signal-cli
# already is: a standalone executable, invoked as a subprocess, communicating
# over stdout. That is arm's-length aggregation, and it is the reason this script
# configures `--disable-shared --enable-static` — the binary carries its own copy
# of the library and there is no dylib for anything of ours to link against.
#
# `COPYING` ships beside the binary and the source tarball is retained under
# `src/`, so the corresponding-source obligation is satisfiable from a release
# machine rather than reconstructed after the fact.
#
# ## Why not use the library the Python path used
#
# `espeakng_loader` ships `libespeak-ng.dylib`. It is the same 1.52.0 code, and
# it is precisely the thing we must not link. It is also not a CLI, so it cannot
# be driven as a subprocess.
#
# ## Why G2P cannot simply be written in Swift
#
# The temptation is to hand-roll a phoneme table and skip 17 MB of source. It
# does not work: number, date, currency and abbreviation expansion happen
# *inside* espeak, before letter-to-sound rules run. `"Cost: $5.50"` comes out as
# `kˈɔst: dˈɑːlɚ fˈaɪv.fˈɪfti` — "dollar five fifty", a decision no phoneme table
# makes. Reimplementing that is reimplementing espeak.
#
# ## A trap worth knowing about
#
# `--compile-phonemes` builds vowel-file paths in a fixed `char[180]` buffer and
# **silently truncates** anything longer, then reports `Bad vowel file` for a
# name that is plainly present on disk. It is not a corrupt checkout: the build
# directory path is simply too long. Building under `vendor/` keeps the longest
# path near 102 characters. If this script is ever pointed somewhere deeper and
# starts failing on Finnish, Vietnamese, Lule Saami or NYC English vowels, that
# is this limit and not a real error — shorten the path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESPEAK_ROOT="${SAGE_VOICE_ESPEAK_ROOT:-$ROOT/vendor/espeak-ng}"

ESPEAK_VERSION="1.52.0"
# GitHub generates these archives on demand rather than storing an uploaded
# asset — the 1.52.0 release publishes only an Android APK and a Windows MSI —
# so the digest is of the archive as served on 2026-07-30 at 17,739,803 bytes.
# The tag's commit is recorded alongside it because a regenerated archive would
# change this digest without changing the source, and the commit is what the
# digest is really standing in for.
ESPEAK_ARCHIVE_SHA="bb4338102ff3b49a81423da8a1a158b420124b055b60fa76cfb4b18677130a23"
ESPEAK_TAG_COMMIT="4870adfa25b1a32b4361592f1be8a40337c58d6c"
ESPEAK_ARCHIVE="espeak-ng-${ESPEAK_VERSION}.tar.gz"
ESPEAK_URL="https://github.com/espeak-ng/espeak-ng/archive/refs/tags/${ESPEAK_VERSION}.tar.gz"

SOURCE_ROOT="$ESPEAK_ROOT/src"
mkdir -p "$SOURCE_ROOT" "$ESPEAK_ROOT/bin" "$ESPEAK_ROOT/share"

verify_sha() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "SHA-256 mismatch for $file" >&2
    echo "expected $expected" >&2
    echo "actual   $actual" >&2
    echo "" >&2
    echo "If GitHub regenerated the archive, verify the contents against commit" >&2
    echo "$ESPEAK_TAG_COMMIT before updating the pin." >&2
    exit 1
  }
}

ARCHIVE_PATH="$SOURCE_ROOT/$ESPEAK_ARCHIVE"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  curl -L --fail --retry 3 "$ESPEAK_URL" -o "$ARCHIVE_PATH"
fi
verify_sha "$ARCHIVE_PATH" "$ESPEAK_ARCHIVE_SHA"

UNPACKED="$SOURCE_ROOT/espeak-ng-${ESPEAK_VERSION}"
if [[ ! -d "$UNPACKED" ]]; then
  tar -xzf "$ARCHIVE_PATH" -C "$SOURCE_ROOT"
fi

# The path-length trap above. Fail with the real reason rather than letting the
# data compiler report a missing file that is sitting right there.
PROBE="$UNPACKED/espeak-ng-data/../phsource/vwl_en_us_nyc/e_short_1"
if [[ ${#PROBE} -ge 179 ]]; then
  echo "Build path is too long for espeak-ng's data compiler." >&2
  echo "  longest probe path: ${#PROBE} chars (limit 179)" >&2
  echo "  $PROBE" >&2
  echo "Set SAGE_VOICE_ESPEAK_ROOT to somewhere shallower and re-run." >&2
  exit 1
fi

cd "$UNPACKED"

# `--without-pcaudiolib` is the load-bearing one: we only ever ask espeak for
# phonemes on stdout, so an audio-output backend would be a dependency bought
# for nothing. Klatt/MBROLA/speechPlayer are synthesizers we do not use either —
# Kokoro is the voice; espeak is only the front end that spells words out.
if [[ ! -f config.status ]]; then
  ./autogen.sh
  ./configure --prefix="$ESPEAK_ROOT" \
    --without-pcaudiolib \
    --without-sonic \
    --without-mbrola \
    --without-speechplayer \
    --disable-shared \
    --enable-static
fi

make -j"$(sysctl -n hw.ncpu)"
make install

# Prove it works before declaring success. A staged binary that cannot phonemize
# is worse than an absent one, because the absence is noticed at provision time
# and the failure is noticed by the owner mid-sentence.
PHONEMES="$(
  ESPEAK_DATA_PATH="$ESPEAK_ROOT/share/espeak-ng-data" \
    "$ESPEAK_ROOT/bin/espeak-ng" -q --ipa=3 -v gmw/en-US "hello" 2>/dev/null | tr -d ' \n'
)"
if [[ -z "$PHONEMES" ]]; then
  echo "Staged espeak-ng produced no phonemes for 'hello'." >&2
  exit 1
fi
echo "espeak-ng says 'hello' is: $PHONEMES"

# The licence travels with the binary it covers, and the source archive stays
# put so the corresponding-source offer is answerable.
cp "$UNPACKED/COPYING" "$ESPEAK_ROOT/COPYING"
cp "$UNPACKED/README.md" "$ESPEAK_ROOT/README.espeak-ng.md"
echo "$ESPEAK_VERSION" > "$ESPEAK_ROOT/VERSION"
echo "$ESPEAK_TAG_COMMIT" > "$ESPEAK_ROOT/SOURCE_COMMIT"

# The data path compiled into the binary is this machine's absolute prefix,
# which will not exist on the owner's Mac. Callers must pass ESPEAK_DATA_PATH;
# EspeakPhonemizer does, and this note is here for whoever wonders why.
echo "$ESPEAK_ROOT"
