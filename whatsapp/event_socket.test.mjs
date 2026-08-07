// The socket half of never losing a message: a consumer that was not there
// when the message arrived still gets it when it comes back.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect } from 'net';
import { mkdtempSync, rmSync, statSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';

import { createEventSpool } from './event_spool.js';
import { createEventSocket } from './event_socket.js';

function scratch() {
  return mkdtempSync(path.join(tmpdir(), 'mynah-evsock-'));
}

/** A stand-in for the Swift side: reads lines, can send acks. */
function consumer(socketPath) {
  const socket = connect(socketPath);
  const lines = [];
  const waiters = [];
  let buffer = '';

  socket.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    let newline;
    while ((newline = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;
      lines.push(JSON.parse(line));
      while (waiters.length && lines.length >= waiters[0].count) waiters.shift().resolve();
    }
  });

  return {
    socket,
    lines,
    connected: () => new Promise((resolve, reject) => {
      socket.once('connect', resolve);
      socket.once('error', reject);
    }),
    /** Resolves once `count` records have arrived. Fails the test rather than hanging. */
    receive: (count, ms = 3000) => new Promise((resolve, reject) => {
      if (lines.length >= count) return resolve();
      const timer = setTimeout(
        () => reject(new Error(`only ${lines.length} of ${count} records arrived in ${ms}ms`)),
        ms
      );
      waiters.push({ count, resolve: () => { clearTimeout(timer); resolve(); } });
    }),
    ack: (seq) => socket.write(`${JSON.stringify({ ack: seq })}\n`),
    close: () => new Promise((resolve) => { socket.end(); socket.once('close', resolve); }),
  };
}

/** Lets the event loop turn so a write reaches the other end. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 60));

async function withSocket(run) {
  const dir = scratch();
  const socketPath = path.join(dir, 'events.sock');
  const spool = createEventSpool({ dir: path.join(dir, 'spool') });
  const events = createEventSocket({ path: socketPath, spool });
  await events.start();
  try {
    await run({ dir, socketPath, spool, events });
  } finally {
    await events.stop();
    rmSync(dir, { recursive: true, force: true });
  }
}

function message(text) {
  return { type: 'message', chatId: '60123@s.whatsapp.net', text };
}

test('a live event reaches a connected consumer', async () => {
  await withSocket(async ({ socketPath, spool, events }) => {
    const client = consumer(socketPath);
    await client.connected();

    events.notify({ seq: spool.append(message('hello')), event: message('hello') });
    await client.receive(1);

    assert.equal(client.lines[0].event.text, 'hello');
    assert.equal(client.lines[0].seq, 1);
    await client.close();
  });
});

test('an event that arrived while nobody was listening is replayed', async () => {
  await withSocket(async ({ socketPath, spool, events }) => {
    // Nothing is connected. This is the window a restart opens, and the one
    // upstream's drain-on-read loses outright.
    const seq = spool.append(message('did the ferry get booked'));
    events.notify({ seq, event: message('did the ferry get booked') });

    const client = consumer(socketPath);
    await client.connected();
    await client.receive(1);

    assert.equal(client.lines[0].event.text, 'did the ferry get booked');
    await client.close();
  });
});

test('an unacknowledged event comes back after the consumer restarts', async () => {
  await withSocket(async ({ socketPath, spool, events }) => {
    const seq = spool.append(message('remind me at six'));
    events.notify({ seq, event: message('remind me at six') });

    const first = consumer(socketPath);
    await first.connected();
    await first.receive(1);
    await first.close();           // read it, never acked it, went away
    await settle();

    const second = consumer(socketPath);
    await second.connected();
    await second.receive(1);
    assert.equal(second.lines[0].event.text, 'remind me at six');
    assert.equal(second.lines[0].seq, seq, 'the same sequence, not a new one');
    await second.close();
  });
});

test('an acknowledged event does not come back', async () => {
  await withSocket(async ({ socketPath, spool, events }) => {
    const seq = spool.append(message('book the hotel'));
    events.notify({ seq, event: message('book the hotel') });

    const first = consumer(socketPath);
    await first.connected();
    await first.receive(1);
    first.ack(seq);
    await settle();
    await first.close();
    await settle();

    const second = consumer(socketPath);
    await second.connected();
    await settle();
    assert.deepEqual(second.lines, [], 'nothing to replay');
    await second.close();
  });
});

test('replay is in order, and partial acks leave the rest', async () => {
  await withSocket(async ({ socketPath, spool, events }) => {
    for (const text of ['one', 'two', 'three']) {
      const seq = spool.append(message(text));
      events.notify({ seq, event: message(text) });
    }

    const first = consumer(socketPath);
    await first.connected();
    await first.receive(3);
    assert.deepEqual(first.lines.map((r) => r.event.text), ['one', 'two', 'three']);
    first.ack(first.lines[0].seq);     // took the first only
    await settle();
    await first.close();
    await settle();

    const second = consumer(socketPath);
    await second.connected();
    await second.receive(2);
    assert.deepEqual(second.lines.map((r) => r.event.text), ['two', 'three']);
    await second.close();
  });
});

test('a second consumer displaces the first rather than splitting the stream', async () => {
  await withSocket(async ({ socketPath, spool, events }) => {
    const first = consumer(socketPath);
    await first.connected();

    const second = consumer(socketPath);
    await second.connected();
    await settle();

    const seq = spool.append(message('who gets this'));
    events.notify({ seq, event: message('who gets this') });
    await second.receive(1);
    await settle();

    assert.deepEqual(first.lines, [], 'the displaced consumer gets nothing further');
    assert.equal(second.lines[0].event.text, 'who gets this');
    // The point: if both were served, either one's ack would retire the
    // other's unread messages, and the loss would look like redundancy.
    await second.close();
  });
});

test('a garbled line from the consumer does not stop delivery', async () => {
  await withSocket(async ({ socketPath, spool, events }) => {
    const client = consumer(socketPath);
    await client.connected();

    client.socket.write('{not json at all\n');
    await settle();

    const seq = spool.append(message('still here'));
    events.notify({ seq, event: message('still here') });
    await client.receive(1);

    assert.equal(client.lines[0].event.text, 'still here');
    await client.close();
  });
});

test('a multi-line message survives the framing', async () => {
  await withSocket(async ({ socketPath, spool, events }) => {
    const client = consumer(socketPath);
    await client.connected();

    const text = 'line one\nline two\nline three';
    const seq = spool.append(message(text));
    events.notify({ seq, event: message(text) });
    await client.receive(1);

    assert.equal(client.lines.length, 1, 'one record, not three');
    assert.equal(client.lines[0].event.text, text);
    await client.close();
  });
});

test('the socket file is not reachable by other accounts', async () => {
  await withSocket(async ({ socketPath }) => {
    assert.equal(statSync(socketPath).mode & 0o777, 0o600);
  });
});

test('too long a socket path is refused, not silently truncated', async () => {
  const dir = scratch();
  try {
    // sockaddr_un.sun_path is 104 bytes on macOS. Over that, listen() binds a
    // TRUNCATED name and succeeds, and the failure surfaces later and
    // elsewhere — the first sighting of this was a chmod failing ENOENT on a
    // socket that had just been created.
    //
    // Every other test in this file uses a short mkdtemp path, which is
    // exactly why none of them caught it and running the real bridge did.
    const tooLong = path.join(dir, `${'x'.repeat(120)}.sock`);
    const spool = createEventSpool({ dir: path.join(dir, 'spool') });
    const events = createEventSocket({ path: tooLong, spool });

    await assert.rejects(() => events.start(), /the kernel allows/);
    // And it must say what to do about it, not just that it went wrong.
    await assert.rejects(() => events.start(), /--events-socket/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a stale socket file is cleared, but a live one is refused', async () => {
  const dir = scratch();
  try {
    const socketPath = path.join(dir, 'events.sock');
    const spool = createEventSpool({ dir: path.join(dir, 'spool') });

    const first = createEventSocket({ path: socketPath, spool });
    await first.start();

    // A live bridge is holding it. Starting a second must fail loudly rather
    // than unlink the socket out from under a process that still owns the
    // WhatsApp session.
    const second = createEventSocket({ path: socketPath, spool });
    await assert.rejects(() => second.start(), /another bridge is already listening/);

    // Now the first is gone but has left the file behind, which is what a
    // kill -9 does. That file is a corpse and must not block a restart.
    await first.stop();
    const third = createEventSocket({ path: socketPath, spool });
    await third.start();
    assert.equal(statSync(socketPath).mode & 0o777, 0o600);
    await third.stop();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
