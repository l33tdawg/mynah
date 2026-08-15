// Media that has done its job stops being kept.
//
// **Nothing here ever deleted anything, and that is inherited rather than
// designed.** These cache directories come from Hermes, where a Python gateway
// owned the lifecycle and swept them. In Mynah the bridge is the only owner and
// no sweep came with them, so every photo, video, voice note, sticker and
// document the owner is sent accumulates for the life of the install.
//
// The disk is the smaller half. These are decrypted copies of private messages,
// written outside the WhatsApp session directory and kept indefinitely — an
// appliance quietly maintaining a plaintext archive of everything anybody sent
// its owner, which nothing in the product mentions and no control removes.
//
// Two bounds, because one is not enough. An age bound alone lets a heavy day —
// a holiday, a group that shares video — put gigabytes on the boot disk and
// keep them for the full window. A size bound alone deletes nothing at all on a
// quiet install, so a document from March is still there in December.

import { readdirSync, statSync, unlinkSync, existsSync } from 'fs';
import path from 'path';

/** Anything younger than this is never swept, whatever the size cap says. */
export const SAFETY_FLOOR_MS = 60 * 60 * 1000;      // one hour

const DEFAULT_MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000; // a fortnight
const DEFAULT_MAX_BYTES = 2 * 1024 * 1024 * 1024;    // 2 GiB across all caches

/**
 * Deletes cached media that is old, or that is over the size cap and not
 * recent. Returns what it did, so the caller can say so in the log rather than
 * removing the owner's files silently.
 *
 * **The safety floor is the part that must not be tuned away.** An attachment is
 * handed to the consumer as a PATH, not as bytes, and the consumer opens it when
 * it gets to the turn — which is after transcription, after the model, and after
 * however long the message sat in the spool waiting for Mynah to start. Sweeping
 * by size alone would race that: the busiest hour is exactly when the cap is hit
 * and exactly when the unread files are newest. So nothing inside the floor is
 * ever deleted, and if that means staying over the cap, the cap is what gives.
 *
 * @param {object} options
 * @param {string[]} options.dirs         cache directories to sweep
 * @param {number} options.now            ms since epoch; passed in so this is testable
 * @param {number} [options.maxAgeMs]
 * @param {number} [options.maxBytes]     across all `dirs` together
 * @param {(line: string) => void} [options.warn]
 */
export function sweepMediaCaches({
  dirs,
  now,
  maxAgeMs = DEFAULT_MAX_AGE_MS,
  maxBytes = DEFAULT_MAX_BYTES,
  warn = () => {},
}) {
  const files = [];
  let unreadable = 0;

  for (const dir of dirs) {
    if (!dir || !existsSync(dir)) continue;
    let names;
    try {
      names = readdirSync(dir);
    } catch (error) {
      // Reported, never passed over. A directory we cannot list is a directory
      // whose growth we are no longer bounding, and saying nothing here is how
      // that goes unnoticed until the disk is full.
      warn(`[whatsapp] could not list the media cache at ${dir}: ${error.message}`);
      continue;
    }
    for (const name of names) {
      const full = path.join(dir, name);
      try {
        const stat = statSync(full);
        if (!stat.isFile()) continue;
        files.push({ path: full, size: stat.size, mtimeMs: stat.mtimeMs });
      } catch {
        // Vanished between readdir and stat, or unreadable. Neither is worth a
        // line each; counted so a systematic failure is still visible.
        unreadable += 1;
      }
    }
  }

  const doomed = new Set();
  let freed = 0;

  // Age first. Independent of the cap, so a quiet install still forgets.
  for (const file of files) {
    if (now - file.mtimeMs > maxAgeMs) {
      doomed.add(file.path);
      freed += file.size;
    }
  }

  // Then size, oldest first, and only down to the floor.
  const total = files.reduce((sum, f) => sum + f.size, 0);
  if (total - freed > maxBytes) {
    const candidates = files
      .filter((f) => !doomed.has(f.path) && now - f.mtimeMs > SAFETY_FLOOR_MS)
      .sort((a, b) => a.mtimeMs - b.mtimeMs);
    for (const file of candidates) {
      if (total - freed <= maxBytes) break;
      doomed.add(file.path);
      freed += file.size;
    }
  }

  let removed = 0;
  let bytes = 0;
  for (const file of files) {
    if (!doomed.has(file.path)) continue;
    try {
      unlinkSync(file.path);
      removed += 1;
      bytes += file.size;
    } catch (error) {
      warn(`[whatsapp] could not remove cached media ${file.path}: ${error.message}`);
    }
  }

  const stillOver = total - bytes > maxBytes;
  return { removed, bytes, kept: files.length - removed, unreadable, stillOver };
}
