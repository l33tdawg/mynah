#!/usr/bin/env bash
# Stages the Node runtime the WhatsApp bridge runs on.
#
# **Why a whole runtime is in this bundle.** WhatsApp has no official client
# library for anything this app is written in. Baileys is the one maintained
# implementation, it is TypeScript, and it needs Node — so shipping WhatsApp
# means shipping Node. There is no version of this feature that does not.
#
# Everything else in Mynah.app is a self-contained native binary plus data:
# signal-cli is a 121 MB GraalVM native image, pandoc and typst and espeak-ng
# are single binaries. Node keeps that shape — it is one 112 MB Mach-O — and
# the JavaScript beside it is 32 MB with, deliberately, no native addons at
# all (see scripts/provision-whatsapp-bridge.sh). That last part is what makes
# this ordinary: codesign seals the tree into CodeResources without having to
# sign anything inside it.
#
# Downloaded from nodejs.org and checked against a pinned SHA-256, the same way
# provision-typst.sh does it. Not from Homebrew and not from the build Mac's
# nvm: an app that ships whatever runtime happened to be installed on the
# machine that built it is an app nobody can reproduce.
#
# **This binary must be re-signed, and package-app.sh does it.** The download
# arrives already signed and hardened by the Node Foundation (Team
# HX7739G8FX) with six entitlements, and one of them is
# com.apple.security.get-task-allow — a development entitlement that lets
# another process attach as a debugger, and one Apple's notary service
# rejects. Staged unchanged, it fails notarisation at the very end of a
# release, after everything else has been signed.
#
# Measured on this Mac on 7 August 2026 with the real Developer ID identity,
# because an ad-hoc signature carries no Team ID and the hardened runtime is
# then not enforced at all:
#
#   hardened runtime, no entitlements   node -e     rc=133 (SIGTRAP), instant
#                                       bridge.js   rc=133, no QR
#   hardened runtime, allow-jit only    node -e     ran, v22.22.0
#                                       bridge.js   stayed up, QR drawn
#
# So com.apple.security.cs.allow-jit is necessary and sufficient — V8 needs to
# map executable memory, and that is the narrow MAP_JIT-shaped permission for
# it. The wider allow-unsigned-executable-memory that Node itself declares is
# not needed here and is not granted. resources/NodeRuntime.entitlements holds
# the grant and the rest of the reasoning.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${SAGE_VOICE_NODE_VERSION:-22.22.0}"
DEST_ROOT="${SAGE_VOICE_NODE_ROOT:-$ROOT/vendor/node}"
DEST="$DEST_ROOT/bin/node"

# From https://nodejs.org/dist/v22.22.0/SHASUMS256.txt, fetched 7 August 2026.
# Change this in the same commit as VERSION, never separately: a version bump
# with a stale hash fails with a checksum error that reads like a corrupted
# download and sends whoever hits it looking in the wrong place entirely.
EXPECTED_SHA="${SAGE_VOICE_NODE_SHA256:-5ed4db0fcf1eaf84d91ad12462631d73bf4576c1377e192d222e48026a902640}"

ARCHIVE="node-v${VERSION}-darwin-arm64.tar.gz"
URL="${SAGE_VOICE_NODE_URL:-https://nodejs.org/dist/v${VERSION}/${ARCHIVE}}"

die() { echo "error: $*" >&2; exit 1; }

# Node's licence travels with it. Apache 2.0 section 4 requires it for our own
# licence, and Node's MIT terms require the notice to accompany the copy.
#
# Fatal, not a warning. This warned, and the warning was the defect: the binary
# it protects is 107 MB of somebody else's MIT-licensed code, package-app.sh used
# to copy the LICENSE only `[[ -f ]]`, and scripts/release.sh runs both without a
# human reading the scroll-back. A transient network failure here would have
# shipped it with the notice silently absent — a licence breach that looks
# exactly like a successful release.
#
# A function, and called on both paths, because it used to sit only at the end of
# the fresh-download path. Every rerun took the early return above it, so the one
# instruction package-app.sh gives when the file is missing — "rerun
# provision-node.sh" — did nothing.
#
# Skips the fetch when the file is already the real notice, so an offline rebuild
# of an already-provisioned tree works.
stage_licence() {
  if [[ -s "$DEST_ROOT/LICENSE" ]] \
     && grep -q "Permission is hereby granted, free of charge" "$DEST_ROOT/LICENSE"; then
    return 0
  fi
  mkdir -p "$DEST_ROOT"
  curl -fsSL "https://raw.githubusercontent.com/nodejs/node/v${VERSION}/LICENSE" \
    -o "$DEST_ROOT/LICENSE" \
    || die "could not fetch Node's LICENSE for v${VERSION}.
It ships beside the binary because MIT requires the notice to travel with the
copy, so this is not optional and packaging will refuse without it.
Retry, or save it by hand to $DEST_ROOT/LICENSE:
  curl -fsSL https://raw.githubusercontent.com/nodejs/node/v${VERSION}/LICENSE -o '$DEST_ROOT/LICENSE'"

  # Fetched, but is it the licence or a proxy's error page? `-f` catches an HTTP
  # status; it does not catch a captive portal answering 200 with HTML.
  [[ -s "$DEST_ROOT/LICENSE" ]] && grep -q "Permission is hereby granted, free of charge" "$DEST_ROOT/LICENSE" \
    || die "what was fetched for Node's LICENSE is not the MIT notice: $DEST_ROOT/LICENSE
Something answered the request that was not GitHub. Delete it and retry."
}

# **The binary being there is not the same as the staging being complete, and
# treating them alike made a fatal check unrecoverable.**
#
# This returned here the moment bin/node existed, which is every run after the
# first — so the LICENSE fetch at the bottom was reached exactly once in the life
# of a checkout. package-app.sh now *dies* when that file is missing and tells
# the operator to rerun this script, which in precisely that state did nothing at
# all. A dead end whose only signposted exit is a no-op.
#
# So the early return now requires everything this script is responsible for, and
# a missing piece falls through to the code that creates it rather than being
# reported. `stage_licence` is idempotent.
if [[ -x "$DEST" ]]; then
  FOUND="$("$DEST" --version 2>/dev/null || true)"
  [[ "$FOUND" == "v$VERSION" ]] \
    || die "vendored node is '$FOUND'; this release pins v$VERSION.
Delete $DEST_ROOT and rerun to restage."
  stage_licence
  echo "$VERSION" > "$DEST_ROOT/VERSION"
  echo "$DEST"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "fetching $URL"
curl -fsSL "$URL" -o "$WORK/$ARCHIVE" \
  || die "could not download Node $VERSION from $URL

If nodejs.org has retired this version, pick a current one and update BOTH
SAGE_VOICE_NODE_VERSION and SAGE_VOICE_NODE_SHA256 in this file."

FOUND_SHA="$(shasum -a 256 "$WORK/$ARCHIVE" | cut -d' ' -f1)"
[[ "$FOUND_SHA" == "$EXPECTED_SHA" ]] || die \
"checksum mismatch for $ARCHIVE
  expected $EXPECTED_SHA
  got      $FOUND_SHA

Either this file was tampered with in transit, or the pin in this script is
stale. Check https://nodejs.org/dist/v${VERSION}/SHASUMS256.txt before
changing anything — do not simply paste the new value in."

# **Only bin/node.** The tarball also carries npm, npx, headers and a full
# lib/node_modules — around 60 MB of things this app never runs. The bridge's
# dependencies are installed on the build Mac and staged separately, so the
# only thing needed at runtime is the interpreter.
tar -xzf "$WORK/$ARCHIVE" -C "$WORK" "node-v${VERSION}-darwin-arm64/bin/node"

mkdir -p "$DEST_ROOT/bin"
cp "$WORK/node-v${VERSION}-darwin-arm64/bin/node" "$DEST"
chmod 0755 "$DEST"

# Checked, not assumed. A Rosetta-era mistake here packages and signs
# perfectly and then cannot run on the appliance — the same failure
# package-app.sh guards against for the Go call endpoint.
ARCH="$(lipo -info "$DEST" 2>/dev/null || echo unknown)"
case "$ARCH" in
  *arm64*) ;;
  *) die "the staged node is not arm64: $ARCH" ;;
esac

FOUND="$("$DEST" --version)"
[[ "$FOUND" == "v$VERSION" ]] || die "staged node reports $FOUND, expected v$VERSION"

# Node's licence travels with it. Apache 2.0 section 4 requires it for our own
# licence, and Node's MIT terms require the notice to accompany the copy.
#
stage_licence

echo "$VERSION" > "$DEST_ROOT/VERSION"
echo "node v$VERSION staged at $DEST ($(du -h "$DEST" | cut -f1))"
echo "$DEST"
