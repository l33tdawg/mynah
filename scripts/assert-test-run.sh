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
# target is Kokoro's 38.
#
# Raise it in the same commit that adds a batch of tests. Test counts only ever
# grow; the only thing that lowers them is deleting tests, which ought to be
# reviewed anyway.
#
# **And it rotted anyway, by exactly the mechanism described above.** 1815 was
# 25 under the 1840 of the day. The suite has since grown, so a build with
# onnxruntime unstaged sailed over it — waved through, shipping an appliance
# whose speech engine is missing. Confirmed during the 1.7.2 re-audit by
# arithmetic, not by a build failing, which is the only reason it was caught.
#
# The rule was right; following it was left to memory, which is the part that
# does not work. Restated as arithmetic anyone can redo in one line, against a
# count measured on 2026-08-05 rather than remembered:
#
#   measured      1892
#   without Kokoro  1854   (1892 - 38)
#   floor           1867   (25 under measured, 13 above the failure it must catch)
#
# **And it rotted a third time, which is when the rule stopped being written down
# and started being checked.** Restating the arithmetic in a comment fixed the
# number and not the mechanism: by 5 August the suite was 1915 and the floor was
# still 1867, so losing KokoroEngine would have left 1877 — comfortably over.
# Twice caught by a person doing arithmetic, and a gate that depends on somebody
# remembering to redo a calculation is not a gate.
#
# So the rule is now an assertion this script makes about itself, below. Rot
# arrives as a build failure carrying the new number rather than as a silent
# hole. See the check on SMALLEST_TEST_TARGET.
#
#   measured      2438   (2.1.1, three defects the owner found by using 2.1.0;
#                         2407 at 2.1.0, the message wake bus;
#                         2348 at 2.0.0-beta.11, 2316 at beta.10, 2313 at beta.9,
#                         2312 at beta.8, 2304 at beta.7, 2298 at beta.6,
#                         2111 at 1.9.0)
#   without Kokoro  2400   (2438 - 38)
#   floor           2426   (12 under measured, 26 above the failure it must catch)
#
# 2111 to 2157 is fifteen tests for the WhatsApp Swift transport, four for the
# menu-bar mark, eighteen for the channel abstraction that lets Signal and
# WhatsApp run together, and nine for the acknowledgement ledger.
#
# 2157 to 2214 is the half that makes the feature reachable from the running app
# rather than only from a test: one for merging across channels, thirty-seven for
# the choice itself (`ChannelSet`'s routing, what is remembered between launches,
# the third LaunchAgent, and pairing read as a line of text), and nineteen for
# the places where "the same route" still had a Signal-shaped assumption in it —
# a log scrub that could not see a WhatsApp number, a voice note filed as a
# document, an attachment note that said Signal whatever it was, and a promise
# that would have been apologised for down the wrong channel. Every one of those
# nineteen was put back and reddened exactly its own test before this number
# moved.
#
# 2214 to 2231 is a 43-agent adversarial audit of the branch, which confirmed 21
# defects — five of them critical, three of those in code written the same day by
# the hand that was fixing the previous round. Eight tests cover the third
# LaunchAgent (installed, removed, restarted when the allowlist changes, and not
# reported as running when it never started); nine cover what the audit found,
# including an acknowledgement ledger that walked its watermark over a redelivered
# message, a loopback API with no authentication in front of it, and a refused
# sender's phone number written into a log. Every one was mutated back before this
# number moved; two of the mutations survived the first attempt, and the tests
# were rewritten rather than the finding waved off.
#
# 2231 to 2241 is the SECOND audit of the same branch, which confirmed 27 more —
# five critical, and five of the total introduced by round two's own repairs. The
# ten here cover the ones a value can reach: the acknowledgement that destroyed a
# message whose reply never left the Mac, conversation threads orphaned by a key
# that gained a channel prefix, a WhatsApp allowlist that could only ever be the
# Signal number, and a Signal helper started for an appliance that had turned
# Signal off.
#
# 2241 to 2264 is the first release where the number moved because the product
# was USED rather than audited. 2.0.0-beta.1 was installed from the DMG on 7
# August and answered two WhatsApp messages on the owner's phone; reading the
# logs of that exchange found a defect no agent had — his chat was addressed as
# `161228928336031@lid` and filed under that, so the day WhatsApp addresses it as
# his number instead, the appliance starts a second conversation and forgets the
# first mid-sentence. Twelve of the twenty-three cover that and the migration
# that carries the existing history across. The other eleven are the four
# findings the second audit reported and this branch shipped without: a spool
# whose numbering restarted leaving the acknowledgement watermark stranded above
# every sequence it would ever emit, a reconcile latch that answered the owner's
# own button press with a log line, "this build can only do Signal" said to
# owners whose build does WhatsApp perfectly well, and media caches that had
# never deleted anything. Every one was mutated back; the tenth mutation survived
# the first attempt and the test was rewritten rather than the finding waved off.
#
# 2264 to 2288 is the second defect found by USE rather than audit, and the most
# expensive one this branch has shipped: link WhatsApp and not Signal, and the
# whole appliance declined to install. `SignalServiceConfiguration.current()`
# required a linked Signal account before it would return anything at all, and
# `nil` from there is read as `cannotTell` — which by design changes nothing. No
# LaunchAgent, no error, and a Settings row reporting an unreachable phone over an
# appliance that was never started.
#
# Sixteen tests, in two halves. Seven drive `current()` itself, which had never
# been under test at all: it read the real accounts.json and the real PATH, so on
# any Mac with Signal linked — every Mac this is developed on — the WhatsApp-only
# branch was unreachable from a test. Those two reads are now injected. Four cover
# what launchd is handed for a WhatsApp-only appliance, and five cover what the
# window says about a Mac whose only channel is one the old code could not see.
# Five mutations, every one reddened its own tests.
#
# 2288 to 2294 is the same defect's other half, found by asking what an owner
# already stuck on beta.3 has to do. Pairing records the owner's number from the
# `connected` event — but that event carried `name ?? id`, so on any account with
# a push name the sheet was handed a display name, correctly refused to read a
# phone number out of it, and stored nothing. Whether Mynah could answer WhatsApp
# came down to whether the owner had ever set a display name. Invisible with
# Signal linked, because the allowlist falls back to that number; fatal without.
#
# Six tests. One is the JID surviving an account that has a name — the assertion
# it replaces, `.connected(user: "Dhillon")`, was the defect written down and
# passing. Five cover the repair: the number is recovered from `me.id` in the
# session already on disk, so an affected Mac fixes itself on launch instead of
# being told to unlink and scan again through a button that is hidden precisely
# because it is paired.
#
# **Two of these turned red on the first run for the right reason**, and it is
# worth recording: the new fallback reads a session directory whose default is
# the real one, so tests that did not name a path read the developer's own paired
# WhatsApp account. Every call site in the suite now passes one explicitly.
#
# **2294 down to 2287 is the only fall this number has ever taken, and it is a
# deletion rather than a loss.** `MCPAgentDirectoryTests`' seven tests went with
# the agent-roster path they were written for: the Agents panel was removed in
# 3bb085b, and the boot fetch that fed it outlived it by a release — every launch
# read `GET /v1/agents`, put the names to `sage_find_agent`, and threw the answer
# away, because nothing had read `ApplianceRoster.phase` since the panel went.
#
# The floor is deliberately NOT lowered with it. 2287 still clears 2276, and the
# one failure this floor exists to catch — losing KokoroEngineTests, 38 tests —
# would leave 2249 and still be caught. What a deletion changes is the headroom
# above the floor, not the floor: it now sits 11 under rather than 18, which
# means 27 more tests before the rot check fires rather than 20. Both numbers are
# stated above so the next person reads them instead of subtracting.
#
# 2287 to 2298 is eleven for what a call opens with. His own call on 8 August
# opened by reading his task list out, on a prompt that has said "Do not read my
# task list out" since the day it was written — because the same paragraph also
# asked for "the one thing that is still open between us", and the daemon had
# been up since 06:44 with nothing said in messages, so there was no thread to
# continue and something open in the backlog was the only thing that fitted.
#
# Three changes, five mutations, each killing exactly its own test. Nothing to
# pick up now means no model call at all rather than a model asked nicely to
# behave; the briefing runs through its own closure so its request — a page of
# machine-written instruction — stops becoming turn zero of the call in the
# owner's voice; and the phrase that invited it is gone. Note the headroom this
# spends: the floor now sits 22 under, leaving 16 tests before the rot check
# fires. The next release that adds more than sixteen has to raise it.
#
# 2298 to 2304 is a fourteen-agent adversarial sweep of the whole 2.0 beta line,
# run because two earlier audits had passed this branch and the two worst defects
# in it were then found by the owner using the product. Thirty findings raised,
# fifteen survived refutation.
#
# The six tests are for the two that could lose something. Three cover a call
# that could not have worked at all on an Anthropic brain: beta.6 started a
# call's history at a single assistant turn, and Anthropic rejects a request
# whose first non-system message is not the user's. Nothing normalised it and
# there is no retry, so every //call an Anthropic owner made would have 400'd —
# shipped four hours earlier and caught by nothing in the suite. Three cover the
# acknowledgement ledger's epoch guard, which fired in both directions and so
# noticed a recreated spool only through `deliver`, while `WhatsAppClient`
# settles directly for anything the allowlist refuses.
#
# The floor moves 2276 to 2292 here rather than waiting to be forced: at 2304 it
# had ten tests of headroom left, and the next release to add eleven would have
# gone red on a green suite. CI's pair moves with it — 2238 to 2254 — because
# raising one alone is what turned the runner red the first time.
#
# 2304 to 2312 is eight for the first thing the after-the-call queue was ever
# asked to do on a real call, which it did not do. The owner asked for a file
# after the call at 18:11:56, heard "On it — let me pull that together" at
# 18:11:57, and hung up at 18:12:02 — six seconds into a turn that had not yet
# emitted its tool call, and hang-up cancels the turn. Nothing queued, nothing on
# disk, and a promise made out loud that nothing anywhere revisits.
#
# The design had that written down as a known gap and called it an edge case. One
# real call showed it is the ordinary one: people ring off once they have said
# the thing they rang to say. The request is now written from the caller's own
# sentence the moment it is recognised, before any model runs, and the model's
# own tool call replaces it when it gets there. Three mutations: the fail-safe
# never writing (5 red), the replacement removed (2), the replacement scoped to
# the call rather than the turn (1).
#
# 2312 to 2313 is the regression the owner found by reading WhatsApp while both
# channels were linked. The proactive watch reused the after-the-call fallback,
# which deliberately chose Signal first, so every unprompted agent reply, task
# digest and reminder went to Signal only. The owner ruled that news goes to
# both linked channels, accepting two copies. The new source-wiring guard reddens
# both the old early return from Signal and a loop restricted to the first
# recipient; after-the-call attachments remain single-recipient replies.
#
# 2313 to 2316 is the WhatsApp screenshot bug: the live model was forbidden
# from reading sent-message history, then its private truth-guard correction
# and rejected draft were persisted as owner-visible conversation. It falsely
# confessed that genuine ids were invented and duplicated both sends. The three
# tests cover outbox-without-resend, the read-only allowlist/prompt contract and
# history containing only the real request plus delivered reply.
#
# 2316 to 2348 is beta.11's delivery audit: fourteen tests make a completed
# WhatsApp turn crash-durable without recording an answer before it reaches the
# owner or repeating its tools on replay, including partial coalesced spools,
# LID identity changes, interleaved announcements, attachment retries and the
# textless MP4/MOV no-op. Ten cover exact after-call origin recovery and queue
# retention until a report or file really delivers. Four pin ASR fallback
# telemetry, and three require the Pages beta link and release workflow to agree
# on a complete four-asset distribution and detach the verified DMG safely. The
# final test prevents a Rosetta parent shell from selecting an x86 XCTest runner
# for the arm64 release bundle.
#
# 2348 to 2407 is 2.1.0's message wake bus, and the split is worth reading
# because only ten of the forty-nine are about the network at all.
#
# Ten of them exist because of one defect, and they are the ones to read
# first. The client was reading the event stream through Foundation's
# `AsyncBytes.lines`, which does not yield an empty line — and in server-sent
# events the empty line is the dispatch. Against the owner's live node the
# frame arrived, was assembled, and was never delivered: `id`, `event` and
# `data` at t=0.01s, then nothing until a heartbeat at t=15s. The node was
# perfect and the feature was inert. Six tests now cover a byte splitter that
# keeps blank lines, and four drive the whole client against a stubbed stream
# through a `URLProtocol`; putting `.lines` back reddens three of them. Nothing
# over the reader alone could have caught it, because a reader test feeds it
# the blank line the transport was eating.
#
# Twenty-one cover the two halves that can be wrong invisibly. The signing
# derivation is pinned against message-byte vectors — not signature vectors, and
# that distinction cost the first version of these tests: CryptoKit's Ed25519 is
# hedged, so signing identical bytes twice yields two different signatures and a
# pinned signature hex is a pinned random number. The message is the actual
# contract with the node's `internal/auth/ed25519.go` and is deterministic. The
# SSE reader is tested for the two failures a happy-path check cannot see — a
# heartbeat comment mistaken for an event, and a dispatch that never fires —
# rather than for the frames it will usually get right.
#
# Six cover what a wake is allowed to override, which is the part with a cost to
# the owner rather than to the appliance: it skips the poll interval, and it
# does not skip the proactive switch or quiet hours. Mutating the guard above
# quiet hours reddens one of them, which is the point of writing it that way.
#
# Four are source scans, because `main.swift` is an executable target and cannot
# be imported — the precedent AfterTheCallTests already set. Without them the
# whole feature can be perfect and unreachable: nothing else in this file fails
# if the daemon never constructs the bus, never latches its wakes, never hands
# the latch to the watch, or never cancels the stream on shutdown. A fifth
# asserts the window does NOT dial it, because the node grants one wake lease
# per agent and a second consumer would lock the daemon out for five minutes at
# a time.
#
# One deserves naming for what it did not catch. The explicit
# `if line.hasPrefix(":")` comment guard in the SSE reader turns out to be
# redundant — a comment line's field name parses as empty and the `default:`
# case ignores it anyway — so mutating that line away leaves the suite green.
# That was found by mutating rather than assumed, the code now says so where a
# reader will see it, and the test was rewritten to pin the observable contract
# instead of pretending to guard one line. A test that claims a guarantee it
# does not hold is worse than no test.
#
# 2407 to 2438 is 2.1.1, and all three defects in it were found by the owner
# USING 2.1.0 rather than by anyone reading the code — which is the third
# release running where that is true, and the reason the note at the bottom of
# this file about preferring his reports still stands.
#
# Fifteen cover a relayed agent message arriving whole. It was cut at 160
# characters and his report was that he "always" had to ask for the rest, so the
# excerpt was buying nothing and costing a question every time. Ten of the
# fifteen are `AnnouncementParts`, which sends a long message as several rather
# than one with its end missing — his instruction, and splitting rather than
# summarising because `ProactiveWatch`'s own third rule is that nothing is
# invented. Two existing tests changed sides here: one pinned the 160-character
# cut and now pins the opposite, with the old reasoning quoted in place so the
# reversal is readable rather than mysterious.
#
# **The security half of that old cap did not survive review, and that is worth
# recording.** Its stated reason was that an unbounded relay lets a remote agent
# push whatever it likes into the owner's thread. A cap does not stop an
# injection, it truncates one, and `intent` sat on the same line, written by the
# same remote agent, with no bound at all. What actually makes a relay safe is
# the frame `RelayedAgentTextTests` asserts, which is untouched.
#
# Sixteen cover `sage_timeline`, from a 43-second turn in bridge.log where the
# appliance was refused twice by its own memory and answered out of four web
# searches instead. The node caps a timeline at 31 days and its own tool schema
# offers a full year as the example, so the model copied what it was shown. Four
# of the sixteen exist because narrowing a range silently would be worse than
# the refusal it replaces: a month reported as a year is a confident false
# statement produced by us.
#
# The bridge's
# own 88 JavaScript tests are NOT in this number and never will be: they run
# under `node --test` from scripts/provision-whatsapp-bridge.sh, which is its
# own gate with its own per-file check. Two suites in two languages, and this
# one counts only what SwiftPM executes — a floor that tried to cover both would
# be a floor that moves for reasons this script cannot see.
#
# **The nine are the ones worth naming.** An audit of this release found that
# `WhatsAppClient` acknowledged a refused message by sending the bridge a
# cumulative watermark, which retired the owner's still-unanswered message along
# with it — the exact loss the whole durable path was built to prevent. Fifteen
# tests over that transport passed while it was live, because reaching the
# acknowledgement path needed a running socket and none of them had one. The
# nine drive it without one.
#
# **1.9.0 is the first time this fired rather than being raised ahead of it**,
# and it fired exactly as designed: a green suite, 2111 executed and 0 failures,
# stopped by a floor that could no longer see a missing target. 2080 to 2111 in
# one release — thirteen tests for the directory-scope fix and eighteen from the
# 1.8.5 work before it — spent the room the previous raise bought. Nothing was
# wrong with the run; the gate had simply gone blind, which is the one thing it
# is built to notice about itself.
#
# **1.7.5 raised it by 26 and that is the whole point of the rule.** The floor
# was 1916, which is exactly the without-Kokoro number for this suite — so the
# gate had drifted to the edge where losing the entire target would have gone
# unnoticed, purely because the suite grew. Nobody changed the gate; arithmetic
# did. That is what FLOOR_SITS_UNDER exists to make automatic.
#
# **The check caught its own author within the hour.** 1890 was set from a run of
# 1915, on the "25 under" rule — and 25 under is wrong, because the check fires
# at floor + 38. This release then added thirteen more tests and the gate went
# red on a green suite, which is exactly the behaviour asked of it. See
# FLOOR_SITS_UNDER for the arithmetic that replaced the rule of thumb.
#
# The runner's number is NOT this one and lives in .github/workflows/release.yml:
# CI does not stage vendor/onnxruntime, so KokoroEngineTests is absent from its
# graph and its measured count is 38 lower. Two environments, two floors, both to
# be maintained — raising this one alone is what turned CI red the first time.
MIN_EXECUTED="${MYNAH_MIN_EXECUTED_TESTS:-2426}"

# The smallest thing whose disappearance this gate has to notice.
#
# KokoroEngineTests, at 38 tests: Package.swift decides whether that target
# exists by looking for vendor/onnxruntime/lib/libonnxruntime.dylib as the
# manifest is read, so an unstaged dylib removes the target from the graph rather
# than failing anything. A floor that cannot see a 38-test hole cannot see any
# target loss at all.
SMALLEST_TEST_TARGET="${MYNAH_SMALLEST_TEST_TARGET:-38}"

# How far under the measured count a freshly-set floor sits.
#
# **Not 25, and the difference is the whole reason this is a named constant.**
# The obvious choice is "25 under, so there is room for 25 more tests", and it is
# wrong by construction: the rot check fires at MIN_EXECUTED + 38, so a floor set
# 25 under a count of N fires once the suite reaches N + 13. It buys 13 tests of
# room while telling you it bought 25 — and the first remediation message this
# script ever printed said exactly that, in a release that had already added
# enough tests to spend it.
#
# The arithmetic that actually holds: a floor set K under the measured count
# fires after (SMALLEST_TEST_TARGET - K) further tests. So K is chosen from the
# room wanted, not the other way round. 12 under 38 leaves 26.
FLOOR_SITS_UNDER="${MYNAH_FLOOR_SITS_UNDER:-12}"
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

# **The floor checking that it is still a floor.**
#
# A floor only catches a loss of N tests while the suite has fewer than N tests
# of headroom above it — once EXECUTED reaches MIN_EXECUTED + N, losing a whole
# target still clears the bar and the gate waves it through. That is not a
# hypothetical: it happened three times, twice discovered by hand and once by
# arithmetic during an audit, each time months after the gate had quietly stopped
# working.
#
# Writing the rule in a comment did not hold, because following it was left to
# memory. This is the same rule as an assertion, so the failure arrives at the
# moment it starts being true, with the new number already worked out.
#
# It fires on a *healthy* run — nothing is wrong with the suite, the gate has
# simply outgrown its own setting — so the message says that plainly rather than
# sending anyone looking for a broken test.
if (( EXECUTED >= MIN_EXECUTED + SMALLEST_TEST_TARGET )); then
  die "the suite has grown to $EXECUTED and the floor of $MIN_EXECUTED can no longer do its job.

Nothing is wrong with this run. The gate is what needs attention: losing the
smallest test target ($SMALLEST_TEST_TARGET tests, KokoroEngineTests) would leave
$(( EXECUTED - SMALLEST_TEST_TARGET )), which still clears $MIN_EXECUTED — so the
one failure this floor exists to catch would pass it.

Raise it to $(( EXECUTED - FLOOR_SITS_UNDER )) in this commit.

If this run was on the build Mac, that means editing scripts/assert-test-run.sh:
  MIN_EXECUTED=\"\${MYNAH_MIN_EXECUTED_TESTS:-$(( EXECUTED - FLOOR_SITS_UNDER ))}\"
If it was CI, the number lives in .github/workflows/release.yml instead, in the
env block of the step that just failed. The two graphs differ — the runner does
not stage vendor/onnxruntime, so it has 38 fewer tests — so they hold different
numbers and both have to be maintained. Setting one and not the other is how
this check first went red.

$(( EXECUTED - FLOOR_SITS_UNDER )) is $FLOOR_SITS_UNDER under today's count and
$(( SMALLEST_TEST_TARGET - FLOOR_SITS_UNDER )) above the failure it must catch,
which leaves room for $(( SMALLEST_TEST_TARGET - FLOOR_SITS_UNDER )) more tests
before this fires again. Update the measured/without-Kokoro/floor block above it
in the same edit, so the next person reads numbers rather than history."
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
