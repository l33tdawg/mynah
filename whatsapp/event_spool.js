// A durable spool for inbound WhatsApp events. Mynah's, not upstream's.
//
// **What this replaces, and why it is not a refinement.** Upstream delivers
// inbound messages through `GET /messages`, whose handler is
// `messageQueue.splice(0, messageQueue.length)` — it hands the caller
// everything and forgets it in the same expression. If the consumer dies
// between the socket read and actually accepting the turn, the message is
// gone, and nothing anywhere knows it existed. The same queue also drops its
// oldest entry once it passes MAX_QUEUE_SIZE.
//
// That is fine for Hermes, whose consumer is a co-supervised Python process in
// the same lifecycle. It is not fine here for a specific reason: by the time an
// event reaches this file, WhatsApp has already been told the message was
// delivered. There is no upstream copy left to ask for. Whatever we drop is
// dropped for good, and the owner's experience of it is a message he sent that
// was simply never answered.
//
// This codebase spent 1.8.3, 1.8.5 and 1.9.0 removing exactly that shape from
// three other layers — the rule each time was that "I could not look" must
// never reach the owner as "there was nothing there". A silent drop is the
// worst version of it: not even a wrong answer, just nothing.
//
// So: an event is written to disk before anyone is told about it, and it stays
// on disk until a consumer says it has taken responsibility for it. A crash on
// either side replays rather than loses. Redelivery is the deliberate trade —
// at-least-once, because a message answered twice is embarrassing and a message
// answered never is a broken product.
//
// **On-disk shape.** One JSON object per line in `events.jsonl`:
//
//     {"seq":1,"event":{…}}
//
// plus `ack` holding a single integer, the highest sequence a consumer has
// accepted. Both 0600, in a 0700 directory: these hold message text.
//
// Deliberately no database and no dependencies. The whole file is a few
// hundred lines, it is `cat`-able while debugging a live pairing, and a
// truncated last line — the shape a power cut leaves — is recoverable by
// dropping it, which `load()` does.

import {
  closeSync,
  existsSync,
  fstatSync,
  fsyncSync,
  ftruncateSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeSync,
} from 'fs';
import { randomBytes } from 'crypto';
import path from 'path';

const EVENTS_FILE = 'events.jsonl';
const ACK_FILE = 'ack';
// Which run of numbering the sequences belong to. See `readOrMintEpoch`.
const EPOCH_FILE = 'epoch';

// Past this, the spool stops accepting rather than grow without bound. It is a
// backstop against a consumer that never acks — not a working limit. At a few
// hundred bytes per event that is tens of thousands of unanswered messages,
// which is not a busy day, it is a broken consumer.
const DEFAULT_MAX_UNACKED = 10000;

/**
 * @param {object} options
 * @param {string} options.dir           directory to hold the spool
 * @param {number} [options.maxUnacked]  refuse to spool past this many
 * @param {(line: string) => void} [options.warn]
 */
export function createEventSpool({ dir, maxUnacked = DEFAULT_MAX_UNACKED, warn = () => {} }) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });

  const eventsPath = path.join(dir, EVENTS_FILE);
  const ackPath = path.join(dir, ACK_FILE);
  const epochPath = path.join(dir, EPOCH_FILE);

  // Whether this directory already claimed an identity before we opened it.
  // Read before minting, because `readOrMintEpoch` creates the file.
  const epochPredatesThisOpen = existsSync(epochPath);
  let epoch = readOrMintEpoch(epochPath, warn);

  let ackedThrough = readAck(ackPath, warn);
  // Acknowledgements refused as out of range, latched so a consumer repeating a
  // mark from a different spool cannot have it accepted later.
  //
  // **A set of exact values, not a floor.** It was `refusedAbove`, compared with
  // `target <= refusedAbove`, which blocks a whole RANGE: one bogus ack of 9,000
  // against a young spool refused every legitimate acknowledgement from 1 to
  // 9,000 for the life of the process. The spool then fills to `maxUnacked` and
  // inbound WhatsApp stops — the outcome the bound was added to prevent,
  // produced by the bound. Only the exact value a consumer keeps re-sending
  // needs latching, because re-sending it is the behaviour being defended
  // against.
  const refusedAcks = new Set();
  const loaded = load(eventsPath, warn);
  let records = loaded.records.filter((r) => r.seq > ackedThrough);

  // **Repair the file, not just our idea of it.**
  //
  // `load()` drops a torn final line from memory, which is right — it was never
  // acknowledged to anybody. But the torn BYTES are still on disk, and `append`
  // opens with 'a', so the next event would be written onto the end of a broken
  // line: `{"seq":3,"eve{"seq":4,"event":…}`. That is one unreadable line where
  // there should be two records, so the recovery destroys a message that
  // arrived AFTER the crash — and the window is unbounded, because it lasts
  // until the next append, which is exactly while Mynah is down.
  //
  // Rewriting here closes it before the first append can happen. Only for a
  // torn tail: a corrupt line in the middle is damage that must stay visible
  // until an ack compacts it away, and appending after it is safe anyway
  // because the last line is intact.
  if (loaded.torn && !loaded.unreadable) {
    compact(eventsPath, records);
  }

  // **A failed read must stay a failed read, and `compact` was undoing that.**
  //
  // `load()` deliberately returns an empty list without rewriting anything when
  // it cannot read the file, so as not to turn "I could not look" into "there
  // was nothing there". The very next `ack()` then called `compact` with that
  // empty list — which unlinks the file. The scruple lasted exactly one
  // acknowledgement.
  //
  // So a spool that could not read its own events refuses to compact at all.
  // The file stays, unreadable and intact, for whoever comes to look at it; the
  // mark still advances, so the consumer is not stuck; and the events file is
  // simply larger than it needs to be, which is the cheapest possible symptom.
  const mayRewriteEvents = !loaded.unreadable;

  // The next sequence continues past anything on disk INCLUDING acked-and-
  // compacted history, so a sequence number is never reused within the life of
  // a spool directory. That stops a stale ack meaning a DIFFERENT message; it
  // does not stop a stale ack meaning a message that has not arrived yet, which
  // is a separate hole and is closed by the bound in `ack`.
  let nextSeq = Math.max(ackedThrough, ...records.map((r) => r.seq), 0) + 1;

  // **An epoch names a run of NUMBERING, not a directory — and until 2.0.0-beta.7
  // it named the directory, which is not the same thing.**
  //
  // The repair both `readAck` throws print is `mv ack ack.broken`. In steady
  // state `compact()` has already unlinked the events file, so after that move
  // the directory holds nothing but `epoch`: `ackedThrough` reads 0, there are
  // no records to resume past, and numbering restarts at 1 — under a byte-
  // identical epoch. The consumer therefore sees sequence 1 from what it
  // believes is the same spool it has been talking to all along, keeps a
  // watermark stranded far above it, and refuses every ack from then on. The
  // spool never compacts, `event_socket` replays its whole backlog on each
  // reconnect, and the owner's contacts are answered again each time.
  //
  // Two comments asserted this case was covered and it was not — one here, one
  // in `WhatsAppAcknowledgementLedger.observe` ("Reachable by following the
  // repair readAck prints"). It was reachable, and following it was what broke.
  //
  // So: numbering that starts at 1 in a directory that already claimed an
  // identity is a new run, and says so. A genuinely fresh spool mints its epoch
  // above and does not come through here.
  if (nextSeq === 1 && epochPredatesThisOpen) {
    const renumbered = randomBytes(8).toString('hex');
    try {
      writeAtomic(epochPath, `${renumbered}\n`);
      epoch = renumbered;
      warn(`spool: numbering restarted at 1 in ${dir}, which already had an epoch — the ` +
        `acknowledgement mark was moved aside or lost. Minted a new epoch so the consumer ` +
        `rebuilds its mark instead of stranding it above sequences that no longer exist.`);
    } catch (error) {
      // In memory only, like the mint above: consistent within this run, and
      // the next start tries again. Better than keeping an identity we know is
      // wrong.
      epoch = renumbered;
      warn(`spool: numbering restarted at 1 in ${dir} but the new epoch could not be written ` +
        `(${error.message}). The consumer will re-baseline once per restart until this ` +
        `directory is writable.`);
    }
  }

  /**
   * Writes an event to disk and returns its sequence number. Throws if the
   * spool is full — the caller must decide what to do, because silently
   * dropping here is the bug this file exists to prevent.
   */
  function append(event) {
    if (records.length >= maxUnacked) {
      throw new Error(
        `event spool is full: ${records.length} events unacknowledged at ${dir}. ` +
        `Nothing has read from this spool in a long time — the consumer is ` +
        `down or wedged. Fix that; do not raise the limit.`
      );
    }
    const record = { seq: nextSeq, event };
    // fsync, because the whole point is surviving a crash. Without it the
    // write sits in the page cache and a power cut loses precisely the
    // messages this file promised to keep.
    const line = `${JSON.stringify(record)}\n`;
    const fd = openSync(eventsPath, 'a', 0o600);
    // Where the file ended before we touched it. If the write fails half way —
    // a full disk is the ordinary cause — the partial line is rolled back, so
    // the next append starts on a clean boundary rather than writing onto the
    // end of a broken record.
    const before = fstatSync(fd).size;
    try {
      writeFully(fd, line);
      fsyncSync(fd);
    } catch (error) {
      try {
        ftruncateSync(fd, before);
        fsyncSync(fd);
      } catch (repairError) {
        warn(
          `spool: an append to ${eventsPath} failed part way (${error.message}) and the ` +
          `partial line could not be rolled back (${repairError.message}). The next ` +
          `startup will discard it as a torn tail.`
        );
      }
      throw error;
    } finally {
      closeSync(fd);
    }
    // Only now. A sequence is burned by a successful write, never by a failed
    // one — the failed bytes are gone, so nothing can ever refer to that number.
    nextSeq += 1;
    records.push(record);
    return record.seq;
  }

  /** Everything written and not yet acknowledged, oldest first. */
  function pending() {
    return records.map((r) => ({ seq: r.seq, event: r.event }));
  }

  /**
   * Marks everything up to and including `seq` as accepted. Returns the number
   * of records that dropped away.
   *
   * Idempotent and monotonic: a repeated or stale ack is a no-op rather than an
   * error, because a consumer that reconnects and re-acks what it already had
   * is behaving correctly, not badly.
   *
   * **Bounded above as well as below, and the upper bound is the one that
   * matters.** Below the mark is a consumer repeating itself, which is
   * harmless. Above `nextSeq` is a consumer acknowledging messages that have
   * not been written yet: `{"ack":57}` against a fresh spool would set the mark
   * to 57 and then silently retire the next 57 messages as they arrived, each
   * one filtered out by `load()` on the following start. That is the exact
   * silent loss this file exists to prevent, arriving through the one door left
   * open — and reachable by a consumer holding a stale mark from a spool
   * directory that was deleted and recreated.
   */
  function ack(seq) {
    const target = Number(seq);
    if (!Number.isSafeInteger(target) || target <= ackedThrough) return 0;

    // **Refused once is refused for good, and the latch is the whole fix.**
    //
    // Without it the bound only holds until `nextSeq` catches up. The consumer
    // re-sends the same mark on every reconnection — that is correct behaviour
    // for it, and this file says so two paragraphs up — so a spool that receives
    // 57 real messages after refusing `{"ack":57}` accepts the very next copy of
    // it and retires all 57 unread. The bound moved the loss later rather than
    // preventing it.
    if (target >= nextSeq || refusedAcks.has(target)) {
      refusedAcks.add(target);
      warn(
        `spool: refusing an acknowledgement of ${target} — nothing above ` +
        `${nextSeq - 1} has been written. Accepting it would retire the next ` +
        `${Math.max(0, target - nextSeq + 1)} message(s) unread. The consumer is holding a ` +
        `mark from a different spool and will keep re-sending it, so it is refused ` +
        `permanently rather than until this spool grows past it. Nothing is lost: ` +
        `every record here is still replayed on the next connection, and the consumer ` +
        `rebuilds its mark when it sees this spool's epoch (${epoch}) differs from the ` +
        `one its numbers came from.`
      );
      return 0;
    }

    // **Disk first, memory second.** This used to move `records` and
    // `ackedThrough` before touching the disk, then call `writeAtomic` and
    // `compact` with no handling at all — and both throw on the ENOSPC and EIO
    // that `append` was hardened against. The throw arrives from
    // `event_socket.js`'s `data` listener, which has no catch, in a process with
    // no `uncaughtException` handler: one full disk and the bridge is gone,
    // having already dropped the records from memory.
    //
    // Written this way round, a failure leaves the spool exactly as it was and
    // the consumer simply re-acks on its next connection.
    const before = records.length;
    const remaining = records.filter((r) => r.seq > target);

    // Order matters here too. The ack file is written FIRST and fsynced, then
    // the events file is compacted. Crash in between and the events are still on
    // disk but below the ack mark, so the next load() filters them out — a
    // duplicate-free replay. Do it the other way round and a crash loses events
    // that were never acknowledged.
    try {
      writeAtomic(ackPath, `${target}\n`);
    } catch (error) {
      warn(
        `spool: could not record an acknowledgement of ${target} at ${ackPath} ` +
        `(${error.message}). Nothing was dropped — every message here is still on ` +
        `disk and will be replayed. Free some space; the consumer re-acknowledges ` +
        `on its next connection.`
      );
      return 0;
    }
    ackedThrough = target;
    records = remaining;
    try {
      if (mayRewriteEvents) compact(eventsPath, records);
    } catch (error) {
      // The mark is already down, so these records are retired whether or not
      // the file shrinks — `load()` filters by the mark. A failure here costs
      // disk space, not messages.
      warn(
        `spool: acknowledged through ${target} but could not shrink ${eventsPath} ` +
        `(${error.message}). No message is lost; the file is larger than it needs to be ` +
        `and the next successful acknowledgement rewrites it.`
      );
    }
    return before - records.length;
  }

  /** For tests and for /health. */
  function stats() {
    return { pending: records.length, ackedThrough, nextSeq };
  }

  return { append, pending, ack, stats, epoch, eventsPath, ackPath, epochPath };
}

/**
 * Which run of numbering these sequences belong to.
 *
 * **The consumer cannot work this out for itself, and the file used to claim it
 * could.** The refusal in `ack()` tells whoever reads the log that "the
 * consumer's mark is rebuilt from the first sequence it sees". That was false:
 * `WhatsAppAcknowledgementLedger` baselines exactly once per process, so a spool
 * recreated under a running Mynah — which is what the repair `readAck` prints
 * produces — leaves the watermark stranded above every new sequence. It never
 * moves again, nothing is ever acknowledged, and the spool fills to `maxUnacked`
 * and refuses inbound WhatsApp for good.
 *
 * Guessing is not available. A consumer seeing a sequence below its watermark
 * cannot tell "the spool restarted" from "my last ack never landed and the
 * bridge is legitimately replaying" — the second is ordinary, and re-baselining
 * on it would re-answer messages already dealt with. So the spool states which
 * run it is rather than leaving the other end to infer it.
 *
 * Minted once and then kept: it identifies the numbering, not the process, so a
 * bridge restart over the same directory must keep it. A directory that is moved
 * aside or deleted takes it with it, which is exactly the event being detected.
 *
 * An unreadable epoch file is not fatal. It costs one unnecessary re-baseline at
 * worst — at-least-once, which is this file's whole trade — and refusing to
 * start over it would take down WhatsApp for a file that carries no messages.
 */
function readOrMintEpoch(epochPath, warn) {
  if (existsSync(epochPath)) {
    try {
      const existing = readFileSync(epochPath, 'utf8').trim();
      if (existing !== '') return existing;
      warn(`spool: the epoch at ${epochPath} is empty; minting a new one. The consumer will ` +
        `rebuild its acknowledgement mark from the next sequence it sees.`);
    } catch (error) {
      warn(`spool: could not read the epoch at ${epochPath} (${error.message}); minting a new ` +
        `one. The consumer will rebuild its acknowledgement mark from the next sequence it sees.`);
    }
  }
  const minted = randomBytes(8).toString('hex');
  try {
    writeAtomic(epochPath, `${minted}\n`);
  } catch (error) {
    // In memory only. Every event this run carries the same value, so the
    // consumer stays consistent within the run; the next start mints another
    // and re-baselines once more, which is survivable and visible.
    warn(`spool: could not record the epoch at ${epochPath} (${error.message}). Sequence ` +
      `numbering still works; the consumer will re-baseline once on each restart until this ` +
      `directory is writable.`);
  }
  return minted;
}

/**
 * The mark, or a refusal to start.
 *
 * **Absent and unreadable are different, and treating them alike restarts
 * sequence numbering.** No file at all is a fresh spool, and 0 is the right
 * answer. A file that exists and will not parse is the opposite: this spool has
 * a history and we cannot see how far it got. Answering 0 there makes `nextSeq`
 * restart at 1 — the events file is normally absent in the steady state,
 * because `compact` unlinks it once everything is acknowledged, so there are no
 * records to derive a floor from either.
 *
 * What that costs is not one message. Sequence numbers are the only thing
 * identifying a message to the consumer, and the file at line 99 states that
 * one is never reused within the life of a spool directory. Reuse breaks the
 * consumer's watermark in both directions at once: acks for the old 1..N retire
 * the new 1..N unread, and the ledger on the other side has already seen those
 * numbers.
 *
 * So this throws, and the bridge refuses to start. Loud and stopped beats
 * running and quietly reusing numbers — and the message says exactly which file
 * to move aside, which is a repair the owner can carry out in one command.
 */
function readAck(ackPath, warn) {
  if (!existsSync(ackPath)) return 0;
  let raw;
  try {
    raw = readFileSync(ackPath, 'utf8');
  } catch (error) {
    throw new Error(
      `the spool's acknowledgement mark at ${ackPath} could not be read (${error.message}).\n` +
      `Starting anyway would restart sequence numbering at 1 and hand the consumer numbers it\n` +
      `has already seen, which loses messages silently in both directions.\n` +
      `Fix the permissions on that file, or move it aside to start clean:\n` +
      `  mv '${ackPath}' '${ackPath}.broken'\n` +
      `Moving just this file is deliberate: the events file beside it is what numbering resumes\n` +
      `from, so anything unacknowledged is replayed rather than renumbered.`
    );
  }
  const trimmed = raw.trim();
  // **Blank is not zero.** `Number('')` is 0, and 0 is the answer for a spool
  // that has never acknowledged anything — so an ack file truncated to nothing,
  // which is what a crash between `open` and `write` leaves, read as "start
  // again from 1". Exactly the renumbering this function throws to prevent, and
  // it arrived through the emptiest possible door.
  const value = trimmed === '' ? Number.NaN : Number(trimmed);
  if (Number.isSafeInteger(value) && value >= 0) return value;
  throw new Error(
    `the spool's acknowledgement mark at ${ackPath} is ${trimmed === '' ? 'empty' : `not a whole number (${JSON.stringify(raw.slice(0, 40))})`}.\n` +
    `Starting anyway would restart sequence numbering at 1 and hand the consumer numbers it\n` +
    `has already seen, which loses messages silently in both directions.\n` +
    `Move it aside to start clean, accepting that anything unacknowledged in it is gone:\n` +
    `  mv '${ackPath}' '${ackPath}.broken'`
  );
}

/**
 * Reads the spool, dropping only what cannot possibly be a record.
 *
 * A half-written final line is what an interrupted append leaves behind, and
 * dropping it is correct: it was never acknowledged to anybody, so no promise
 * is broken. A corrupt line in the MIDDLE is different — that is damage, and it
 * is reported rather than passed over in silence, because quietly reading
 * around a hole is how a spool that has lost messages goes on looking healthy.
 *
 * Returns `{ records, torn, unreadable }`. `torn` says the file itself needs
 * rewriting before anything is appended to it; `unreadable` says nothing may
 * rewrite it at all — see the caller.
 */
function load(eventsPath, warn) {
  if (!existsSync(eventsPath)) return { records: [], torn: false, unreadable: false };
  let text;
  try {
    text = readFileSync(eventsPath, 'utf8');
  } catch (error) {
    warn(
      `spool: could not read ${eventsPath}: ${error.message}. ` +
      `Nothing in it will be replayed and nothing will overwrite it either — it is left ` +
      `exactly as found. Fix the permissions and restart to recover whatever is in there.`
    );
    // Not `torn`, and now `unreadable` as well. We could not read the file, so
    // we know nothing about its shape — rewriting it from an empty record list
    // would turn "I could not look" into "there was nothing there", which is the
    // whole rule. Saying so in the return value is what makes the rule hold past
    // this function: the flag travels to `compact`, which was undoing it on the
    // very next acknowledgement.
    return { records: [], torn: false, unreadable: true };
  }

  const lines = text.split('\n');
  const trailingPartial = lines.length > 0 && lines[lines.length - 1] !== '';
  const records = [];

  lines.forEach((line, index) => {
    if (line === '') return;
    const isLast = index === lines.length - 1;
    try {
      const record = JSON.parse(line);
      if (Number.isSafeInteger(record?.seq) && 'event' in record) {
        records.push(record);
        return;
      }
      throw new Error('missing seq or event');
    } catch (error) {
      if (isLast && trailingPartial) {
        // An interrupted append. Expected; not a fault.
        warn(`spool: discarding a partial final line in ${eventsPath}`);
        return;
      }
      warn(
        `spool: line ${index + 1} of ${eventsPath} is unreadable (${error.message}). ` +
        `That line held a WhatsApp message and it is now lost. This is damage, ` +
        `not routine: an interrupted append can only ever damage the LAST line, ` +
        `and this one has intact lines after it.`
      );
    }
  });

  // Sorted rather than assumed sorted: append order is sequence order today,
  // and a future writer that batches would break that assumption silently.
  return { records: records.sort((a, b) => a.seq - b.seq), torn: trailingPartial, unreadable: false };
}

function compact(eventsPath, records) {
  if (records.length === 0) {
    if (existsSync(eventsPath)) unlinkSync(eventsPath);
    return;
  }
  writeAtomic(eventsPath, records.map((r) => `${JSON.stringify(r)}\n`).join(''));
}

/**
 * Write-and-rename, so a reader never sees a half-written file and a crash
 * leaves either the old contents or the new ones. The fsync before the rename
 * is the part that is easy to leave out and makes the whole exercise
 * decorative on a crash.
 */
function writeAtomic(target, contents) {
  const temporary = `${target}.tmp`;
  const fd = openSync(temporary, 'w', 0o600);
  try {
    writeFully(fd, contents);
    fsyncSync(fd);
  } catch (error) {
    // The rename is what makes this atomic, and it must not happen. A
    // short-written temporary renamed over the events file would replace every
    // unacknowledged record with a truncated copy of itself — a compaction that
    // destroys exactly the messages it was called to preserve.
    closeSync(fd);
    try { unlinkSync(temporary); } catch { /* nothing left to clean up */ }
    throw error;
  }
  closeSync(fd);
  renameSync(temporary, target);
}

/**
 * `writeSync` is not obliged to write everything you give it — it returns how
 * many bytes it took, and on a full or slow filesystem that can be fewer than
 * asked for. Ignoring the return value means a partial write reports success,
 * which here means a truncated message that reads back as corruption, or a
 * truncated compaction that loses every record after the cut.
 *
 * Bytes rather than the string, because a partial write is counted in bytes and
 * message text is full of multi-byte characters — resuming at a character
 * offset would splice the file at the wrong place.
 *
 * `write` is a parameter only so the tests can hand it a writer that takes
 * three bytes at a time. Producing a genuine short write needs a full disk, and
 * a hazard that can only be reproduced by filling a disk is a hazard nobody
 * ever writes a test for.
 */
function writeFully(fd, contents, write = writeSync) {
  const buffer = Buffer.from(contents, 'utf8');
  let written = 0;
  while (written < buffer.length) {
    const n = write(fd, buffer, written, buffer.length - written);
    if (!(n > 0)) {
      throw new Error(`write stalled after ${written} of ${buffer.length} bytes`);
    }
    written += n;
  }
}

// Exported for the tests, which need to build a spool file by hand to prove
// what happens to a damaged one.
export const _internals = { load, writeAtomic, writeFully, EVENTS_FILE, ACK_FILE };
