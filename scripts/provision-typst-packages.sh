#!/usr/bin/env bash
# Stages the Typst packages a generated document draws with.
#
# **Just one, and it is Graphviz.** `diagraph` is Graphviz compiled to
# WebAssembly plus a thin Typst wrapper, so a ```dot fence in a note becomes a
# real laid-out graph inside the PDF. Everything about that is worth having:
# Graphviz has been drawing these since 1991 and is what a language model
# already knows how to write, the WASM runs inside Typst so there is no second
# binary to sign, notarize or relocate, and it never touches the network once
# this script has run.
#
# **Vendored into the `@local` namespace on purpose.** Typst will happily fetch
# `@preview/…` from packages.typst.org on first compile — which would mean a
# document that renders on a developer's Mac and fails on an aeroplane, and a
# build whose output depends on a server. `@local` cannot reach the network by
# construction, so if this script has not run the import is simply absent and
# `DocumentTemplate` leaves the diagram support out. See `DocumentExporter`.
#
# Two licences travel with it: diagraph itself is MIT, and the Graphviz inside
# the WASM is EPL 2.0. The MIT text comes in the archive; the EPL text is in
# resources/licences and is copied in here so the vendor tree is complete on its
# own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${SAGE_VOICE_DIAGRAPH_VERSION:-0.3.5}"
DEST_ROOT="${SAGE_VOICE_TYPST_PACKAGES_ROOT:-$ROOT/vendor/typst-packages}"
DEST="$DEST_ROOT/local/diagraph/$VERSION"

EXPECTED_SHA="${SAGE_VOICE_DIAGRAPH_SHA256:-12515a12103b319d86b0ac6891e6c384c915331ed1cec74ad40282d917b2477f}"
URL="https://packages.typst.org/preview/diagraph-$VERSION.tar.gz"

die() { echo "error: $*" >&2; exit 1; }

if [[ -f "$DEST/typst.toml" && -f "$DEST/graphviz_interface/diagraph.wasm" ]]; then
  echo "$DEST"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching diagraph $VERSION"
curl -fsSL -o "$WORK/diagraph.tar.gz" "$URL" || die "could not download $URL"

ACTUAL="$(shasum -a 256 "$WORK/diagraph.tar.gz" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED_SHA" ]] || die "diagraph $VERSION checksum mismatch.
  expected $EXPECTED_SHA
  got      $ACTUAL
Refusing to stage it. If you meant to move to a new version, update
SAGE_VOICE_DIAGRAPH_SHA256 in this script from the published package."

mkdir -p "$WORK/unpacked"
tar -xzf "$WORK/diagraph.tar.gz" -C "$WORK/unpacked"
[[ -f "$WORK/unpacked/typst.toml" ]] \
  || die "the archive did not contain typst.toml where this script expected it"
[[ -f "$WORK/unpacked/graphviz_interface/diagraph.wasm" ]] \
  || die "the archive did not contain the Graphviz plugin, which is the only reason to stage it"

# The version in the manifest, not the one in the filename. A package that
# claims a different version than the directory it sits in will not resolve, and
# the error typst gives for that names neither.
DECLARED="$(awk -F'"' '/^version *=/ {print $2; exit}' "$WORK/unpacked/typst.toml")"
[[ "$DECLARED" == "$VERSION" ]] \
  || die "the archive declares version '$DECLARED' but was fetched as $VERSION"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WORK/unpacked/." "$DEST/"

[[ -f "$DEST/LICENSE" ]] || die "diagraph is MIT and its licence text was not in the archive"
cp "$ROOT/resources/licences/EPL-2.0.txt" "$DEST_ROOT/GRAPHVIZ-LICENSE.txt"
{
  echo "diagraph $VERSION (MIT) — Graphviz compiled to WebAssembly"
  echo "$URL"
  echo "sha256 $EXPECTED_SHA"
  echo ""
  echo "The plugin embeds Graphviz, which is Eclipse Public License 2.0."
  echo "Its licence text is GRAPHVIZ-LICENSE.txt beside this file."
  echo "Graphviz source: https://gitlab.com/graphviz/graphviz"
} > "$DEST_ROOT/SOURCE"

echo "$DEST"
