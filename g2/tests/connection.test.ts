import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MynahConnection } from '../src/connection.ts';

const link = 'https://call.sage.delivery/' + 'a'.repeat(32);

/// A peer that never negotiates anything: these cases are all decided before
/// the first byte of SDP, and a stub keeps the failure being tested legible.
class Peer {
  connectionState = 'new';
  iceGatheringState = 'complete';
  localDescription = { sdp: 'offer' };
  createDataChannel() { return { readyState: 'connecting' }; }
  addEventListener() {}
  removeEventListener() {}
  async createOffer() { return { type: 'offer', sdp: 'offer' }; }
  async setLocalDescription() {}
  async setRemoteDescription() {}
  close() {}
}

async function attempt(fetch_: typeof fetch) {
  const realFetch = globalThis.fetch;
  const realPeer = globalThis.RTCPeerConnection;
  globalThis.fetch = fetch_;
  // @ts-expect-error the stub is deliberately smaller than the real constructor
  globalThis.RTCPeerConnection = Peer;
  const connection = new MynahConnection(() => {}, () => {});
  try {
    await connection.connect(link);
    return undefined;
  } catch (error) {
    return (error as Error).message;
  } finally {
    connection.close();
    globalThis.fetch = realFetch;
    globalThis.RTCPeerConnection = realPeer;
  }
}

const respond = (status: number) => (async () => new Response('refused', { status })) as unknown as typeof fetch;

test('an expired pairing link says so, and says how to replace it', async () => {
  const message = await attempt(respond(404));
  assert.match(message ?? '', /expired/);
  assert.match(message ?? '', /\/\/g2/);
  assert.ok(!/revoked/.test(message ?? ''), 'a live pairing must not be described as revoked');
});

test('a Mac that is not holding a poll is named as that, not as a revoked pairing', async () => {
  const message = await attempt(respond(503));
  assert.match(message ?? '', /Mac is not answering/);
});

test('a Mac that took too long asks for another tap', async () => {
  const message = await attempt(respond(504));
  assert.match(message ?? '', /did not answer in time/);
});

test('a phone that cannot reach the relay blames the phone, not the pairing', async () => {
  const message = await attempt((async () => { throw new TypeError('Failed to fetch'); }) as typeof fetch);
  assert.match(message ?? '', /unreachable from this phone/);
  assert.ok(!/pairing/.test(message ?? ''));
});

test('an abort is a sentence too, rather than the DOMException text', async () => {
  const message = await attempt((async () => { throw Object.assign(new Error('signal is aborted without reason'), { name: 'AbortError' }); }) as typeof fetch);
  assert.match(message ?? '', /unreachable from this phone/);
});

test('anything else the relay answers keeps its own words', async () => {
  const message = await attempt(async () => ({ ok: true, status: 200, json: async () => ({ protocol: 'mynah.g2.v2', iceServers: [] }) }) as unknown as Response);
  assert.match(message ?? '', /Update the Mynah relay/);
});
