#!/usr/bin/env bash
# Runs scripts/linux-test.sh in the pinned Linux container, from the build Mac.
#
#   bash scripts/linux-test-in-docker.sh
#   MYNAH_LINUX_TEST_FILTER='AboutTests' bash scripts/linux-test-in-docker.sh
#
# This file exists for the flags. The image is pinned in
# docker/linux-test.Dockerfile because a tag that drifts silently changes what
# was tested; the `docker run` line lives here because it carries two choices
# that are results rather than preferences.
#
# ## Where the single CPU is applied, and why not here by default
#
# CONCURRENCY WIDTH IS THE TRIGGER for the corelibs run-loop wedge: pinning to a
# single CPU took the single-process suite from 3 tests to 920. That pinning is
# real and it is not optional — but scripts/linux-test.sh applies it per test
# process with `taskset -c 0`, not to the whole container, because the compiler
# is not what wedges and pinning the build too would buy a tenfold slower cold
# build for no change in the hang count.
#
# MYNAH_LINUX_TEST_CPUSET pins the whole container as well, which is the
# like-for-like reproduction of the original measurement. It is empty by default.
# Setting it makes the build crawl; set it when comparing hang counts against
# that measurement, not to make a run go faster.
#
# ## The scratch volume is not in the checkout
#
# The checkout is mounted read-write, because SwiftPM writes Package.resolved at
# the package root and there is no flag that moves it. Everything else it writes
# goes to a named Docker volume mounted over /linux-scratch, so no Linux build
# product ever lands in the Mac's .build/ — the same directory a Mac toolchain
# may be using in this checkout at the same moment.
#
# **Package.resolved is the one file this run can dirty in the working tree.**
# Linux writes it, macOS deletes it. Never `git add -A` from the repo root after
# running this; add paths explicitly.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="${MYNAH_LINUX_TEST_IMAGE:-mynah-linux-test}"
BASE_IMAGE="swift:6.0.3-jammy"
VOLUME="${MYNAH_LINUX_TEST_VOLUME:-mynah-linux-scratch}"
CPUSET="${MYNAH_LINUX_TEST_CPUSET:-}"

command -v docker >/dev/null 2>&1 \
  || die "no \`docker\` on PATH. This is the only route to a Linux build from a Mac:
Package.swift is Swift compiled for the host, so a cross-compile from macOS
assembles the Mac graph and can never have worked."

docker info >/dev/null 2>&1 \
  || die "the Docker daemon is not answering. Start Docker Desktop and run this again."

# The base image is already on the build Mac. Not pulling is deliberate: a pull
# here would be a silent toolchain change on a machine where the pinned one is
# already present.
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 \
  || die "$BASE_IMAGE is not present locally and this script will not pull one.
That tag is the toolchain commit 9a7e797 verified against, and fetching a fresh
copy mid-investigation is how two runs stop being comparable. If it is genuinely
absent, pull it deliberately and say so in the commit:
  docker pull $BASE_IMAGE"

echo "linux-test-in-docker: building $IMAGE from $BASE_IMAGE (no apt layer, so this is quick)"
docker build -q -f "$REPO_ROOT/docker/linux-test.Dockerfile" -t "$IMAGE" "$REPO_ROOT"

# `docker volume create` is idempotent and touches nothing that already exists.
# Nothing in this script stops, kills or removes a container: the wedged ones
# parked on this Mac are evidence from the hang investigation.
docker volume create "$VOLUME" >/dev/null

CONTAINER="mynah-linux-test-$$"
CPUSET_ARGS=()
if [[ -n "$CPUSET" ]]; then
  CPUSET_ARGS=(--cpuset-cpus="$CPUSET")
  echo "linux-test-in-docker: whole container pinned to CPU(s) $CPUSET — the build will be slow."
fi
echo "linux-test-in-docker: running as $CONTAINER"

# --rm because this container is disposable; the run's output lives in the
# volume and is copied out below.
set +e
docker run --rm \
  --name "$CONTAINER" \
  ${CPUSET_ARGS[@]+"${CPUSET_ARGS[@]}"} \
  -v "$REPO_ROOT:/workspace" \
  -v "$VOLUME:/linux-scratch" \
  -e MYNAH_LINUX_TEST_FILTER="${MYNAH_LINUX_TEST_FILTER:-}" \
  -e MYNAH_LINUX_TEST_TIMEOUT="${MYNAH_LINUX_TEST_TIMEOUT:-60s}" \
  -e MYNAH_LINUX_TEST_KILL_AFTER="${MYNAH_LINUX_TEST_KILL_AFTER:-10s}" \
  -e MYNAH_LINUX_TEST_CPU="${MYNAH_LINUX_TEST_CPU:-0}" \
  -e MYNAH_LINUX_MIN_TESTS="${MYNAH_LINUX_MIN_TESTS:-}" \
  -e MYNAH_MIN_EXECUTED_TESTS="${MYNAH_MIN_EXECUTED_TESTS:-}" \
  -e MYNAH_MAX_SKIPPED_TESTS="${MYNAH_MAX_SKIPPED_TESTS:-}" \
  -w /workspace \
  "$IMAGE" \
  bash scripts/linux-test.sh
STATUS=$?
set -e

echo "linux-test-in-docker: harness exited $STATUS"
echo "linux-test-in-docker: the run's log and id lists are in the $VOLUME volume at /linux-scratch/test-run."
echo "linux-test-in-docker: read them without a rebuild with:"
echo "  docker run --rm -v $VOLUME:/linux-scratch $BASE_IMAGE cat /linux-scratch/test-run/hung.txt"
exit "$STATUS"
