#!/usr/bin/env bash
# Runs the suite on Linux, one test per process, and NAMES anything that wedges.
#
#   bash scripts/linux-test.sh                     # inside a Linux container
#   bash scripts/linux-test-in-docker.sh           # from the build Mac
#
# It is not a wrapper around `swift test`. `swift test` cannot be used to verify
# this package on Linux at all, and the reason is not in this package.
#
# ## Why per-test, and why that is not paranoia
#
# `RunLoop.run(mode:before:)` on swift-corelibs-foundation can block forever,
# ignoring the date it is handed. CFRunLoop asks ppoll for an *untimed* sleep and
# relies on a libdispatch timer to wake it; when that wake-up is lost the loop
# never returns. strace on a wedged process shows `ppoll([...], 1, NULL, NULL, 8)`
# on a call whose stated deadline was 50 ms.
#
# corelibs-xctest routes EVERY test — not only the async ones — through
# XCTWaiter.wait and so through RunLoop.run, with a nominal timeout of 30 days.
# So the first test that loses a wake parks the whole suite at 0% CPU, and which
# test that is MOVES BETWEEN RUNS, because it is a race and not a bad test.
#
# It is a toolchain bug and this harness is not a fix for it. Reproduced with a
# throwaway package of 400 trivial tests, one source file, no dependencies, on
# 6.0, 6.0.3, 6.1 and 6.2, on amd64 and arm64. Nothing in Sources/ or Tests/ is
# implicated and nothing here should be "fixed" by editing them.
#
# One test per process means a lost wake-up costs one test and names it, instead
# of costing the suite and naming nothing.
#
# ## Things that do not work, so nobody spends the day again
#
#   * a resident libdispatch heartbeat thread — made it worse
#   * a repeating Timer on the main run loop — corelibs arms mode timers through
#     libdispatch too, so the timer is downstream of the thing that is stuck
#   * a plain-thread waker calling RunLoop.main.perform — CFRunLoopPerformBlock
#     does not wake the loop
#   * `swift test --parallel`
#
# And the one thing that does: CONCURRENCY WIDTH IS THE TRIGGER. Pinning the
# container to a single CPU took the single-process suite from 3 tests to 920.
# So the loop below is sequential AND each test process is run under
# `taskset -c 0`.
#
# Pinning the TEST PROCESS rather than the whole container is deliberate, and it
# is not the same thing the original measurement did. Two reasons it is the
# right shape here. The compiler is not the thing that wedges — the wedge is
# XCTWaiter reaching RunLoop.run — so pinning the build as well would buy a
# tenfold slower build for no change in the hang count. And a GitHub-hosted
# runner has no --cpuset-cpus to give: the workflow runs on the metal, not in a
# container, and taskset is the only knob it has. Set MYNAH_LINUX_TEST_CPUSET in
# scripts/linux-test-in-docker.sh to pin the whole container instead, which is
# the like-for-like reproduction of the original 3-versus-920 measurement.
#
# Do not "speed this up" with background workers without measuring the hang
# count before and after: the hang count IS the measurement, and a faster run
# that wedges more has bought nothing.
#
# ## What may not be done to a wedge
#
# Not a sleep, not a longer timeout, not a skip. A suite that finishes because
# tests stopped running is the hollow suite scripts/assert-test-run.sh exists to
# catch, and this script gates on that file at the end for exactly that reason.
# A hang is reported as a hang, is never counted as a pass, is never quietly
# folded into the failure list, and always exits non-zero.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Knobs. Every one of these is an environment variable rather than a flag so a
# CI job can set it in an `env:` block the way .github/workflows/release.yml
# already sets assert-test-run.sh's numbers.
# ---------------------------------------------------------------------------

# Where SwiftPM builds. **Not .build/.** The same checkout is mounted into the
# container while a Mac toolchain owns .build/ in the host filesystem, and two
# triples sharing one scratch root is a class of failure that shows up as
# nonsense module errors hours later. The image sets this to /linux-scratch,
# outside the mount; off the image it defaults to a sibling of the checkout,
# still outside .build/.
SCRATCH_PATH="${MYNAH_LINUX_SCRATCH_PATH:-$REPO_ROOT/.build-linux}"

# Where the log, the machine-readable lists and the per-test output go.
OUT_DIR="${MYNAH_LINUX_TEST_OUT:-$SCRATCH_PATH/test-run}"

# Per-test wall clock. A test in this suite takes well under a second; a test
# that has been going for a minute is not slow, it is parked in ppoll at 0% CPU.
# **Raising this does not fix a hang.** It converts a named hang into a slower
# named hang, and if raised far enough into a suite that never finishes, which
# is the failure mode this whole file exists to prevent.
PER_TEST_TIMEOUT="${MYNAH_LINUX_TEST_TIMEOUT:-60s}"

# How long after SIGTERM before SIGKILL. A wedged corelibs process does die on
# TERM — it is blocked in ppoll, not uninterruptible — but a test that has
# spawned a child can outlive it.
KILL_AFTER="${MYNAH_LINUX_TEST_KILL_AFTER:-10s}"

# The CPU each test process is confined to. See the note above on concurrency
# width — this is a finding, not a tuning parameter.
TEST_CPU="${MYNAH_LINUX_TEST_CPU:-0}"

# Optional ERE, matched against the test ids from --list-tests, for running a
# subset while working on the harness itself. **A filtered run is not a
# verification of the suite** and this script says so in its output and in the
# log; CI must never set it.
ID_FILTER="${MYNAH_LINUX_TEST_FILTER:-}"

# The floor on how many test ids the enumeration found, so a green result cannot
# be bought by running fewer tests. Left empty deliberately: the honest number is
# whatever this checkout actually enumerates, and a number invented here would be
# a gate that has never been compared to anything. The first run prints the count
# and tells you to set it — the same shape assert-test-run.sh uses to keep its
# own floor from rotting.
MIN_TESTS="${MYNAH_LINUX_MIN_TESTS:-}"

# ---------------------------------------------------------------------------
# This has to be Linux. On a Mac it would be a false green of the worst kind:
# the Mac suite passing while the port is never exercised.
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
  die "scripts/linux-test.sh runs on Linux, and this is $(uname -s).
There is no cross-compile route: Package.swift is Swift compiled for the HOST,
so loading it on a Mac assembles the Mac graph before a single source file is
read. Build for Linux on Linux.
From the build Mac, the container is one command:
  bash scripts/linux-test-in-docker.sh"
fi

command -v timeout >/dev/null 2>&1 \
  || die "no coreutils \`timeout\` on PATH, and it is what names a hang here.
Without it a wedged test parks this script forever and reports nothing, which is
the exact failure the harness exists to prevent. Install coreutils, or run this
in the image: bash scripts/linux-test-in-docker.sh"

command -v swift >/dev/null 2>&1 \
  || die "no \`swift\` on PATH. Expected the swift:6.0.3-jammy toolchain — the
image commit 9a7e797 verified against. Build it with:
  docker build -f docker/linux-test.Dockerfile -t mynah-linux-test ."

# Confined rather than merely sequential. Absence is reported rather than
# shrugged off: without it the run is still correct, but it is a DIFFERENT run
# from the one the hang counts were measured on, and a hang count compared
# across that difference means nothing.
if command -v taskset >/dev/null 2>&1; then
  PIN=(taskset -c "$TEST_CPU")
  PIN_NOTE="taskset -c $TEST_CPU"
else
  PIN=()
  PIN_NOTE="NOT PINNED - no taskset on PATH"
  echo "linux-test: WARNING: no \`taskset\`, so test processes run at full concurrency width."
  echo "linux-test: WARNING: expect more hangs than a pinned run, and do not compare the two."
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/per-test"
LOG="$OUT_DIR/tests.log"
IDS_FILE="$OUT_DIR/ids.txt"
PASSED_FILE="$OUT_DIR/passed.txt"
FAILED_FILE="$OUT_DIR/failed.txt"
HUNG_FILE="$OUT_DIR/hung.txt"
SKIPPED_FILE="$OUT_DIR/skipped.txt"
: >"$PASSED_FILE"; : >"$FAILED_FILE"; : >"$HUNG_FILE"; : >"$SKIPPED_FILE"

echo "linux-test: toolchain $(swift --version 2>/dev/null | head -1)"
echo "linux-test: scratch   $SCRATCH_PATH"
echo "linux-test: output    $OUT_DIR"
echo "linux-test: nproc     $(nproc), test processes pinned: $PIN_NOTE"

# ---------------------------------------------------------------------------
# Build once. Loudly.
# ---------------------------------------------------------------------------
# A build failure here is not a test result and must never be reported as one.
# The suite had never built off Darwin at all before 9a7e797 — 398 copies of
# "no such module 'MynahMac'" — and a harness that swallowed that would have
# reported a clean run of zero tests.
echo "linux-test: building tests (this is the long pole on a cold scratch dir)"
BUILD_LOG="$OUT_DIR/build.log"
set +e
swift build --build-tests --scratch-path "$SCRATCH_PATH" 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS="${PIPESTATUS[0]}"
set -e
if (( BUILD_STATUS != 0 )); then
  die "\`swift build --build-tests\` failed with status $BUILD_STATUS. NO TESTS WERE RUN.
This is a build failure, not a test failure, and this script will not report a
count for a suite that was never linked. The whole log is at:
  $BUILD_LOG
First errors:
$(grep -m 5 -E '^.*error:' "$BUILD_LOG" 2>/dev/null || echo '  (no line matching error: — read the log)')"
fi

BIN_PATH="$(swift build --build-tests --scratch-path "$SCRATCH_PATH" --show-bin-path 2>/dev/null | tail -1)"
[[ -n "$BIN_PATH" && -d "$BIN_PATH" ]] \
  || die "\`swift build --show-bin-path\` did not name a directory that exists.
Got: '$BIN_PATH'. Without it there is no test binary to invoke per test."

# The xctest bundle on Linux is a plain ELF executable whose first positional
# argument is a test filter. Driving it directly rather than through
# `swift test --filter` is what makes per-test affordable: SwiftPM re-plans the
# build graph on every invocation, and 1700 graph re-plans is a different
# program from 1700 test runs.
RUNNER="$(find "$BIN_PATH" -maxdepth 1 -name '*.xctest' -type f 2>/dev/null | head -1)"
[[ -n "$RUNNER" && -x "$RUNNER" ]] \
  || die "no executable *.xctest bundle in $BIN_PATH after a successful --build-tests.
Contents:
$(ls -la "$BIN_PATH" 2>/dev/null | head -20)
If SwiftPM has changed where it puts the Linux test runner, teach this script the
new location rather than falling back to \`swift test\`, which cannot run one test
per process."
echo "linux-test: runner    $RUNNER"

# ---------------------------------------------------------------------------
# Enumerate.
# ---------------------------------------------------------------------------
# Under a timeout as well, because --list-tests goes through the same runner.
LIST_RAW="$OUT_DIR/list-tests.raw"
set +e
timeout --kill-after="$KILL_AFTER" "$PER_TEST_TIMEOUT" \
  swift test --list-tests --scratch-path "$SCRATCH_PATH" >"$LIST_RAW" 2>"$OUT_DIR/list-tests.err"
LIST_STATUS=$?
set -e
if (( LIST_STATUS == 124 || LIST_STATUS == 137 )); then
  die "\`swift test --list-tests\` itself hit the ${PER_TEST_TIMEOUT} timeout.
The enumeration goes through the same corelibs runner the tests do, so it can
wedge the same way. Run it again — the wedge point moves — and if it wedges
every time, that is a new finding worth recording rather than a number to raise."
fi
(( LIST_STATUS == 0 )) \
  || die "\`swift test --list-tests\` exited $LIST_STATUS. Nothing was enumerated, so nothing ran.
stderr:
$(head -20 "$OUT_DIR/list-tests.err" 2>/dev/null)"

# Ids look like Target.ClassName/testMethod. Anything else on stdout is build
# chatter and is dropped rather than fed to the runner as a filter.
grep -E '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*/[A-Za-z_][A-Za-z0-9_]*$' "$LIST_RAW" \
  | sort -u >"$IDS_FILE" || true
ENUMERATED="$(wc -l <"$IDS_FILE" | tr -d ' ')"
(( ENUMERATED > 0 )) \
  || die "--list-tests named no test ids at all, so this run verified nothing.
Raw output is at $LIST_RAW. An empty enumeration is the suite never having
started, not an empty suite."
echo "linux-test: enumerated $ENUMERATED test ids"

PARTIAL=0
if [[ -n "$ID_FILTER" ]]; then
  PARTIAL=1
  grep -E "$ID_FILTER" "$IDS_FILE" >"$IDS_FILE.filtered" || true
  mv "$IDS_FILE.filtered" "$IDS_FILE"
  SELECTED="$(wc -l <"$IDS_FILE" | tr -d ' ')"
  (( SELECTED > 0 )) \
    || die "MYNAH_LINUX_TEST_FILTER='$ID_FILTER' matched none of the $ENUMERATED enumerated ids.
A filter that matches nothing is a run that verifies nothing while exiting 0,
which is the hollow suite in miniature."
  echo "linux-test: PARTIAL RUN — filter '$ID_FILTER' selected $SELECTED of $ENUMERATED ids."
  echo "linux-test: a filtered run is NOT a verification of the suite."
  ENUMERATED="$SELECTED"
fi

if [[ -n "$MIN_TESTS" ]]; then
  if (( PARTIAL )); then
    echo "linux-test: floor MYNAH_LINUX_MIN_TESTS=$MIN_TESTS not applied to a filtered run."
  elif (( ENUMERATED < MIN_TESTS )); then
    die "--list-tests found $ENUMERATED ids, under the floor of $MIN_TESTS, so tests went missing rather than passing.
Worth checking in this order:
  1. a test target fell out of the package graph. Package.swift decides what
     exists as it is READ, so a missing vendored library removes targets instead
     of failing anything. Compare: swift build --build-tests --scratch-path $SCRATCH_PATH
  2. tests really were deleted on purpose, in which case lower
     MYNAH_LINUX_MIN_TESTS in the same commit that deleted them, so the new floor
     is reviewed alongside the removal."
  fi
fi

# ---------------------------------------------------------------------------
# Run. One process per id, sequentially.
# ---------------------------------------------------------------------------
{
  echo "Linux per-test run — scripts/linux-test.sh"
  echo "toolchain: $(swift --version 2>/dev/null | head -1)"
  echo "runner:    $RUNNER"
  echo "started:   $(date -u '+%Y-%m-%d %H:%M:%S +0000')"
  echo "per-test timeout: $PER_TEST_TIMEOUT (SIGKILL $KILL_AFTER later)"
  echo "pinning:   $PIN_NOTE"
  if (( PARTIAL )); then
    echo "PARTIAL RUN: filter '$ID_FILTER' selected $ENUMERATED ids. NOT a verification of the suite."
  fi
  echo
} >"$LOG"

PASSED=0; FAILED=0; HUNG=0; SKIPPED=0; RAN=0
INDEX=0
START_EPOCH="$(date +%s)"

while IFS= read -r ID; do
  [[ -n "$ID" ]] || continue
  INDEX=$(( INDEX + 1 ))
  SAFE="${ID//\//__}"
  SAFE="${SAFE//./_}"
  TEST_LOG="$OUT_DIR/per-test/$SAFE.log"

  set +e
  timeout --kill-after="$KILL_AFTER" "$PER_TEST_TIMEOUT" \
    ${PIN[@]+"${PIN[@]}"} "$RUNNER" "$ID" >"$TEST_LOG" 2>&1
  STATUS=$?
  set -e

  # `timeout` reports 124 when its own deadline fired, and 128+9=137 when the
  # follow-up SIGKILL was needed. Both mean the same thing here: the process was
  # still alive when the harness stopped waiting. Neither is a test failure and
  # neither is ever written to the failed list.
  if (( STATUS == 124 || STATUS == 137 )); then
    OUTCOME="HUNG"
    HUNG=$(( HUNG + 1 ))
    printf '%s\n' "$ID" >>"$HUNG_FILE"
  elif (( STATUS == 0 )); then
    # A zero exit with nothing executed is a filter that matched nothing, not a
    # pass. Counting it as one is how a green result gets bought by running
    # fewer tests.
    if grep -qE 'Executed 0 tests' "$TEST_LOG"; then
      OUTCOME="NOTRUN"
      FAILED=$(( FAILED + 1 ))
      printf '%s\t(id matched no test in the bundle)\n' "$ID" >>"$FAILED_FILE"
    elif grep -qE 'with 1 test skipped' "$TEST_LOG"; then
      OUTCOME="skipped"
      SKIPPED=$(( SKIPPED + 1 )); RAN=$(( RAN + 1 ))
      printf '%s\n' "$ID" >>"$SKIPPED_FILE"
    else
      OUTCOME="passed"
      PASSED=$(( PASSED + 1 )); RAN=$(( RAN + 1 ))
      printf '%s\n' "$ID" >>"$PASSED_FILE"
    fi
  else
    OUTCOME="failed"
    FAILED=$(( FAILED + 1 )); RAN=$(( RAN + 1 ))
    printf '%s\t(exit %d)\n' "$ID" "$STATUS" >>"$FAILED_FILE"
  fi

  printf '[%d/%d] %-7s %s\n' "$INDEX" "$ENUMERATED" "$OUTCOME" "$ID"

  {
    printf '=== %s :: %s ===\n' "$OUTCOME" "$ID"
    if [[ "$OUTCOME" == "HUNG" ]]; then
      printf 'HUNG: %s did not return within %s and was terminated by the harness.\n' \
        "$ID" "$PER_TEST_TIMEOUT"
      printf 'This is the corelibs RunLoop wedge, not a slow test. Do not raise the timeout.\n'
    fi
    # The per-test file keeps XCTest's own two-line "All tests" epilogue
    # verbatim; the aggregate log does not, because assert-test-run.sh reads the
    # FIRST such block it finds and would otherwise judge the whole suite by
    # test number one. The single aggregate block is written at the end.
    grep -vE "Test Suite 'All tests' (passed|failed) at" "$TEST_LOG" \
      | grep -vE '^\s*Executed [0-9]+ tests?,' || true
    echo
  } >>"$LOG"
done <"$IDS_FILE"

ELAPSED=$(( $(date +%s) - START_EPOCH ))

# ---------------------------------------------------------------------------
# Every id has to have landed somewhere. If this arithmetic does not close, the
# counts below are not describing the run.
# ---------------------------------------------------------------------------
ACCOUNTED=$(( PASSED + SKIPPED + FAILED + HUNG ))
(( ACCOUNTED == ENUMERATED )) \
  || die "accounting does not close: $ACCOUNTED outcomes for $ENUMERATED ids.
passed $PASSED, skipped $SKIPPED, failed $FAILED, hung $HUNG. The loop lost ids,
so no number in this run can be trusted. Do not paper over this with a tolerance."

# ---------------------------------------------------------------------------
# The log assert-test-run.sh consumes.
# ---------------------------------------------------------------------------
# That script speaks XCTest, which has two outcomes and no word for a hang. The
# harness keeps hangs separate everywhere it reports for a person — the banner
# below, $HUNG_FILE, the per-test lines — and folds them into the FAILURE number
# of this one compatibility line, never into the executed number.
#
# The direction of that conflation is deliberate: a hang must never be cheaper
# than a failure. Counting a hang as executed-and-passing would be the hollow
# suite; counting it as a failure makes assert-test-run.sh's `FAILURES > 0` gate
# fire, which is the correct verdict on a run containing one.
#
# EXECUTED counts what actually ran to a verdict. A hung test executed nothing,
# so it is not in that number — which means a run full of hangs sinks under the
# floor rather than sliding under it.
GATE_FAILURES=$(( FAILED + HUNG ))
{
  echo "--- harness summary (scripts/linux-test.sh) ---"
  echo "ids enumerated: $ENUMERATED"
  echo "passed:  $PASSED"
  echo "failed:  $FAILED"
  echo "HUNG:    $HUNG"
  echo "skipped: $SKIPPED"
  echo "executed (reached a verdict): $RAN"
  if (( HUNG > 0 )); then
    echo
    echo "hung test ids (also in $HUNG_FILE):"
    sed 's/^/  /' "$HUNG_FILE"
  fi
  echo
  echo "The line below is written in XCTest's wording so scripts/assert-test-run.sh"
  echo "can read this file. Its failure count is failed + hung ($FAILED + $HUNG);"
  echo "XCTest has no word for a hang and a hang must not be the cheaper outcome."
  echo "Test Suite 'All tests' $( (( GATE_FAILURES > 0 )) && echo failed || echo passed ) at $(date -u '+%Y-%m-%d %H:%M:%S.000')"
  echo "	 Executed $RAN tests, with $SKIPPED tests skipped and $GATE_FAILURES failures (0 unexpected) in ${ELAPSED}.000 (${ELAPSED}.000) seconds"
} >>"$LOG"

# ---------------------------------------------------------------------------
# Banner, then the gate — in that order, and only now.
# ---------------------------------------------------------------------------
echo
echo "linux-test: $RAN of $ENUMERATED ids reached a verdict — $PASSED passed, $FAILED failed, $SKIPPED skipped, $HUNG HUNG, in ${ELAPSED}s"
echo "linux-test: log $LOG"
echo "linux-test: hung ids $HUNG_FILE   failed ids $FAILED_FILE"
if (( HUNG > 0 )); then
  echo
  echo "linux-test: $HUNG test(s) HUNG and were terminated after $PER_TEST_TIMEOUT:"
  sed 's/^/  HUNG  /' "$HUNG_FILE"
  echo "linux-test: the wedge point moves between runs — it is a race in corelibs,"
  echo "linux-test: not a property of these tests. Do not skip them and do not raise"
  echo "linux-test: the timeout; both make the suite finish by testing less."
fi

# Only after the run has exited. A log gated while it is still being written
# fails as if nothing ran at all.
[[ -s "$LOG" ]] || die "the aggregate log at $LOG is empty after a run that reported $ENUMERATED ids."

ASSERT="$REPO_ROOT/scripts/assert-test-run.sh"
if [[ -f "$ASSERT" ]]; then
  echo
  echo "linux-test: gating the log with scripts/assert-test-run.sh"
  # assert-test-run.sh's defaults are the build Mac's graph, which is not this
  # one: off Darwin the Mac targets are not declared and KokoroEngineTests does
  # not exist, so both its floor and its rot check have to be told Linux's
  # numbers.
  #
  # **Where these fall back to this run's own figures they are a consistency
  # check, not a second opinion.** A floor set to what just ran cannot fail, and
  # neither can a skip ceiling set to what was just skipped. For the floor that
  # is fine, because the floor that does the work is MYNAH_LINUX_MIN_TESTS,
  # checked against the enumeration before a single test ran. The SKIP CEILING
  # has no such counterpart: a caller who leaves MYNAH_MAX_SKIPPED_TESTS unset
  # has nothing standing between them and a suite that goes quiet by skipping,
  # which is the exact hole assert-test-run.sh was written for. CI sets it — see
  # .github/workflows/linux.yml — and so should anyone running this by hand who
  # intends the result to mean something.
  ASSERT_FLOOR="${MYNAH_MIN_EXECUTED_TESTS:-$RAN}"
  set +e
  MYNAH_MIN_EXECUTED_TESTS="$ASSERT_FLOOR" \
  MYNAH_SMALLEST_TEST_TARGET="${MYNAH_SMALLEST_TEST_TARGET:-$ENUMERATED}" \
  MYNAH_FLOOR_SITS_UNDER="${MYNAH_FLOOR_SITS_UNDER:-0}" \
  MYNAH_MAX_SKIPPED_TESTS="${MYNAH_MAX_SKIPPED_TESTS:-$SKIPPED}" \
    bash "$ASSERT" "$LOG"
  ASSERT_STATUS=$?
  set -e
else
  ASSERT_STATUS=0
  echo "linux-test: no scripts/assert-test-run.sh to gate with — skipping that check."
fi

if (( HUNG > 0 || FAILED > 0 )); then
  echo
  echo "linux-test: FAILED — $FAILED failing, $HUNG hung."
  exit 1
fi
if (( ASSERT_STATUS != 0 )); then
  echo
  echo "linux-test: FAILED — the run had no failures or hangs, but scripts/assert-test-run.sh"
  echo "linux-test: rejected the log above. Fix the gate's numbers, not the log."
  exit 1
fi
if (( PARTIAL )); then
  echo
  echo "linux-test: PARTIAL RUN passed. This verified $ENUMERATED ids and says nothing"
  echo "linux-test: about the rest of the suite."
fi
echo "linux-test: OK"
