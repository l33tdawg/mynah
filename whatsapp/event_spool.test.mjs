// An inbound WhatsApp message is not lost because something restarted.
//
// By the time an event reaches the spool, WhatsApp has already been told the
// message was delivered. There is no copy left anywhere to ask for. So every
// test here is about the same promise from a different angle: once we have it,
// we keep it until somebody says they have taken it.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { appendFileSync, chmodSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';

import { createEventSpool, _internals } from './event_spool.js';

function scratch() {
  return mkdtempSync(path.join(tmpdir(), 'mynah-spool-'));
}

function message(text) {
  return { type: 'message', chatId: '60123@s.whatsapp.net', text };
}

test('an event survives the process that wrote it', () => {
  const dir = scratch();
  try {
    createEventSpool({ dir }).append(message('did the ferry get booked'));

    // A different spool object over the same directory is what a restart is.
    const afterRestart = createEventSpool({ dir });
    assert.equal(afterRestart.pending().length, 1);
    assert.equal(afterRestart.pending()[0].event.text, 'did the ferry get booked');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('an event nobody accepted comes back, rather than going quiet', () => {
  const dir = scratch();
  try {
    // Read it, do not ack it, then die. This is the exact window that upstream
    // loses: consumer has the bytes, has not yet taken responsibility.
    const first = createEventSpool({ dir });
    first.append(message('remind me at six'));
    assert.equal(first.pending().length, 1, 'read does not consume');
    assert.equal(first.pending().length, 1, 'and reading twice still does not');

    const second = createEventSpool({ dir });
    assert.equal(second.pending()[0].event.text, 'remind me at six');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the shape this replaces really does lose it', () => {
  // Not a test of our code — a test of the claim in event_spool.js's header,
  // kept executable so it cannot quietly become folklore. This is upstream's
  // handler, transcribed:
  //
  //     app.get('/messages', (req, res) => {
  //       const msgs = messageQueue.splice(0, messageQueue.length);
  //       res.json(msgs);
  //     });
  const messageQueue = [message('did the ferry get booked')];
  const handedToTheConsumer = messageQueue.splice(0, messageQueue.length);

  assert.equal(handedToTheConsumer.length, 1);
  // …and now the consumer crashes before doing anything with it.
  assert.deepEqual(messageQueue, [], 'the bridge no longer has it');
  // There is nowhere to look. Not an empty result that says "I could not
  // read" — an empty result indistinguishable from nobody having written.
});

test('an accepted event does not come back', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    const seq = spool.append(message('book the hotel'));
    assert.equal(spool.ack(seq), 1);
    assert.equal(spool.pending().length, 0);

    assert.equal(createEventSpool({ dir }).pending().length, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('accepting one leaves the ones after it', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    const first = spool.append(message('one'));
    spool.append(message('two'));
    spool.append(message('three'));

    assert.equal(spool.ack(first), 1);

    const left = createEventSpool({ dir }).pending();
    assert.deepEqual(left.map((r) => r.event.text), ['two', 'three']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a stale ack cannot un-accept, and a repeat is harmless', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    const first = spool.append(message('one'));
    const second = spool.append(message('two'));

    assert.equal(spool.ack(second), 2);
    // A consumer that reconnects and re-acks what it already had is behaving
    // correctly. It must not resurrect anything or throw.
    assert.equal(spool.ack(first), 0);
    assert.equal(spool.ack(second), 0);
    assert.equal(spool.pending().length, 0);
    assert.equal(spool.stats().ackedThrough, second);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a sequence number is never reused, even after compaction', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    const first = spool.append(message('one'));
    spool.ack(first);          // compacts the file away entirely

    // A restart must not start counting again from 1. If it did, a consumer
    // holding a stale ack of 1 would silently accept a message it never saw.
    const afterRestart = createEventSpool({ dir });
    const next = afterRestart.append(message('two'));
    assert.ok(next > first, `expected a sequence above ${first}, got ${next}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a half-written last line is dropped and the rest survives', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('one'));
    spool.append(message('two'));

    // What an append interrupted by a power cut leaves behind.
    const eventsPath = path.join(dir, 'events.jsonl');
    writeFileSync(eventsPath, readFileSync(eventsPath, 'utf8') + '{"seq":3,"eve');

    const warnings = [];
    const recovered = createEventSpool({ dir, warn: (w) => warnings.push(w) });
    assert.deepEqual(recovered.pending().map((r) => r.event.text), ['one', 'two']);
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /partial final line/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a corrupt line in the middle is reported, not read around in silence', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('one'));
    spool.append(message('two'));

    const eventsPath = path.join(dir, 'events.jsonl');
    const lines = readFileSync(eventsPath, 'utf8').split('\n');
    lines[0] = '{"seq":1,"ev';                       // damage, not truncation
    writeFileSync(eventsPath, lines.join('\n'));

    const warnings = [];
    const recovered = createEventSpool({ dir, warn: (w) => warnings.push(w) });

    assert.deepEqual(recovered.pending().map((r) => r.event.text), ['two']);
    assert.equal(warnings.length, 1, 'the loss must be announced exactly once');
    assert.match(warnings[0], /unreadable/);
    // The distinction the code makes, and the reason it makes it: a truncated
    // tail is routine, a hole in the middle means a message was destroyed.
    assert.match(warnings[0], /damage/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a full spool refuses instead of dropping the oldest', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir, maxUnacked: 2 });
    spool.append(message('one'));
    spool.append(message('two'));

    assert.throws(() => spool.append(message('three')), /spool is full/);

    // The point of throwing: 'one' is still there. Upstream's queue would have
    // shifted it out to make room, which is the same silent loss wearing a
    // different hat.
    assert.deepEqual(spool.pending().map((r) => r.event.text), ['one', 'two']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the spool is not world-readable — it holds message text', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('the bank code is'));

    assert.equal(statSync(dir).mode & 0o777, 0o700, 'directory');
    assert.equal(statSync(spool.eventsPath).mode & 0o777, 0o600, 'events file');

    spool.ack(1);
    assert.equal(statSync(spool.ackPath).mode & 0o777, 0o600, 'ack file');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// The four below are regressions. Each reproduces a defect that was in this
// file and passed the eleven tests above it — written after an audit found
// them, and each fails if its fix is taken back out.

test('a message written after a torn tail is not eaten by it', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('one'));
    spool.append(message('two'));

    // An append interrupted by a power cut. The eleven tests above prove the
    // torn line is dropped from MEMORY on the next start — and stop there.
    // The bytes are still on disk, and `append` opens with 'a'.
    appendFileSync(spool.eventsPath, '{"seq":3,"eve');

    const recovered = createEventSpool({ dir });
    recovered.append(message('three'));

    // Without the repair, 'three' is written onto the end of the broken line:
    // one unreadable record where there should have been two, and the message
    // destroyed is the one that arrived AFTER the crash — a message the owner
    // sent while everything was working.
    const warnings = [];
    const afterRestart = createEventSpool({ dir, warn: (w) => warnings.push(w) });
    assert.deepEqual(
      afterRestart.pending().map((r) => r.event.text),
      ['one', 'two', 'three']
    );
    assert.deepEqual(warnings, [], 'the torn tail was repaired, so there is nothing left to report');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('an acknowledgement of messages that have not arrived is refused', () => {
  const dir = scratch();
  try {
    const warnings = [];
    const spool = createEventSpool({ dir, warn: (w) => warnings.push(w) });

    // A consumer holding a mark from a spool directory that was deleted and
    // recreated. Nothing has been written here at all.
    assert.equal(spool.ack(57), 0);
    assert.equal(spool.stats().ackedThrough, 0, 'the mark must not move to a message that does not exist');
    assert.match(warnings.join('\n'), /refusing an acknowledgement/);

    // The damage this prevents: the next fifty-seven real messages arrive,
    // are spooled, and are then filtered out as already-accepted on the next
    // start — read by nobody, reported to nobody.
    spool.append(message('did the ferry get booked'));
    assert.deepEqual(
      createEventSpool({ dir }).pending().map((r) => r.event.text),
      ['did the ferry get booked']
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a short write is finished, not reported as a success', () => {
  // `writeSync` returns how many bytes it took, which on a full or slow
  // filesystem can be fewer than it was given. Ignoring that is a truncated
  // message on disk that reads back as corruption — or, in a compaction, a
  // truncated file renamed over the authoritative one.
  //
  // Injected rather than simulated with a real full disk: the hazard is the
  // return value, and this pins the exact behaviour on it.
  const taken = [];
  const threeBytesAtATime = (fd, buffer, offset, length) => {
    const n = Math.min(3, length);
    taken.push(Buffer.from(buffer.subarray(offset, offset + n)));
    return n;
  };

  // Multi-byte on purpose: a partial write is counted in bytes, so resuming at
  // a character offset would splice the file mid-character.
  const line = '{"seq":1,"event":{"text":"café ☕"}}\n';
  _internals.writeFully(-1, line, threeBytesAtATime);

  assert.ok(taken.length > 1, 'the test is worthless if it all went in one go');
  assert.equal(Buffer.concat(taken).toString('utf8'), line);
});

test('a write that stops making progress throws rather than looping for ever', () => {
  assert.throws(
    () => _internals.writeFully(-1, 'anything at all', () => 0),
    /write stalled after 0 of 15 bytes/
  );
});

test('events acked below the mark do not reappear after a crash mid-compaction', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('one'));
    const second = spool.append(message('two'));
    spool.ack(second);

    // Simulate the crash window ack() is ordered to survive: the ack file
    // landed, the compaction did not. Both records are back on disk, and both
    // are at or below the ack mark.
    writeFileSync(
      path.join(dir, 'events.jsonl'),
      '{"seq":1,"event":{"text":"one"}}\n{"seq":2,"event":{"text":"two"}}\n'
    );

    const recovered = createEventSpool({ dir });
    assert.deepEqual(recovered.pending(), [], 'the ack mark filters them out');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// --- what a 43-agent audit of this branch found, and none of the above caught ---

test('a spool whose mark cannot be read refuses to start rather than renumbering', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('what time is the ferry'));
    spool.ack(1);

    // The steady state: the events file is gone, everything is in the mark. A
    // mark that will not parse used to be read as 0, which restarts numbering at
    // 1 — and the consumer has already seen 1. Both directions lose messages:
    // its ack for the old 1 retires the new 1 unread, and its ledger holds the
    // number open for the one it never gets.
    writeFileSync(path.join(dir, 'ack'), 'not-a-number\n');

    assert.throws(
      () => createEventSpool({ dir }),
      /acknowledgement mark|not a whole number/,
      'a spool with an unreadable mark started anyway and restarted sequence numbering'
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the refusal names the one command that repairs it', () => {
  const dir = scratch();
  try {
    createEventSpool({ dir }).append(message('one'));
    writeFileSync(path.join(dir, 'ack'), '\n');
    try {
      createEventSpool({ dir });
      assert.fail('expected a refusal');
    } catch (error) {
      // Every dead end names the next action.
      assert.match(error.message, /mv /, `no repair offered: ${error.message}`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('an acknowledgement refused as out of range stays refused once the spool grows', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('one'));

    // A consumer holding a mark from a spool directory that was deleted and
    // recreated. Refused — the bound added by the previous round.
    assert.equal(spool.ack(4), 0);

    // …and the consumer re-sends the same mark on every reconnection, which is
    // correct behaviour for it. Before the latch, the bound only held until the
    // spool caught up: these three messages arrive, nextSeq passes 4, and the
    // identical ack is then accepted and retires all of them unread.
    spool.append(message('two'));
    spool.append(message('three'));
    spool.append(message('four'));

    assert.equal(spool.ack(4), 0, 'a stale mark was accepted once the spool grew past it');
    assert.equal(spool.pending().length, 4, 'four messages were retired without being read');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a mark that cannot be read at all is refused, not read as zero', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('what time is the ferry'));
    spool.ack(1);

    // Unreadable rather than unparseable — EACCES, which is the shape a
    // permissions accident takes. Both used to return 0 and renumber; only the
    // parse failure was covered, and the mutation that removed this branch
    // survived a green suite.
    const ackPath = path.join(dir, 'ack');
    chmodSync(ackPath, 0o000);
    try {
      assert.throws(
        () => createEventSpool({ dir }),
        /could not be read/,
        'a mark that could not be read was treated as 0, restarting sequence numbering'
      );
    } finally {
      chmodSync(ackPath, 0o600);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a spool that could not read its events never overwrites them', () => {
  const dir = scratch();
  const eventsPath = path.join(dir, 'events.jsonl');
  try {
    const first = createEventSpool({ dir });
    first.append(message('the ferry booking'));
    first.append(message('and the hotel'));
    const before = readFileSync(eventsPath, 'utf8');
    assert.ok(before.includes('the ferry booking'));

    // Write-only: `load` cannot read it, `append` can still open it with 'a'.
    // That is what makes the next acknowledgement reach `compact` with an empty
    // record list — which used to unlink the file, turning "I could not look"
    // into "there was nothing there" one acknowledgement after `load` had
    // carefully refused to do exactly that.
    chmodSync(eventsPath, 0o200);
    let reopened;
    try {
      reopened = createEventSpool({ dir });
      assert.equal(reopened.pending().length, 0, 'the unreadable file was somehow read');
      reopened.append(message('a third, after the damage'));
      const retired = reopened.ack(reopened.stats().nextSeq - 1);
      assert.equal(retired, 1, 'the new message was not acknowledged');
    } finally {
      chmodSync(eventsPath, 0o600);
    }

    const after = readFileSync(eventsPath, 'utf8');
    assert.ok(
      after.includes('the ferry booking') && after.includes('and the hotel'),
      'two messages nobody could read were deleted by the next acknowledgement'
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('one bogus acknowledgement does not refuse every legitimate one beneath it', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    spool.append(message('one'));

    // A consumer holding a mark from a spool directory that was recreated. Far
    // above anything written, so it is refused.
    assert.equal(spool.ack(9000), 0);

    // **The latch must be the value, not a floor.** It was `target <=
    // refusedAbove`, which blocks a RANGE: after refusing 9,000 every honest
    // acknowledgement from 1 to 9,000 was refused too, the spool filled to
    // maxUnacked, and inbound WhatsApp stopped — the exact outcome the bound was
    // added to prevent, produced by the bound.
    spool.append(message('two'));
    assert.equal(spool.ack(1), 1, 'a legitimate acknowledgement was refused by the bogus one above it');
    assert.equal(spool.pending().length, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// --- which run of numbering these sequences belong to ---

test('the epoch survives a restart over the same directory', () => {
  // It identifies the NUMBERING, not the process. A bridge restart continues
  // the sequence, so re-minting here would make the consumer re-baseline on
  // every restart — which looks exactly like working until the day it matters.
  const dir = scratch();
  try {
    const first = createEventSpool({ dir });
    first.append(message('one'));
    const second = createEventSpool({ dir });
    assert.equal(second.epoch, first.epoch, 'a plain restart looked like a new spool');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a spool directory that was moved aside gets a different epoch', () => {
  // The event being detected, and the one `readAck`'s repair instructions
  // produce. Without a way to tell, the consumer's watermark is stranded above
  // every sequence the new spool will ever emit: nothing is acknowledged, the
  // spool fills to maxUnacked, and inbound WhatsApp stops for good.
  const before = scratch();
  const after = scratch();
  try {
    const original = createEventSpool({ dir: before });
    const replacement = createEventSpool({ dir: after });
    assert.notEqual(replacement.epoch, original.epoch);
  } finally {
    rmSync(before, { recursive: true, force: true });
    rmSync(after, { recursive: true, force: true });
  }
});

test('the epoch is a value, and one the consumer can compare', () => {
  const dir = scratch();
  try {
    const spool = createEventSpool({ dir });
    assert.equal(typeof spool.epoch, 'string');
    assert.ok(spool.epoch.length > 0, 'an empty epoch compares equal to a missing one');
    assert.equal(readFileSync(spool.epochPath, 'utf8').trim(), spool.epoch);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('an empty epoch file is replaced rather than read as a value', () => {
  // What a crash between open and write leaves. Read as-is it would be the empty
  // string, which the consumer cannot distinguish from a bridge that sends no
  // epoch at all — so the recovery would silently stop working.
  const dir = scratch();
  try {
    writeFileSync(path.join(dir, 'epoch'), '');
    const warnings = [];
    const spool = createEventSpool({ dir, warn: (line) => warnings.push(line) });
    assert.ok(spool.epoch.length > 0);
    assert.ok(warnings.some((w) => w.includes('epoch')), 'a re-mint happened in silence');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a spool whose epoch cannot be written still runs', () => {
  // Consistent within the run, so the consumer is never confused mid-stream; it
  // re-baselines once per restart until the directory is writable. Refusing to
  // start would take WhatsApp down over a file that carries no messages.
  const dir = scratch();
  try {
    const warnings = [];
    chmodSync(dir, 0o500);            // readable and listable, not writable
    const spool = createEventSpool({ dir, warn: (line) => warnings.push(line) });
    assert.ok(spool.epoch.length > 0);
    assert.ok(warnings.some((w) => w.includes('epoch')));
  } finally {
    chmodSync(dir, 0o700);
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the refusal no longer promises something the consumer cannot do', () => {
  // The line said "the consumer's mark is rebuilt from the first sequence it
  // sees", and the ledger baselines exactly once per process — so a spool
  // recreated under a running Mynah wedged, while the log said it would recover.
  const dir = scratch();
  try {
    const warnings = [];
    const spool = createEventSpool({ dir, warn: (line) => warnings.push(line) });
    spool.append(message('one'));
    spool.ack(9000);

    const refusal = warnings.find((w) => w.includes('refusing an acknowledgement'));
    assert.ok(refusal, 'the refusal was not reported at all');
    assert.ok(
      !refusal.includes('rebuilt from the first sequence it sees'),
      'the log still promises a recovery the consumer does not have'
    );
    assert.ok(refusal.includes(spool.epoch), 'the refusal does not say which spool this is');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
