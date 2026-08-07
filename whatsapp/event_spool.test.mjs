// An inbound WhatsApp message is not lost because something restarted.
//
// By the time an event reaches the spool, WhatsApp has already been told the
// message was delivered. There is no copy left anywhere to ask for. So every
// test here is about the same promise from a different angle: once we have it,
// we keep it until somebody says they have taken it.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';

import { createEventSpool } from './event_spool.js';

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
