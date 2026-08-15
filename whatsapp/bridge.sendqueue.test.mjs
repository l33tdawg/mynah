// Two replies to one chat never interleave, and a reply never hangs.
//
// **This file used to re-declare the queue inside itself.** `createSendQueue()`
// was a local copy of bridge.js's implementation, so no case here could fail for
// anything wrong in bridge.js — and that is not hypothetical: the shipped
// `enqueueReply` deadlocked every outbound WhatsApp message while this file was
// green. A test that carries its own copy of the subject is a test of the copy.
//
// The queue now lives in bridge_helpers.js and is imported. bridge.js is not
// imported directly by anything here, because importing it opens a WhatsApp
// connection.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createSendQueue } from './bridge_helpers.js';

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test('sends run one at a time, in the order they were asked for', async () => {
  const order = [];
  const queue = createSendQueue(async () => {});
  const done = [
    queue.enqueueSend(async () => { order.push('a-start'); await tick(); order.push('a-end'); }),
    queue.enqueueSend(async () => { order.push('b-start'); await tick(); order.push('b-end'); }),
  ];
  await Promise.all(done);
  assert.deepEqual(order, ['a-start', 'a-end', 'b-start', 'b-end']);
});

test('a failed send does not wedge the ones behind it', async () => {
  const order = [];
  const queue = createSendQueue(async () => {});
  const first = queue.enqueueSend(async () => { throw new Error('WhatsApp said no'); });
  const second = queue.enqueueSend(async () => { order.push('ran'); });
  await assert.rejects(first, /WhatsApp said no/);
  await second;
  assert.deepEqual(order, ['ran'], 'one refused send stopped the queue for ever');
});

// --- the deadlock ---

test('a multi-chunk reply completes rather than hanging for ever', async () => {
  // The regression. `enqueueReply(fn)` holds the slot for the whole reply, and
  // `fn` used to call the *queued* send for each chunk — which chains onto a
  // tail that only settles when `fn` returns, while `fn` awaits it. Nothing
  // resolves. With the bug present this test does not fail an assertion, it
  // never returns, which is why it carries its own timeout.
  const sent = [];
  const queue = createSendQueue(async (chatId, payload) => {
    sent.push(payload.text);
    return { key: { id: `id-${sent.length}` } };
  });

  const reply = queue.enqueueReply(async (send) => {
    for (const chunk of ['one', 'two', 'three']) {
      await send('60123@s.whatsapp.net', { text: chunk });
    }
  });

  const finished = await Promise.race([
    reply.then(() => 'finished'),
    new Promise((resolve) => setTimeout(() => resolve('hung'), 1000)),
  ]);
  assert.equal(finished, 'finished', 'the reply never completed — the send queue is deadlocked');
  assert.deepEqual(sent, ['one', 'two', 'three']);
});

test('a deadlocked reply would also wedge every send after it', async () => {
  // The half that makes the deadlock catastrophic rather than local: the queue
  // is one promise chain, so a reply that never settles leaves the tail pending
  // and everything queued behind it waits for ever too. Asserting the fixed
  // behaviour — a later send still runs — is what pins that.
  const queue = createSendQueue(async () => ({ key: { id: 'x' } }));
  await queue.enqueueReply(async (send) => {
    await send('chat', { text: 'a' });
    await send('chat', { text: 'b' });
  });

  const after = await Promise.race([
    queue.enqueueSend(async () => 'ran'),
    new Promise((resolve) => setTimeout(() => resolve('hung'), 1000)),
  ]);
  assert.equal(after, 'ran', 'a send queued after a reply never ran');
});

test('another request cannot slot between one reply\'s chunks', async () => {
  // What the whole thing is for. Chunks are separated by a deliberate pause, and
  // before `enqueueReply` that pause was taken outside the queue — so a second
  // answer to the same chat interleaved: paragraph 1 of A, paragraph 1 of B,
  // paragraph 2 of A.
  const order = [];
  const queue = createSendQueue(async (chatId, payload) => { order.push(payload.text); });

  const reply = queue.enqueueReply(async (send) => {
    await send('chat', { text: 'A1' });
    await new Promise((resolve) => setTimeout(resolve, 30));
    await send('chat', { text: 'A2' });
  });
  // Queued while the reply is mid-pause, which is exactly the window that used
  // to be open.
  const interloper = queue.enqueueSend(async () => { order.push('B1'); });

  await Promise.all([reply, interloper]);
  assert.deepEqual(order, ['A1', 'A2', 'B1'], 'another message landed inside a reply');
});
