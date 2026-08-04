#!/usr/bin/env bash
# Decides whether a `swift test` run actually verified anything.
#
#   arch -arm64 swift test 2>&1 | tee /tmp/tests.log
#   bash scripts/assert-test-run.sh /tmp/tests.log
#
# It reads a log a test run has already written; it runs nothing itself. That is
# deliberate — scripts/release.sh and .github/workflows/release.yml invoke the
# suite differently, and the point of this file is that they cannot end up
# judging it differently.
#
# ## The check this replaces, and why it could not fail
#
# release.sh used to assert `grep -qE "Executed [1-9][0-9]* tests"` and nothing
# else. **XCTest counts a skipped test as an executed one**, so that pattern is
# satisfied by a run in which every single test was skipped.
#
# It was not a theoretical hole. Provisioning of pandoc and typst used to happen
# after the test step, and `DocumentExporter.locate()` looks for them in exactly
# two places — `../Resources/<tool>` inside Mynah.app and `vendor/<tool>` in a
# checkout — both of which are gitignored. Measured on this checkout on
# 2026-08-04, by holding vendor/pandoc aside and running the whole suite:
#
#   pandoc staged   Executed 1815 tests, with 21 tests skipped   suite passed
#   pandoc absent   Executed 1815 tests, with 33 tests skipped   suite passed
#
# The twelve document tests are the whole of the difference and **the executed
# count does not move by one**. Any floor on the executed count alone, however
# high, would have waved the second run through exactly as the first. That is
# why there are two assertions below, and why the ceiling on skips is the
# load-bearing one.
#
# The same shape, one layer down, on a checkout with no vendor/ at all: 1777
# executed with 29 skipped unstaged against 1777 with 17 staged. The executed
# count is again identical.
#
# ## What the two numbers are for
#
# The floor catches a run that did not happen: an arm64 bundle that failed to
# load, a filter that matched nothing, a test target that fell out of the
# package graph. The ceiling catches a run that happened but was hollow. Neither
# is satisfiable by an empty run and neither is satisfiable by an all-skipped
# one, which is the property the old check lacked.
#
# Both are environment variables because the honest floor differs by machine:
# the Kokoro tests read a model out of ~/sage-voice-lab, so they skip on a
# hosted runner and run on the build Mac. Defaults are the build Mac, which is
# where release.sh runs.
set -euo pipefail

LOG="${1:-}"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "$LOG" ]] \
  || die "assert-test-run.sh needs the path to a test log as its only argument.
Capture one with: arch -arm64 swift test 2>&1 | tee /tmp/tests.log"
[[ -f "$LOG" ]] \
  || die "no test log at $LOG.
Capture one with: arch -arm64 swift test 2>&1 | tee $LOG"

# Measured on this checkout on 2026-08-04, deliberately not carried forward from
# the earlier audit that said 1783: a fully provisioned run on the build Mac
# reports "Executed 1815 tests, with 21 tests skipped".
#
# 1790 rather than something far lower, because the failure this floor has to
# catch is not "zero tests" — it is losing a whole test target quietly. Staging
# vendor/onnxruntime late leaves SwiftPM serving a cached manifest without the
# KokoroEngine targets and the run drops to 1777 while still looking healthy;
# anything under 1777 would wave that through. Test counts only ever grow, so a
# floor 25 under today's number needs no headroom for new tests — the only thing
# that lowers it is deleting tests, which ought to be reviewed anyway.
MIN_EXECUTED="${MYNAH_MIN_EXECUTED_TESTS:-1790}"
# The ceiling has to sit above the 21 that skip on a healthy build Mac and below
# the 33 a missing document surface produces, or it is decoration. 26 leaves
# room for five new opt-in tests and still trips seven clear of the failure it
# exists to catch. Widening it past 32 disarms it entirely — if you need that
# much room, the right move is to stop skipping, not to raise this.
MAX_SKIPPED="${MYNAH_MAX_SKIPPED_TESTS:-26}"

# The line after "Test Suite 'All tests' passed", specifically, rather than the
# last line matching "Executed" anywhere. XCTest prints a summary per suite, so
# there are hundreds of candidates, and `swift test` prints the swift-testing
# runner's own summary after XCTest has finished — taking the last match is a
# coincidence waiting to break.
SUMMARY="$(awk "/Test Suite 'All tests' (passed|failed) at/ { getline; print; exit }" "$LOG")"

[[ -n "$SUMMARY" ]] \
  || die "$LOG contains no XCTest summary at all, so no test ran and nothing was verified.
This is not an empty suite; it is the suite never having started. Search the log
for 'incompatible architecture' — on an Apple Silicon Mac where the xctest
runner resolves to x86_64 the test bundle fails to load, the run reports zero
tests, and the command still exits 0. Rerun with: arch -arm64 swift test"

EXECUTED="$(printf '%s\n' "$SUMMARY" | sed -E 's/.*Executed ([0-9]+) tests?,.*/\1/')"
[[ "$EXECUTED" =~ ^[0-9]+$ ]] \
  || die "could not read an executed-test count out of the XCTest summary in $LOG.
The line was: $SUMMARY
If XCTest has changed its wording, this script has to be taught the new one —
leaving it unable to parse would silently retire the gate."

# The skipped clause is absent, not zero, when nothing was skipped: XCTest
# writes "with 0 failures" and no mention of skipping at all.
if [[ "$SUMMARY" =~ with\ ([0-9]+)\ tests?\ skipped ]]; then
  SKIPPED="${BASH_REMATCH[1]}"
else
  SKIPPED=0
fi

RAN=$(( EXECUTED - SKIPPED ))

if (( EXECUTED < MIN_EXECUTED )); then
  die "the suite executed $EXECUTED tests, under the floor of $MIN_EXECUTED, so this run did not cover the release.
Worth checking in this order:
  1. 'incompatible architecture' in $LOG — the bundle did not load. Rerun with
     arch -arm64 swift test.
  2. vendor/onnxruntime is not staged. Package.swift decides whether the
     KokoroEngine and KokoroEngineTests targets exist by looking for
     vendor/onnxruntime/lib/libonnxruntime.dylib as it is read, so an absent
     dylib removes 38 tests from the graph rather than failing anything. Run
     scripts/provision-onnxruntime.sh, then delete .build — SwiftPM caches the
     evaluated manifest and will otherwise keep serving the graph it already
     decided on.
  3. tests really were deleted on purpose, in which case lower
     MYNAH_MIN_EXECUTED_TESTS in the same commit that deleted them, so the new
     floor is reviewed alongside the removal."
fi

if (( SKIPPED > MAX_SKIPPED )); then
  die "the suite skipped $SKIPPED tests, over the ceiling of $MAX_SKIPPED, so part of it was not verified.
The executed count above looks healthy because XCTest counts a skipped test as
executed. It is this number that says what actually ran: $RAN of $EXECUTED.

See which ones and why:
  grep 'Test skipped - ' $LOG

Twelve at once, naming pandoc, typst or Graphviz, is the document surface not
being staged. Stage it and run the suite again:
  bash scripts/provision-pandoc.sh
  bash scripts/provision-typst.sh
  bash scripts/provision-typst-packages.sh

If the skips are legitimately new opt-in tests, raise MYNAH_MAX_SKIPPED_TESTS
deliberately and keep it under 32 — above that this check can no longer see a
missing document surface, which is the thing it was written for."
fi

echo "tests: $RAN of $EXECUTED really ran, $SKIPPED skipped (floor $MIN_EXECUTED executed, ceiling $MAX_SKIPPED skipped)"
