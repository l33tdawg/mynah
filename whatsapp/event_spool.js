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
import path from 'path';

const EVENTS_FILE = 'events.jsonl';
const ACK_FILE = 'ack';

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

  let ackedThrough = readAck(ackPath, warn);
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
  if (loaded.torn) {
    compact(eventsPath, records);
  }

  // The next sequence continues past anything on disk INCLUDING acked-and-
  // compacted history, so a sequence number is never reused within the life of
  // a spool directory. That stops a stale ack meaning a DIFFERENT message; it
  // does not stop a stale ack meaning a message that has not arrived yet, which
  // is a separate hole and is closed by the bound in `ack`.
  let nextSeq = Math.max(ackedThrough, ...records.map((r) => r.seq), 0) + 1;

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

    if (target >= nextSeq) {
      warn(
        `spool: refusing an acknowledgement of ${target} — nothing above ` +
        `${nextSeq - 1} has been written. Accepting it would retire the next ` +
        `${target - nextSeq + 1} message(s) unread. The consumer is holding a ` +
        `mark from a different spool; it will be corrected on the next connection.`
      );
      return 0;
    }

    const before = records.length;
    records = records.filter((r) => r.seq > target);
    ackedThrough = target;

    // Order matters. The ack file is written FIRST and fsynced, then the
    // events file is compacted. Crash in between and the events are still on
    // disk but below the ack mark, so the next load() filters them out — a
    // duplicate-free replay. Do it the other way round and a crash loses
    // events that were never acknowledged.
    writeAtomic(ackPath, `${ackedThrough}\n`);
    compact(eventsPath, records);
    return before - records.length;
  }

  /** For tests and for /health. */
  function stats() {
    return { pending: records.length, ackedThrough, nextSeq };
  }

  return { append, pending, ack, stats, eventsPath, ackPath };
}

function readAck(ackPath, warn) {
  if (!existsSync(ackPath)) return 0;
  try {
    const value = Number(readFileSync(ackPath, 'utf8').trim());
    if (Number.isSafeInteger(value) && value >= 0) return value;
    warn(`spool: ack file at ${ackPath} is not a whole number; treating as 0`);
  } catch (error) {
    warn(`spool: could not read ack file at ${ackPath}: ${error.message}`);
  }
  return 0;
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
 * Returns `{ records, torn }`. `torn` says the file itself needs rewriting
 * before anything is appended to it — see the caller.
 */
function load(eventsPath, warn) {
  if (!existsSync(eventsPath)) return { records: [], torn: false };
  let text;
  try {
    text = readFileSync(eventsPath, 'utf8');
  } catch (error) {
    warn(`spool: could not read ${eventsPath}: ${error.message}`);
    // Not `torn`. We could not read the file, so we know nothing about its
    // shape — rewriting it from an empty record list would turn "I could not
    // look" into "there was nothing there", which is the whole rule.
    return { records: [], torn: false };
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
  return { records: records.sort((a, b) => a.seq - b.seq), torn: trailingPartial };
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
