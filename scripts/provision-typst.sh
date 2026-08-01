#!/usr/bin/env bash
# Stages Typst, which is how a document becomes a PDF.
#
# **Why not LaTeX.** Pandoc's default PDF engine is pdflatex, and a usable TeX
# distribution is somewhere between 400 MB and 5 GB — on a bundle that is
# already 900 MB, for one output format. Typst is a single 35 MB binary, Pandoc
# has supported `--pdf-engine=typst` since 3.1.11, and the output is a PDF
# nobody can tell apart.
#
# Apache 2.0, the same licence as this app, so it carries no copyleft
# obligation — but LICENSE and NOTICE are staged beside it anyway, because
# Apache 2.0 section 4 requires both to travel with a redistribution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${SAGE_VOICE_TYPST_VERSION:-0.15.1}"
DEST_ROOT="${SAGE_VOICE_TYPST_ROOT:-$ROOT/vendor/typst}"
DEST="$DEST_ROOT/bin/typst"

EXPECTED_SHA="${SAGE_VOICE_TYPST_SHA256:-48f62ed034aa3a7978309579ac6ca00045e2ef0da73114e8af27cfd8e74dc05a}"
URL="https://github.com/typst/typst/releases/download/v$VERSION/typst-aarch64-apple-darwin.tar.xz"

die() { echo "error: $*" >&2; exit 1; }

if [[ -x "$DEST" ]]; then
  FOUND="$("$DEST" --version 2>/dev/null | head -1 || true)"
  [[ "$FOUND" == *"$VERSION"* ]] || die "vendored typst is '$FOUND'; expected $VERSION.
Delete $DEST_ROOT and rerun to replace it."
  echo "$DEST"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching typst $VERSION"
curl -fsSL -o "$WORK/typst.tar.xz" "$URL" || die "could not download $URL"

ACTUAL="$(shasum -a 256 "$WORK/typst.tar.xz" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED_SHA" ]] || die "typst $VERSION checksum mismatch.
  expected $EXPECTED_SHA
  got      $ACTUAL
Refusing to stage it. If you meant to move to a new version, update
SAGE_VOICE_TYPST_SHA256 in this script from the published release."

mkdir -p "$WORK/unpacked"
tar -xJf "$WORK/typst.tar.xz" -C "$WORK/unpacked"
UNPACKED="$WORK/unpacked/typst-aarch64-apple-darwin"
[[ -f "$UNPACKED/typst" ]] || die "the archive did not contain typst where this script expected it"

ARCH="$(lipo -info "$UNPACKED/typst" 2>/dev/null || echo unknown)"
case "$ARCH" in
  *arm64*) ;;
  *) die "downloaded typst is not arm64: $ARCH" ;;
esac

mkdir -p "$DEST_ROOT/bin"
cp "$UNPACKED/typst" "$DEST"
chmod 0755 "$DEST"
# Apache 2.0 section 4 wants both, and they come in the archive, so there is no
# excuse for staging one without the other.
cp "$UNPACKED/LICENSE" "$DEST_ROOT/LICENSE"
cp "$UNPACKED/NOTICE" "$DEST_ROOT/NOTICE"
{
  echo "typst $VERSION"
  echo "$URL"
  echo "sha256 $EXPECTED_SHA"
} > "$DEST_ROOT/SOURCE"

"$DEST" --version | head -1
echo "$DEST"
