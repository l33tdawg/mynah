#!/usr/bin/env bash
# One command from a clean checkout to a notarized, verified DMG.
#
#   scripts/release.sh                        # ad-hoc build, no notarization
#   MYNAH_NOTARIZE=1 \
#   SAGE_VOICE_CODESIGN_IDENTITY="Developer ID Application: …" \
#     scripts/release.sh                      # the real thing
#
# Order matters and is not arbitrary:
#   provision before tests — the suite does not fail when a vendored tool is
#                          missing, it skips, and XCTest reports a skipped test
#                          as an executed one. Staging the tools first is what
#                          turns those skips back into assertions. Nothing in
#                          provisioning signs anything — every one of those
#                          scripts downloads or builds an input and stops — so
#                          the tests-before-signing invariant below is untouched
#                          by having moved them up.
#   tests before build   — a release that fails its own suite should never reach
#                          a signing key
#   build before package — package-app.sh copies binaries, it does not make them
#   package before dmg   — create-dmg.sh refuses an unsigned bundle
#   notarize before dmg  — the ticket staples to the .app; an image built before
#                          that carries an unstapled bundle and needs the network
#                          on first launch. Notarizing the image instead does not
#                          work at all: notarize.sh takes a bundle, not a file.
#   dmg last             — so the image is built around a stapled bundle and its
#                          .sha256 describes the bytes that actually ship
#   verify after staple  — the only check that answers "will this launch on a Mac
#                          that has never seen it"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NOTARIZE="${MYNAH_NOTARIZE:-0}"
SIGN_IDENTITY="${SAGE_VOICE_CODESIGN_IDENTITY:--}"
export SAGE_VOICE_CODESIGN_IDENTITY="$SIGN_IDENTITY"

step() { printf '\n=== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# Fail before the slow part rather than after it. Notarization with an ad-hoc
# signature is rejected by Apple minutes into the submission, and the useful
# time to learn that is now.
if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]]; then
  [[ "$SIGN_IDENTITY" != "-" ]] \
    || die "MYNAH_NOTARIZE=1 needs SAGE_VOICE_CODESIGN_IDENTITY set to a Developer ID Application identity.
Apple will not notarize an ad-hoc signature."
  [[ -n "${MYNAH_NOTARY_PROFILE:-}" || -n "${MYNAH_APPLE_ID:-}" ]] \
    || die "MYNAH_NOTARIZE=1 needs MYNAH_NOTARY_PROFILE (or MYNAH_APPLE_ID + MYNAH_TEAM_ID + MYNAH_APP_PASSWORD).
See scripts/notarize.sh for how to store a keychain profile."
fi

# Everything the build and the suite consume, staged before either runs.
#
# **This block used to sit after the tests, and that is what let a release ship
# an unexercised document surface.** `DocumentExporter.locate()` looks in two
# places only — `../Resources/<tool>` inside Mynah.app, and `vendor/<tool>` in a
# checkout — and `vendor/` is gitignored. So on a clean checkout pandoc and typst
# were simply absent when the suite ran, every document test threw `XCTSkip`, and
# the gate below counted them as executed. Measured on this checkout on
# 2026-08-04 by holding vendor/pandoc aside and running the whole suite:
#
#   pandoc staged   Executed 1815 tests, with 21 tests skipped
#   pandoc absent   Executed 1815 tests, with 33 tests skipped
#
# Both runs passed. The executed count does not move by one, twelve document
# tests are the entire difference, and the check this step used to make —
# `grep -qE "Executed [1-9][0-9]* tests"` — went green on the second one.
#
# Nothing below signs, packages or notarizes anything: each script downloads or
# builds an input, verifies its SHA-256, and stops. So moving them in front of
# the tests costs the ordering invariant nothing — the suite still runs before
# `swift build`, and a failing suite still never reaches the signing key.
#
# The scripts all stop early when their output is already staged, so on a repeat
# run in a working repo this block is close to free. On a genuinely clean
# checkout it is the slowest part of the release, mostly because espeak-ng is
# built from source rather than downloaded.
step "provision signed speech assets"
bash scripts/provision-asr-assets.sh

step "provision signed Signal helper"
bash scripts/provision-signal-cli.sh

# The native voice's two binaries. package-app.sh requires both and this script
# would otherwise never produce them — the same omission the call endpoint below
# documents, which stayed hidden for several releases because the working repo
# happened to have the artifact lying around from a manual run.
#
# ONNX Runtime has to be staged before the first SwiftPM command of the run and
# not merely before packaging, because Package.swift decides whether the
# KokoroEngine and KokoroEngineTests targets exist at all by looking for
# `vendor/onnxruntime/lib/libonnxruntime.dylib` while the manifest is being
# evaluated. Provision it afterwards and SwiftPM serves the manifest it already
# cached, the whole Kokoro test target stays out of the graph, and the suite
# reports a healthy number having never built it. Confirmed here: staging the
# dylib into an already-evaluated tree left `swift package describe` listing
# five targets, and the Kokoro three only came back after the cache was bypassed.
step "provision ONNX Runtime for the native voice"
bash scripts/provision-onnxruntime.sh

step "provision espeak-ng for the native voice"
bash scripts/provision-espeak-ng.sh

# The document writers, and the one package a drawn diagram needs.
#
# provision-typst-packages.sh was never called from here at all, which
# package-app.sh:474 turns into a hard stop on a clean checkout — "Required
# Typst packages are missing" — after the tests, the build and the notarization
# have already been paid for. It is also what four of the skips above were
# waiting on.
step "provision pandoc and typst for documents"
bash scripts/provision-pandoc.sh
bash scripts/provision-typst.sh
bash scripts/provision-typst-packages.sh

step "tests"
# Two things, and the second is the one that matters.
#
# `swift test` on its own does not run the suite on an Apple Silicon Mac where
# the xctest runner resolves to x86_64: the arm64 test bundle fails to load with
# "incompatible architecture", the swift-testing runner then reports
# "Test run with 0 tests in 0 suites passed", and the whole command **exits 0**.
# Measured here, not theorised — 1148 tests became 0 and the step went green.
# `arch -arm64` is what actually runs them; `--arch arm64` does not, because it
# changes what is built rather than what loads it.
#
# And then the assertion, because the arch fix only addresses the cause known
# today. A gate that silently runs zero tests is worse than no gate: this script
# puts tests before the build precisely so a failing suite never reaches a
# signing key, and a step that passes without executing anything hands that key
# over while looking like it did its job. So the run is measured rather than the
# exit code trusted.
#
# The measurement lives in scripts/assert-test-run.sh because the release
# workflow has to make exactly the same one — it used to run a bare `swift test`
# with no check at all, which is how no document test has ever run on a public
# runner. Two scripts agreeing about the numbers by copy is two scripts waiting
# to disagree.
TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/mynah-release-tests.XXXXXX")"
trap 'rm -f "$TEST_LOG"' EXIT
if [[ "$(uname -m)" == "arm64" ]]; then
  arch -arm64 swift test 2>&1 | tee "$TEST_LOG"
else
  swift test 2>&1 | tee "$TEST_LOG"
fi
bash scripts/assert-test-run.sh "$TEST_LOG"

step "release build"
swift build -c release --arch arm64

# The call endpoint, which package-app.sh requires and this script never built.
#
# It went unnoticed because every release so far was cut from the working repo,
# where `.build/sage-voice-webrtc` was left behind by an earlier manual run.
# Building from a clean checkout is what surfaced it: package-app.sh stops with
# "Required call endpoint is missing", naming the file and not the reason this
# script did not produce it.
#
# Separate from `swift build` because the endpoint is Go with cgo and a static
# libopus, so it is built one architecture at a time — see the trap documented
# in the script itself, where a Rosetta Go toolchain silently emits an Intel
# binary that cannot link an arm64 archive.
step "call endpoint"
bash webrtc/scripts/build-endpoint.sh

step "package + sign"
bash scripts/package-app.sh

# Notarize BEFORE the disk image, not after.
#
# This used to run create-dmg.sh first and then hand the .dmg to notarize.sh,
# which fails outright: notarize.sh guards with `[[ -d "$APP" ]]` and a disk
# image is a file, so every notarized run died on "No app at …/Mynah.dmg". The
# one-command path in this script's own header had therefore never once
# produced a notarized release; every real one was assembled by hand.
#
# Two more things went wrong in that order even after the argument was right:
#
#   * Stapling the app does not staple a disk image built before it, so the
#     image shipped an unstapled bundle and first launch needed the network —
#     the exact thing the old comment here claimed to be preventing.
#   * create-dmg.sh writes the .sha256 as it builds. Attaching a ticket
#     afterwards rewrites the image, so the recorded checksum described a file
#     that no longer existed and verify-dmg.sh failed on its first check.
#
# Notarizing the bundle first settles all three: the ticket is stapled to the
# app, the image is then built around an already-stapled bundle, and the
# checksum is written last, over the bytes that actually ship.
if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]]; then
  step "notarize + staple"
  bash scripts/notarize.sh "$ROOT/dist/Mynah.app"
fi

step "disk image"
DMG="$(bash scripts/create-dmg.sh | head -1)"
[[ -f "$DMG" ]] || die "create-dmg.sh did not produce an image"

step "verify"
if ! bash scripts/verify-dmg.sh "$DMG"; then
  if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]]; then
    die "a notarized release failed verification — do not publish this"
  fi
  echo
  echo "note: Gatekeeper/staple checks fail for an ad-hoc build. Expected."
  echo "      Set MYNAH_NOTARIZE=1 with a Developer ID identity for a real release."
fi

echo
echo "Artifact:"
ls -lh "$DMG" "$DMG.sha256"
