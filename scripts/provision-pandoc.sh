#!/usr/bin/env bash
# Stages Pandoc as a release input, so Mynah can write a real document.
#
# This runs on the build Mac, never the owner's Mac. The binary is copied into
# Mynah.app and signed with the rest of the bundle, so "make me a PDF about X"
# works on an appliance in a cupboard with no Homebrew, no Terminal and no
# network.
#
# **Why a downloaded release rather than Homebrew.** signal-cli is staged from
# brew because brew is where it lives; Pandoc publishes signed release archives
# and the checksum below pins exactly which bytes go into a build somebody may
# have to reproduce in two years. A tap that has moved on is not reproducible.
#
# **Why Pandoc at all.** *"don't reinvent the wheel — use open source github
# libs and packages that do all the heavy lifting"*, and DOCX, PPTX and ODT are
# each a zip of XML with twenty years of quirks in it. A hand-rolled writer
# produces files that open with a repair dialog, which is worse than not
# offering the feature.
#
# GPL-2.0-or-later. It is invoked as a subprocess and never linked, which is the
# same posture this bundle already takes with signal-cli and espeak-ng — and
# `resources/licences/GPL-2.0.txt` has to travel with it. package-app.sh refuses
# to build without that file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${SAGE_VOICE_PANDOC_VERSION:-3.10.1}"
DEST_ROOT="${SAGE_VOICE_PANDOC_ROOT:-$ROOT/vendor/pandoc}"
DEST="$DEST_ROOT/bin/pandoc"

# `shasum -a 256 pandoc-<version>-arm64-macOS.zip` on the published asset.
# Changing VERSION without changing this is what the check is for.
EXPECTED_SHA="${SAGE_VOICE_PANDOC_SHA256:-8607160694a70ed9aa63776caa44acef3afb729c379c7c283724b7e27455bfda}"
URL="https://github.com/jgm/pandoc/releases/download/$VERSION/pandoc-$VERSION-arm64-macOS.zip"

die() { echo "error: $*" >&2; exit 1; }

if [[ -x "$DEST" ]]; then
  FOUND="$("$DEST" --version 2>/dev/null | head -1 || true)"
  [[ "$FOUND" == *"$VERSION"* ]] || die "vendored pandoc is '$FOUND'; expected $VERSION.
Delete $DEST_ROOT and rerun to replace it."
  echo "$DEST"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching pandoc $VERSION"
curl -fsSL -o "$WORK/pandoc.zip" "$URL" \
  || die "could not download $URL"

# Before unpacking, not after. An archive that is not the one this build was
# tested against must never reach a machine, and a truncated download is the
# common case rather than the exotic one.
ACTUAL="$(shasum -a 256 "$WORK/pandoc.zip" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED_SHA" ]] || die "pandoc $VERSION checksum mismatch.
  expected $EXPECTED_SHA
  got      $ACTUAL
Refusing to stage it. If you meant to move to a new version, update
SAGE_VOICE_PANDOC_SHA256 in this script from the published release."

unzip -q "$WORK/pandoc.zip" -d "$WORK/unpacked"
BINARY="$WORK/unpacked/pandoc-$VERSION-arm64/bin/pandoc"
[[ -f "$BINARY" ]] || die "the archive did not contain bin/pandoc where this script expected it"

ARCH="$(lipo -info "$BINARY" 2>/dev/null || echo unknown)"
case "$ARCH" in
  *arm64*) ;;
  *) die "downloaded pandoc is not arm64: $ARCH" ;;
esac

mkdir -p "$DEST_ROOT/bin"
cp "$BINARY" "$DEST"
chmod 0755 "$DEST"

# What was staged, in a form that is still answerable years later. "pandoc
# 3.10.1" is ambiguous across rebuilds; the checksum of the archive it came out
# of is not — and a corresponding-source request has to be answerable for as
# long as the binary is out there.
{
  echo "pandoc $VERSION"
  echo "$URL"
  echo "sha256 $EXPECTED_SHA"
} > "$DEST_ROOT/SOURCE"

"$DEST" --version | head -1
echo "$DEST"
