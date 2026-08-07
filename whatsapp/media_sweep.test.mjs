// Cached media is forgotten eventually, and never while it is still needed.
//
// Nothing swept these before. The directories are inherited from Hermes, whose
// Python gateway owned the lifecycle; in Mynah the bridge is the only owner and
// no sweep came with them. Every photo, video, voice note, sticker and document
// the owner was sent stayed on the boot disk for the life of the install —
// decrypted, outside the WhatsApp session directory, mentioned nowhere in the
// product and removable by no control in it.
//
// The hazard in fixing it is the opposite one, and these tests exist mostly for
// that: an attachment reaches the consumer as a PATH, opened when the turn gets
// to it. Sweeping too eagerly deletes a message out from under the answer.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, existsSync, readdirSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';

import { sweepMediaCaches, SAFETY_FLOOR_MS } from './media_sweep.js';

const NOW = 1_786_110_000_000;   // fixed, so nothing here depends on the clock
const DAY = 24 * 60 * 60 * 1000;

function cacheDir() {
  const root = mkdtempSync(path.join(tmpdir(), 'mynah-media-'));
  const dir = path.join(root, 'image_cache');
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** A file of `size` bytes, last modified `ageMs` before NOW. */
function file(dir, name, { ageMs = 0, size = 16 } = {}) {
  const full = path.join(dir, name);
  writeFileSync(full, Buffer.alloc(size));
  const seconds = (NOW - ageMs) / 1000;
  utimesSync(full, seconds, seconds);
  return full;
}

test('media older than the age bound is removed', () => {
  const dir = cacheDir();
  const old = file(dir, 'img_old.jpg', { ageMs: 30 * DAY });
  const recent = file(dir, 'img_recent.jpg', { ageMs: 1 * DAY });

  const result = sweepMediaCaches({ dirs: [dir], now: NOW, maxAgeMs: 14 * DAY });

  assert.equal(existsSync(old), false, 'a month-old photo is still on the disk');
  assert.equal(existsSync(recent), true, 'a photo from yesterday was deleted');
  assert.equal(result.removed, 1);
});

test('a quiet install still forgets, with no size pressure at all', () => {
  // The half a size cap alone cannot do: two small files and gigabytes of
  // headroom, and the one from March should still go.
  const dir = cacheDir();
  file(dir, 'doc_march.pdf', { ageMs: 120 * DAY, size: 8 });
  file(dir, 'doc_today.pdf', { ageMs: 0, size: 8 });

  const result = sweepMediaCaches({
    dirs: [dir], now: NOW, maxAgeMs: 14 * DAY, maxBytes: 1024 * 1024 * 1024,
  });

  assert.equal(result.removed, 1);
  assert.deepEqual(readdirSync(dir), ['doc_today.pdf']);
});

test('a heavy day is brought under the size cap, oldest first', () => {
  // The half an age bound alone cannot do: everything is inside the age window
  // and together it is far too much.
  const dir = cacheDir();
  file(dir, 'vid_1.mp4', { ageMs: 5 * DAY, size: 400 });
  file(dir, 'vid_2.mp4', { ageMs: 4 * DAY, size: 400 });
  file(dir, 'vid_3.mp4', { ageMs: 3 * DAY, size: 400 });

  const result = sweepMediaCaches({
    dirs: [dir], now: NOW, maxAgeMs: 14 * DAY, maxBytes: 900,
  });

  assert.equal(result.removed, 1, 'the cap removed the wrong number of files');
  assert.equal(existsSync(path.join(dir, 'vid_1.mp4')), false, 'the oldest should go first');
  assert.equal(existsSync(path.join(dir, 'vid_3.mp4')), true, 'the newest was deleted first');
});

// --- the hazard that matters ---

test('a file too recent to be safe is kept even when that leaves us over the cap', () => {
  // **The assertion this whole module is built around.** An attachment is handed
  // to Mynah as a path and opened when the turn reaches it — after the message
  // sat in the spool, after transcription, after the model. The busiest hour is
  // exactly when the cap is hit and exactly when the unread files are newest, so
  // a size-only sweep races the answer it is meant to be serving.
  const dir = cacheDir();
  const justArrived = file(dir, 'aud_new.ogg', { ageMs: 60 * 1000, size: 5000 });

  const result = sweepMediaCaches({
    dirs: [dir], now: NOW, maxAgeMs: 14 * DAY, maxBytes: 100,
  });

  assert.equal(existsSync(justArrived), true, 'a voice note was deleted before it could be read');
  assert.equal(result.removed, 0);
  assert.equal(result.stillOver, true, 'staying over the cap has to be reported, not hidden');
});

test('the safety floor is an hour, and the boundary is not off by one', () => {
  const dir = cacheDir();
  const inside = file(dir, 'img_inside.jpg', { ageMs: SAFETY_FLOOR_MS - 1000, size: 5000 });
  const outside = file(dir, 'img_outside.jpg', { ageMs: SAFETY_FLOOR_MS + 1000, size: 5000 });

  sweepMediaCaches({ dirs: [dir], now: NOW, maxAgeMs: 14 * DAY, maxBytes: 100 });

  assert.equal(existsSync(inside), true, 'a file inside the safety floor was swept by the size cap');
  assert.equal(existsSync(outside), false, 'nothing was swept at all');
});

test('the age bound still applies to files inside the safety floor', () => {
  // The floor protects against the SIZE cap, not against age — and the two
  // cannot overlap anyway, since the floor is an hour and the age bound is a
  // fortnight. Stated so that shrinking the age bound to something under an hour
  // fails here rather than silently deleting live attachments.
  const dir = cacheDir();
  const brandNew = file(dir, 'img_new.jpg', { ageMs: 60 * 1000 });
  sweepMediaCaches({ dirs: [dir], now: NOW, maxAgeMs: 30 * 1000 });
  assert.equal(existsSync(brandNew), false);
});

// --- not making things worse ---

test('a cache directory that does not exist is not an error', () => {
  const result = sweepMediaCaches({
    dirs: [path.join(tmpdir(), 'mynah-media-nonexistent-dir')], now: NOW,
  });
  assert.equal(result.removed, 0);
});

test('the size cap is measured across all the caches together', () => {
  // Three directories, one budget. Measuring them separately would let the total
  // reach three times the cap while every individual sweep reported itself
  // healthy.
  const images = cacheDir();
  const documents = path.join(path.dirname(images), 'document_cache');
  mkdirSync(documents, { recursive: true });

  file(images, 'img_1.jpg', { ageMs: 5 * DAY, size: 400 });
  file(documents, 'doc_1.pdf', { ageMs: 4 * DAY, size: 400 });

  const result = sweepMediaCaches({
    dirs: [images, documents], now: NOW, maxAgeMs: 14 * DAY, maxBytes: 500,
  });

  assert.equal(result.removed, 1);
  assert.equal(existsSync(path.join(images, 'img_1.jpg')), false, 'the oldest across both should go');
});

test('a subdirectory is left alone rather than treated as a file', () => {
  const dir = cacheDir();
  mkdirSync(path.join(dir, 'nested'), { recursive: true });
  const result = sweepMediaCaches({ dirs: [dir], now: NOW, maxAgeMs: 0 });
  assert.equal(result.removed, 0);
  assert.equal(existsSync(path.join(dir, 'nested')), true);
});
