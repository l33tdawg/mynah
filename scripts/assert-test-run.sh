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

# Measured on this checkout on 2026-08-04: a fully provisioned run on the build
# Mac reports "Executed 1840 tests, with 21 tests skipped".
#
# **A floor is only a floor relative to the suite it was measured against, and
# this one had already rotted.** It was set to 1790 when the suite was 1815,
# which left 25 of headroom. Twenty-five tests were then added in this same
# release, so losing the whole KokoroEngine target — 38 tests, the exact failure
# this number exists to catch — leaves 1802 and clears 1790 comfortably. Caught
# by the 1.7.0 audit.
#
# So the rule, rather than the number: **keep this within 38 of the true count**,
# because the smallest interesting loss is a test target and the smallest test
# target is Kokoro's 38. 1815 is 25 under today's 1840 and 13 above the 1802 a
# missing onnxruntime produces.
#
# Raise it in the same commit that adds a batch of tests. Test counts only ever
# grow; the only thing that lowers them is deleting tests, which ought to be
# reviewed anyway.
MIN_EXECUTED="${MYNAH_MIN_EXECUTED_TESTS:-1815}"
# The ceiling has to sit above the 21 that skip on a healthy build Mac and below
# the smallest number a missing document tool produces. **26 was set against
# pandoc's +12 and was blind to the tool this change was actually added to
# provision.** Measured here on 2026-08-04 by holding each vendor tree aside and
# running the whole suite:
#
#   vendor/pandoc absent           33 skipped   over 26, caught
#   vendor/typst absent            31 skipped   over 26, caught
#   vendor/typst-packages absent   25 skipped   UNDER 26, waved through
#
# provision-typst-packages.sh being missing from release.sh is the headline
# omission this change fixed, and package-app.sh stops a real release dead when
# its output is absent — so the one regression the gate most needed to see was
# the one it could not. Found by the 1.7.0 audit.
#
# 24: above the healthy 21, below the 25 that means no Graphviz. That leaves
# room for three new opt-in tests rather than five. If you need more than that,
# the right move is to stop skipping — raising this past 24 restores the blind
# spot, and past 30 the gate stops seeing a missing document surface at all.
MAX_SKIPPED="${MYNAH_MAX_SKIPPED_TESTS:-24}"

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

# **A run with failures in it verified nothing, and this script used to say it
# had.** The awk above deliberately matches `Test Suite 'All tests' failed at`
# as well as `passed`, because a failing run still has to be parsed to say what
# went wrong — and then nothing downstream ever looked at the outcome. On a log
# from a failing suite it printed "N of M really ran" and exited 0.
#
# In scripts/release.sh that was survivable by luck rather than design: `set -o
# pipefail` makes the failing `swift test` abort the script before this file is
# ever reached. Luck is not a gate, this file is invoked by name from two
# places, and its own first line claims it decides whether a run verified
# anything. So it decides.
# `with` or `and`, because XCTest writes both: "with 0 failures" on a run that
# skipped nothing, and "with 21 tests skipped and 3 failures" when it did. A
# pattern that matched only `with` read a failing run as zero failures — which
# is the same class of miss as reading a skipped test as an executed one, and it
# is why this is checked against a real failing summary below rather than
# reasoned about.
if [[ "$SUMMARY" =~ (with|and)\ ([0-9]+)\ failures? ]]; then
  FAILURES="${BASH_REMATCH[2]}"
else
  # No failure clause at all is not "no failures" — it is a summary this script
  # cannot read, and the same wording change would retire the counts above.
  die "could not read a failure count out of the XCTest summary in $LOG.
The line was: $SUMMARY
If XCTest has changed its wording, teach this script the new one rather than
leaving it unable to parse — that would silently retire the gate."
fi

if (( FAILURES > 0 )); then
  die "the suite reported $FAILURES failing test(s), so this run did not verify the release.
See them with:
  grep ' error: -\[' $LOG"
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
