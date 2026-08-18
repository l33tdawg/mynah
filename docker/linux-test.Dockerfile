# The Linux test box, pinned.
#
#   docker build -f docker/linux-test.Dockerfile -t mynah-linux-test .
#   bash scripts/linux-test-in-docker.sh
#
# ## Why an image and not just a `docker run swift:6.0.3-jammy`
#
# Because the tag is load-bearing and belongs in one auditable place. The
# corelibs run-loop wedge that scripts/linux-test.sh exists to survive was
# characterised on 6.0.3 specifically (commit 9a7e797), and it reproduces on
# 6.0, 6.1 and 6.2 as well — so a floating `swift:latest` would move the
# toolchain under the harness without moving anything in this repository, and
# the next person would be comparing two runs that were never the same run.
#
# `scripts/linux-test-in-docker.sh` carries the `docker run` line, because that
# is the part with flags a person has to get right (see --cpuset-cpus below);
# this file carries the part that must not drift.
#
# ## Why there is no apt layer
#
# There is deliberately nothing to install. The base image already has the
# toolchain, git and ca-certificates, so this builds offline in about a second
# from an image that is already on the build Mac — `docker images | grep swift`
# lists swift:6.0.3-jammy. Adding an apt-get here would make the first run of
# this harness depend on Ubuntu's mirrors being up, which is a new way for a
# test run to fail that has nothing to do with the tests.
#
# If a test surface later needs a system tool (ffmpeg is the likely one — see
# UnreadableVoiceNote), add it here in the same commit that adds the tests that
# need it, so the image and the suite cannot disagree about what is provisioned.
FROM swift:6.0.3-jammy

# The checkout is mounted here read-write by scripts/linux-test-in-docker.sh.
WORKDIR /workspace

# **Linux build products must never land in the macOS .build directory.** The
# same checkout is mounted into this container while a Mac toolchain is using
# .build/ in the host filesystem, and SwiftPM would happily interleave two
# triples' worth of module caches in one scratch root. This path is outside the
# mount entirely — a container-local directory (or a named volume, which is what
# the wrapper attaches) — so nothing this container builds is visible to the Mac
# at all.
ENV MYNAH_LINUX_SCRATCH_PATH=/linux-scratch

# Keep SwiftPM's own caches container-local too, for the same reason.
ENV XDG_CACHE_HOME=/linux-scratch/cache

CMD ["bash", "scripts/linux-test.sh"]
