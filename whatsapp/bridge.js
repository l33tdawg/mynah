#!/usr/bin/env node
/**
 * WhatsApp Bridge — vendored from NousResearch/hermes-agent, MIT.
 *
 * See PROVENANCE.md beside this file for the exact upstream commit, what was
 * changed here and why, and how to re-sync. Every local change is marked with
 * a `MYNAH:` comment, so `grep -n 'MYNAH:' *.js` is the whole diff from
 * upstream without needing the upstream checkout.
 *
 * **This file is transport, and only transport.** It speaks WhatsApp and it
 * speaks HTTP on loopback. It holds no model, no tools and no memory — the
 * agent is Sources/SageVoiceCore, in Swift, and it is the same agent that
 * answers on Signal, in the window and on a call. Anything in here that starts
 * deciding what to say belongs on the other side of the socket.
 *
 * Standalone Node.js process that connects to WhatsApp via Baileys
 * and exposes HTTP endpoints for the Python gateway adapter.
 *
 * Endpoints (matches gateway/platforms/whatsapp.py expectations):
 *   GET  /messages       - Long-poll for new incoming messages
 *   POST /send           - Send a message { chatId, message, replyTo? }
 *   POST /edit           - Edit a sent message { chatId, messageId, message }
 *   POST /send-media     - Send media natively { chatId, filePath, mediaType?, caption?, fileName? }
 *   POST /send-location  - Send location pin { chatId, latitude, longitude, name?, address? }
 *   POST /typing         - Send typing indicator { chatId }
 *   GET  /chat/:id       - Get chat info
 *   GET  /health         - Health check
 *
 * Usage:
 *   node bridge.js --port 3000 --session ~/.hermes/whatsapp/session
 */

import { makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, downloadMediaMessage, getAggregateVotesInPollMessage, decryptPollVote, getKeyAuthor, jidNormalizedUser } from '@whiskeysockets/baileys';
import express from 'express';
import { Boom } from '@hapi/boom';
import pino from 'pino';
import path from 'path';
import { mkdirSync, readFileSync, writeFileSync, chmodSync, existsSync, readdirSync, unlinkSync } from 'fs';
import { fileURLToPath } from 'url';
import { randomBytes, createHash, timingSafeEqual } from 'crypto';
import { execFileSync } from 'child_process';
import { tmpdir } from 'os';
import qrcode from 'qrcode-terminal';
import { matchesAllowedUser, parseAllowedUsers } from './allowlist.js';
import { createOutboundIdTracker } from './outbound_ids.js';
import { classifyOwnerMessageGate } from './owner_message_gate.js';
import {
  buildPollPayload,
  createReconnectScheduler,
  createVersionResolver,
  buildLocationPayload,
  buildTextSendPayload,
  createBoundedMessageStore,
  extractBridgeEvent,
  inboundReadReceiptKeys,
  inferMediaType,
  mediaPayloadForFile,
  pollCreationMessageFromPayload,
  pollUpdateForAggregation,
} from './bridge_helpers.js';
// MYNAH: the durable inbound path. See event_spool.js for why upstream's
// GET /messages is not enough here.
import { createEventSpool } from './event_spool.js';
import { createEventSocket } from './event_socket.js';

// Parse CLI args
const args = process.argv.slice(2);
function getArg(name, defaultVal) {
  const idx = args.indexOf(`--${name}`);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : defaultVal;
}

const WHATSAPP_DEBUG =
  typeof process !== 'undefined' &&
  process.env &&
  typeof process.env.WHATSAPP_DEBUG === 'string' &&
  ['1', 'true', 'yes', 'on'].includes(process.env.WHATSAPP_DEBUG.toLowerCase());

// Opt-in: when true (and WHATSAPP_MODE === 'bot'), fromMe inbound messages
// that are NOT echoes of our own /send or /send-media calls are forwarded
// to the Python adapter with `fromOwner: true`. This lets plugins detect
// "owner just typed in this customer chat" — needed for handover / sliding
// TTL flows. Default OFF: existing deployments see no behavior change.
//
// Heuristic limitation: we distinguish bot-API-sent from owner-typed by
// looking up `key.id` in `recentlySentIds` (populated when /send returns).
// On bridge restart that set is empty, so a few in-flight bot replies may
// briefly look like owner-typed until they age out. Acceptable; we don't
// persist the set.
const FORWARD_OWNER_MESSAGES =
  typeof process !== 'undefined' &&
  process.env &&
  typeof process.env.WHATSAPP_FORWARD_OWNER_MESSAGES === 'string' &&
  ['1', 'true', 'yes', 'on'].includes(process.env.WHATSAPP_FORWARD_OWNER_MESSAGES.toLowerCase());

const SEND_READ_RECEIPTS =
  typeof process !== 'undefined' &&
  process.env &&
  typeof process.env.WHATSAPP_SEND_READ_RECEIPTS === 'string' &&
  ['1', 'true', 'yes', 'on'].includes(process.env.WHATSAPP_SEND_READ_RECEIPTS.toLowerCase());

// MYNAH: every default path moved out of ~/.hermes and under Mynah's own
// Application Support directory, where the rest of this app's state already
// lives (SingleInstance.swift, MynahIdentity.swift, PauseState.swift all use
// the same base).
//
// This is not tidiness. The owner may well run the real Hermes on this Mac —
// it is a popular agent and this bridge came from it. Two processes sharing
// ~/.hermes/whatsapp/session would be two WhatsApp clients writing one
// Baileys auth state, and Baileys does not arbitrate that: the second writer
// invalidates the first's keys and BOTH ends silently stop decrypting. The
// failure looks like WhatsApp being flaky rather than like a collision, which
// is the kind of bug that costs a weekend.
//
// The env vars keep their HERMES_ names so a re-sync from upstream is a clean
// diff; only the fallbacks changed.
const MYNAH_STATE_DIR = path.join(
  process.env.HOME || '~',
  'Library', 'Application Support', 'SAGE Voice Bridge', 'WhatsApp'
);

const PORT = parseInt(getArg('port', '3000'), 10);
const SESSION_DIR = getArg('session', path.join(MYNAH_STATE_DIR, 'session'));
// Cache directories: the Python gateway passes the profile-aware paths via
// env (HERMES_HOME-aware, new cache/ layout).  Fall back to the legacy
// hardcoded locations for bridges launched outside the gateway.
const IMAGE_CACHE_DIR = process.env.HERMES_IMAGE_CACHE_DIR
  || path.join(MYNAH_STATE_DIR, 'image_cache');
const DOCUMENT_CACHE_DIR = process.env.HERMES_DOCUMENT_CACHE_DIR
  || path.join(MYNAH_STATE_DIR, 'document_cache');
const AUDIO_CACHE_DIR = process.env.HERMES_AUDIO_CACHE_DIR
  || path.join(MYNAH_STATE_DIR, 'audio_cache');

// Self-hash of this script file.  Reported in /health so the Python gateway
// can detect a running bridge that predates the current bridge.js and
// restart it instead of silently reusing stale code (stale-bridge trap:
// `hermes update` updates bridge.js on disk but a long-lived bridge process
// keeps serving the old behavior forever).
let SCRIPT_HASH = '';
try {
  SCRIPT_HASH = createHash('sha256')
    .update(readFileSync(fileURLToPath(import.meta.url)))
    .digest('hex')
    .slice(0, 16);
} catch {}
const PAIR_ONLY = args.includes('--pair-only');
const PAIR_JSON = args.includes('--pair-json');
const WHATSAPP_MODE = getArg('mode', process.env.WHATSAPP_MODE || 'self-chat'); // "bot" or "self-chat"
const WHATSAPP_DM_POLICY = String(process.env.WHATSAPP_DM_POLICY || 'open').trim().toLowerCase();
const ALLOWED_USERS = parseAllowedUsers(process.env.WHATSAPP_ALLOWED_USERS || '');
const DEFAULT_REPLY_PREFIX = '⚕ *Hermes Agent*\n────────────\n';
const REPLY_PREFIX = process.env.WHATSAPP_REPLY_PREFIX === undefined
  ? DEFAULT_REPLY_PREFIX
  : process.env.WHATSAPP_REPLY_PREFIX.replace(/\\n/g, '\n');
const MAX_MESSAGE_LENGTH = parseInt(process.env.WHATSAPP_MAX_MESSAGE_LENGTH || '4096', 10);
const CHUNK_DELAY_MS = parseInt(process.env.WHATSAPP_CHUNK_DELAY_MS || '300', 10);
// Per-call timeout for sock.sendMessage(). Baileys occasionally hangs forever
// when uploading media to WhatsApp servers (and, less often, on text sends),
// which pins the bridge's HTTP handler until the upstream aiohttp timeout
// fires. Fail fast instead so the gateway can surface a real error and retry.
const SEND_TIMEOUT_MS = parseInt(process.env.WHATSAPP_SEND_TIMEOUT_MS || '60000', 10);

// --- Send queue: serialise all sock.sendMessage() calls across concurrent
//     HTTP handlers so a single Baileys socket never has overlapping sends.
//     Overlapping sends are the root cause of cross-chat contamination
//     (#33360) — the WhatsApp protocol-level routing can misdeliver when
//     two sendMessage() Promises race on the same socket. ---
let _sendQueue = Promise.resolve();

function enqueueSend(fn) {
  const task = _sendQueue.then(() => fn(), () => fn());
  _sendQueue = task.catch(() => {});
  return task;
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * MYNAH: one reply is one turn in the queue, however many chunks it is.
 *
 * `enqueueSend` serialises individual `sendMessage` calls, and a long reply is
 * several of them with a deliberate pause between each — a pause taken *outside*
 * the queue, so another request's chunks slot straight into it. Two answers
 * going to the same chat interleave: paragraph 1 of A, paragraph 1 of B,
 * paragraph 2 of A. The queue was serialising the wrong unit.
 *
 * Reachable on this appliance rather than theoretical: the daemon answers turns
 * sequentially, but the proactive watch, the after-the-call drain and an
 * unkept-promise apology all send on their own schedules, and any of them can
 * land inside another reply's chunk gap.
 *
 * Takes the queue slot for the whole run, and the inner `sendWithTimeout` calls
 * re-enter it — which is safe because `_sendQueue` is a promise chain rather than
 * a lock: the inner calls chain onto the tail this one already holds, so they run
 * in order and nothing deadlocks. What cannot get between them is another
 * *request*, which is the point.
 */
function enqueueReply(fn) {
  return enqueueSend(fn);
}

function sendWithTimeout(chatId, payload, options = {}, timeoutMs = SEND_TIMEOUT_MS) {
  let timer;
  const timeoutPromise = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`sendMessage timed out after ${timeoutMs / 1000}s`)),
      timeoutMs,
    );
  });
  return enqueueSend(() =>
    Promise.race([sock.sendMessage(chatId, payload, options), timeoutPromise])
      .finally(() => clearTimeout(timer))
  );
}

function formatOutgoingMessage(message) {
  // In bot mode, messages come from a different number so the prefix is
  // redundant — the sender identity is already clear.  Only prepend in
  // self-chat mode where bot and user share the same number.
  if (WHATSAPP_MODE !== 'self-chat') return message;
  return REPLY_PREFIX ? `${REPLY_PREFIX}${message}` : message;
}

function splitLongMessage(message, maxLength = MAX_MESSAGE_LENGTH) {
  const text = String(message || '');
  if (!text) return [];
  if (!Number.isFinite(maxLength) || maxLength < 1 || text.length <= maxLength) {
    return [text];
  }

  const chunks = [];
  let remaining = text;
  while (remaining.length > maxLength) {
    let splitAt = remaining.lastIndexOf('\n', maxLength);
    if (splitAt < Math.floor(maxLength / 2)) {
      splitAt = remaining.lastIndexOf(' ', maxLength);
    }
    if (splitAt < 1) splitAt = maxLength;

    chunks.push(remaining.slice(0, splitAt).trimEnd());
    remaining = remaining.slice(splitAt).trimStart();
  }
  if (remaining) chunks.push(remaining);
  return chunks;
}

function rememberSentMessage(sent, payload) {
  if (!sent?.key?.id) return;
  if (sent.message) {
    messageStore.remember(sent);
    return;
  }
  const syntheticMessage = pollCreationMessageFromPayload(payload);
  if (syntheticMessage) {
    messageStore.remember({ ...sent, message: syntheticMessage });
  }
}

function trackSentMessageId(sent) {
  rememberSentId(sent?.key?.id);
}

function normalizeWhatsAppId(value) {
  if (!value) return '';
  return String(value).replace(':', '@');
}

function redactWhatsAppId(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  const [userPart, domainPart = ''] = raw.split('@', 2);
  const bare = userPart.split(':', 1)[0];
  const digits = bare.replace(/\D/g, '');
  const suffix = digits ? digits.slice(-4) : bare.slice(-4);
  return `${suffix ? `…${suffix}` : '…'}${domainPart ? `@${domainPart}` : ''}`;
}

function emitDebugEvent(payload) {
  if (!WHATSAPP_DEBUG) return;
  try {
    console.log(JSON.stringify({ event: 'debug', ...payload }));
  } catch {}
}

function getMessageContent(msg) {
  const content = msg?.message || {};
  if (content.ephemeralMessage?.message) return content.ephemeralMessage.message;
  if (content.viewOnceMessage?.message) return content.viewOnceMessage.message;
  if (content.viewOnceMessageV2?.message) return content.viewOnceMessageV2.message;
  if (content.documentWithCaptionMessage?.message) return content.documentWithCaptionMessage.message;
  if (content.templateMessage?.hydratedTemplate) return content.templateMessage.hydratedTemplate;
  if (content.buttonsMessage) return content.buttonsMessage;
  if (content.listMessage) return content.listMessage;
  return content;
}

function getContextInfo(messageContent) {
  if (!messageContent || typeof messageContent !== 'object') return {};
  for (const value of Object.values(messageContent)) {
    if (value && typeof value === 'object' && value.contextInfo) {
      return value.contextInfo;
    }
  }
  return {};
}

mkdirSync(SESSION_DIR, { recursive: true });

// Build LID → phone reverse map from session files (lid-mapping-{phone}.json)
function buildLidMap() {
  const map = {};
  try {
    for (const f of readdirSync(SESSION_DIR)) {
      const m = f.match(/^lid-mapping-(\d+)\.json$/);
      if (!m) continue;
      const phone = m[1];
      const lid = JSON.parse(readFileSync(path.join(SESSION_DIR, f), 'utf8'));
      if (lid) map[String(lid)] = phone;
    }
  } catch {}
  return map;
}
let lidToPhone = buildLidMap();

/**
 * MYNAH: `<lid>@lid` → `<phone>@s.whatsapp.net`, when this session knows the
 * pair.
 *
 * Rebuilt on every `creds.update`, so a mapping learned mid-session is
 * available to the next message. Returns the input unchanged when there is no
 * mapping — an unresolvable LID is still refused by both allowlists, which is
 * the correct outcome for an address nobody can attribute. What this prevents is
 * the *resolvable* one being refused.
 */
function resolveLidToPhoneJid(jid) {
  if (!jid || !jid.endsWith('@lid')) return jid;
  const phone = lidToPhone[jid.replace(/@.*/, '')];
  return phone ? `${phone}@s.whatsapp.net` : jid;
}

const logger = pino({ level: 'warn' });

// Message queue for polling
const messageQueue = [];
const MAX_QUEUE_SIZE = 100;

// MYNAH: a second, durable way out for the same events.
//
// The queue above stays exactly as upstream wrote it, so `GET /messages` and
// upstream's own tests keep working unchanged and a re-sync stays readable.
// What is added is a spool and a socket beside it: an event is written to disk
// before anyone is told, and stays there until a consumer acknowledges it.
//
// Both paths see every event, and that is deliberate rather than sloppy — they
// are independent readers, not a fan-out that needs coordinating. The queue is
// still at-most-once and still drops its oldest past MAX_QUEUE_SIZE; the spool
// is the one Mynah reads, and the one that survives a restart on either side.
//
// Off unless asked for. Without --events-socket this file behaves precisely as
// upstream does, which is what makes the difference testable: the same bridge,
// one flag apart.
const EVENTS_SOCKET = getArg('events-socket', process.env.WHATSAPP_EVENTS_SOCKET || '');
const SPOOL_DIR = getArg('spool', path.join(MYNAH_STATE_DIR, 'spool'));

const eventSpool = EVENTS_SOCKET
  ? createEventSpool({ dir: SPOOL_DIR, warn: (line) => console.warn(line) })
  : null;
const eventSocket = EVENTS_SOCKET
  ? createEventSocket({ path: EVENTS_SOCKET, spool: eventSpool, log: (line) => console.log(line) })
  : null;

/**
 * MYNAH: the one way an inbound event leaves this file.
 *
 * Both upstream push sites call this instead of touching messageQueue, so
 * there is no route by which an event reaches one path and not the other. That
 * is the whole reason it is a function: the previous shape had the queue push
 * duplicated at two call sites 400 lines apart, and adding a third consumer to
 * only one of them is the kind of mistake nobody notices until a particular
 * kind of message stops arriving.
 */
function publish(event) {
  messageQueue.push(event);
  if (messageQueue.length > MAX_QUEUE_SIZE) {
    messageQueue.shift();
  }

  if (!eventSpool) return;
  try {
    const seq = eventSpool.append(event);
    eventSocket.notify({ seq, event });
  } catch (error) {
    // A full spool throws rather than dropping, and this is where that
    // decision is paid for. There is nothing clever to do: WhatsApp has
    // already been told the message was delivered, so it cannot be re-fetched,
    // and the consumer that would have taken it is evidently not running.
    //
    // Say so, loudly and with the number. A silent catch here would recreate
    // the exact defect this whole path exists to remove — except worse,
    // because the spool would look healthy while messages vanished.
    console.error(`[whatsapp] FAILED TO SPOOL AN INBOUND MESSAGE: ${error.message}`);
    console.error('[whatsapp] That message is not recoverable. Start Mynah, or');
    console.error(`[whatsapp] inspect the spool at ${SPOOL_DIR}.`);
  }
}

// Track recently sent message IDs.  Two purposes:
//   1. Prevent echo-back loops with media in self-chat mode.
//   2. (When WHATSAPP_FORWARD_OWNER_MESSAGES=true) distinguish our own
//      bot-API outbound messages from owner-typed messages on the linked
//      device so we can forward only the latter.
// Capacity bounded (see outbound_ids.js) to keep memory flat under
// sustained sending.
const recentlySentIds = createOutboundIdTracker(512);
const recentlyProcessedPollUpdates = createOutboundIdTracker(512);
const messageStore = createBoundedMessageStore(512);

function normalizePollUpdateOptions(aggregation, pollUpdateMessage, meId) {
  const selected = [];
  for (const option of aggregation || []) {
    if ((option.voters || []).length > 0 && option.name && option.name !== 'Unknown') {
      selected.push(option.name);
    }
  }
  if (selected.length > 0) return selected;

  // Fallback for already-decrypted pollUpdateMessage payloads where Baileys did
  // not have the creation message available. This may only yield hashes, but
  // keeping them in metadata is still better than dropping the vote entirely.
  const raw = pollUpdateMessage?.vote?.selectedOptions || [];
  return raw.map(option => String(option)).filter(Boolean);
}

function pollAggregationSummary(aggregation) {
  return (aggregation || []).map(option => ({
    name: option?.name || '',
    voterCount: (option?.voters || []).length,
  }));
}

function logPollUpdateDiagnostic({ sourcePath, pollId, pollCreation, pollUpdates, selectedOptions, aggregation }) {
  const firstUpdate = pollUpdates?.[0] || {};
  try {
    console.log(JSON.stringify({
      event: 'poll_update_decode',
      sourcePath,
      pollId: pollId || '',
      pollCreationFound: !!pollCreation,
      updateKeys: Object.keys(firstUpdate),
      hasVote: !!firstUpdate.vote,
      selectedOptionsLength: selectedOptions?.length || 0,
      aggregation: pollAggregationSummary(aggregation),
    }));
  } catch {}
}

function enqueuePollUpdateEvent({ key, update, selectedOptions, aggregation }) {
  const chatId = normalizeWhatsAppId(key?.remoteJid || update?.pollUpdates?.[0]?.pollUpdateMessageKey?.remoteJid || '');
  const senderId = normalizeWhatsAppId(
    key?.participant
    || update?.pollUpdates?.[0]?.pollUpdateMessageKey?.participant
    || chatId
  );
  const pollId = key?.id
    || update?.pollUpdates?.[0]?.pollCreationMessageKey?.id
    || update?.pollUpdates?.[0]?.pollUpdateMessageKey?.id
    || '';
  // Only surface votes on polls Hermes itself created (tracked when
  // /send-poll returns). Arbitrary human polls in a group chat must not
  // inject agent-visible messages on every vote.
  if (!pollId || !recentlySentIds.has(pollId)) {
    if (WHATSAPP_DEBUG) {
      try { console.log(JSON.stringify({ event: 'ignored', reason: 'foreign_poll_update', pollId })); } catch {}
    }
    return;
  }
  const chosenText = selectedOptions.length ? selectedOptions.join(', ') : `[Poll update${pollId ? `: ${pollId}` : ''}]`;
  const dedupeId = `poll:${pollId}:${senderId}:${selectedOptions.join('|')}`;
  if (recentlyProcessedPollUpdates.has(dedupeId)) return;
  recentlyProcessedPollUpdates.remember(dedupeId);
  const event = {
    messageId: `${pollId || 'poll'}:update:${Date.now()}`,
    chatId,
    senderId,
    senderName: senderId.replace(/@.*/, ''),
    chatName: chatId.replace(/@.*/, ''),
    isGroup: chatId.endsWith('@g.us'),
    body: chosenText,
    hasMedia: false,
    mediaType: 'poll_update',
    mime: '',
    fileName: '',
    nativeType: 'pollUpdateMessage',
    nativeMetadata: {
      pollUpdate: {
        pollId,
        selectedOptions,
        aggregation,
      },
    },
    mediaUrls: [],
    mentionedIds: [],
    quotedMessageId: pollId,
    quotedParticipant: '',
    quotedRemoteJid: chatId,
    quotedText: '',
    hasQuotedMessage: !!pollId,
    botIds: [],
    timestamp: Math.floor(Date.now() / 1000),
  };
  publish(event);   // MYNAH: was messageQueue.push + shift; see publish()
}

function rememberSentId(id) {
  recentlySentIds.remember(id);
}

let sock = null;
let connectionState = 'disconnected';

function emitPairEvent(event) {
  if (!PAIR_JSON) return;
  try {
    console.log(JSON.stringify({ ts: Date.now(), ...event }));
  } catch {}
}

const scheduleReconnect = createReconnectScheduler(() => startSocket());
const getWAVersion = createVersionResolver(fetchLatestBaileysVersion);

async function startSocket() {
  const { state, saveCreds } = await useMultiFileAuthState(SESSION_DIR);
  const version = await getWAVersion();

  sock = makeWASocket({
    ...(version ? { version } : {}),
    auth: state,
    logger,
    printQRInTerminal: false,
    browser: ['Hermes Agent', 'Chrome', '120.0'],
    syncFullHistory: false,
    markOnlineOnConnect: false,
    // Required for Baileys 7.x: without this, incoming messages that need
    // E2EE session re-establishment are silently dropped (msg.message === null)
    getMessage: async (key) => {
      // We don't maintain a message store, so return a placeholder.
      // This is enough for Baileys to complete the retry handshake.
      return { conversation: '' };
    },
  });

  // MYNAH: awaited-with-a-catch, not fire-and-forget.
  //
  // `saveCreds` is `async () => writeData(creds, 'creds.json')` and rejects on
  // ENOSPC, EACCES, EIO or a session directory that has gone. Node 22's default
  // for an unhandled rejection is to throw, and this file installs no
  // `unhandledRejection` handler — so a full disk did not degrade the bridge, it
  // ended the process, and KeepAlive then restarted it into the same full disk
  // every thirty seconds.
  //
  // Logged rather than fatal. Failing to persist a key rotation is recoverable:
  // the in-memory socket keeps working, and the next rotation writes both. What
  // is not recoverable is the process dying mid-session.
  sock.ev.on('creds.update', () => {
    Promise.resolve()
      .then(() => saveCreds())
      .catch((error) => {
        console.error(
          `[whatsapp] could not save the session credentials: ${error?.message || error}. ` +
          `This connection carries on, but if the bridge restarts before the next successful ` +
          `save it will ask for a new QR. Check free space and the permissions on ${SESSION_DIR}.`
        );
      });
    lidToPhone = buildLidMap();
  });

  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      if (PAIR_JSON) {
        emitPairEvent({ event: 'qr', qr });
      } else {
        console.log('\n📱 Scan this QR code with WhatsApp on your phone:\n');
        qrcode.generate(qr, { small: true });
        console.log('\nWaiting for scan...\n');
      }
    }

    if (connection === 'close') {
      const reason = new Boom(lastDisconnect?.error)?.output?.statusCode;
      connectionState = 'disconnected';

      if (reason === DisconnectReason.loggedOut) {
        emitPairEvent({ event: 'error', error: 'logged_out', reason });
        if (!PAIR_JSON) {
          console.log('❌ Logged out. Delete session and restart to re-authenticate.');
        }
        process.exit(1);
      } else {
        // 515 = restart requested (common after pairing). Always reconnect.
        emitPairEvent({ event: 'disconnected', reason });
        if (!PAIR_JSON) {
          if (reason === 515) {
            console.log('↻ WhatsApp requested restart (code 515). Reconnecting...');
          } else {
            console.log(`⚠️  Connection closed (reason: ${reason}). Reconnecting in 3s...`);
          }
        }
        scheduleReconnect(reason === 515 ? 1000 : 3000);
      }
    } else if (connection === 'open') {
      connectionState = 'connected';
      const connectedUser = sock?.user
        ? {
            id: sock.user.id || null,
            name: sock.user.name || sock.user.verifiedName || null,
          }
        : null;
      emitPairEvent({ event: 'connected', user: connectedUser });
      if (!PAIR_JSON) {
        console.log('✅ WhatsApp connected!');
      }
      if (PAIR_ONLY) {
        if (!PAIR_JSON) {
          console.log('✅ Pairing complete. Credentials saved.');
        }
        // Give Baileys a moment to flush creds, then exit cleanly
        setTimeout(() => process.exit(0), 2000);
      }
    }
  });

  sock.ev.on('messages.update', async (updates) => {
    for (const { key, update } of updates || []) {
      if (!update?.pollUpdates) continue;
      const pollCreationId = key?.id || update.pollUpdates?.[0]?.pollCreationMessageKey?.id;
      const pollCreation = messageStore.get(pollCreationId);
      let aggregation = [];
      let pollUpdates = update.pollUpdates;
      try {
        if (pollCreation) {
          const meId = jidNormalizedUser(sock.user?.id || 'me');
          pollUpdates = update.pollUpdates.map(pollUpdate => (
            pollUpdateForAggregation({
              pollUpdateMessage: pollUpdate,
              pollUpdateMessageKey: pollUpdate.pollUpdateMessageKey,
              pollCreation,
              decryptPollVote,
              getKeyAuthor,
              meId,
              pollCreatorJids: [
                jidNormalizedUser(sock.user?.lid || ''),
                jidNormalizedUser(sock.user?.id || ''),
                getKeyAuthor(pollUpdate.pollCreationMessageKey || key, jidNormalizedUser(sock.user?.lid || '')),
                getKeyAuthor(pollUpdate.pollCreationMessageKey || key, jidNormalizedUser(sock.user?.id || '')),
              ],
              voterJids: [
                normalizeWhatsAppId(pollUpdate.pollUpdateMessageKey?.participant || ''),
                normalizeWhatsAppId(pollUpdate.pollUpdateMessageKey?.remoteJid || key?.remoteJid || ''),
              ],
            }) || pollUpdate
          ));
          aggregation = getAggregateVotesInPollMessage({
            message: pollCreation.message,
            pollUpdates,
          });
        }
      } catch (err) {
        console.warn('[bridge] failed to aggregate poll update:', err.message);
      }
      const selectedOptions = normalizePollUpdateOptions(aggregation, pollUpdates?.[0]);
      logPollUpdateDiagnostic({
        sourcePath: 'messages.update',
        pollId: pollCreationId,
        pollCreation,
        pollUpdates,
        selectedOptions,
        aggregation,
      });
      enqueuePollUpdateEvent({ key, update: { ...update, pollUpdates }, selectedOptions, aggregation });
    }
  });

  sock.ev.on('messages.upsert', async ({ messages, type }) => {
    // In self-chat mode, your own messages commonly arrive as 'append' rather
    // than 'notify'. Accept both and filter agent echo-backs below.
    if (type !== 'notify' && type !== 'append') return;

    const botIds = Array.from(new Set([
      normalizeWhatsAppId(sock.user?.id),
      normalizeWhatsAppId(sock.user?.lid),
    ].filter(Boolean)));

    for (const msg of messages) {
      if (!msg.message) continue;

      const chatId = msg.key.remoteJid;
      // MYNAH: a LID resolved back to the phone number, because the consumer
      // cannot do it and destroys what it cannot recognise.
      //
      // WhatsApp increasingly addresses people by LID — an opaque per-account
      // id, `<digits>@lid`, that is not a phone number. This bridge copes: its
      // own allowlist walks the `lid-mapping-*.json` files in the session
      // directory. Mynah's second allowlist, on the Swift side, has no such
      // mapping and compares bare digits, so a `@lid` sender never matches and
      // is refused — and `WhatsAppClient.receive` responds to a refusal by
      // acknowledging the message, which retires it from this spool for good.
      //
      // So an owner whose own messages arrive over LID gets silence, and the
      // message is destroyed rather than held. The information needed to avoid
      // that exists here and nowhere else, so it travels with the event.
      const rawSenderId = normalizeWhatsAppId(msg.key.participant || chatId);
      const senderId = resolveLidToPhoneJid(rawSenderId);
      const isGroup = chatId.endsWith('@g.us');
      const senderNumber = senderId.replace(/@.*/, '');
      emitDebugEvent({
        stage: 'upsert',
        type,
        fromMe: !!msg.key.fromMe,
        chatId: redactWhatsAppId(chatId),
        senderId: redactWhatsAppId(senderId),
        messageKeys: Object.keys(msg.message || {}),
      });

      // Handle fromMe messages based on mode
      let fromOwner = false;
      if (msg.key.fromMe) {
        if (isGroup || chatId.includes('status')) {
          emitDebugEvent({
            stage: 'ignored',
            reason: isGroup ? 'from_me_group' : 'from_me_status',
            chatId: redactWhatsAppId(chatId),
          });
          continue;
        }

        if (WHATSAPP_MODE === 'bot') {
          // Bot mode: separate bot number. fromMe inbound is either
          //   (a) an echo of our own /send (recentlySentIds will catch it), or
          //   (b) a message the owner typed from their own phone using the
          //       linked-device session.
          //
          // We always drop (a). We drop (b) too unless the operator opts in
          // via WHATSAPP_FORWARD_OWNER_MESSAGES so existing deployments see
          // no behavior change. When opted in, we still gate on the
          // customer chatId allowlist — without that gate, any contact
          // the owner replied to would leak into Hermes and trigger
          // implicit handover. See `owner_message_gate.js`.
          const decision = classifyOwnerMessageGate({
            fromMe: true,
            fromOwnerEnabled: FORWARD_OWNER_MESSAGES,
            recentlySent: recentlySentIds,
            allowlistMatches: (id) => matchesAllowedUser(id, ALLOWED_USERS, SESSION_DIR),
            messageId: msg.key.id,
            chatId,
          });
          if (decision.action === 'drop_echo') continue;
          if (decision.action === 'drop_disabled') continue;
          if (decision.action === 'drop_allowlist') {
            try {
              console.log(JSON.stringify({
                event: 'ignored',
                reason: 'allowlist_mismatch_owner_chat',
                chatId,
                senderId,
              }));
            } catch {}
            continue;
          }
          fromOwner = true;
        } else {
          // Self-chat mode: only allow messages in the user's own self-chat.
          // WhatsApp now uses LID (Linked Identity Device) format: 67427329167522@lid
          // AND classic format: 34652029134@s.whatsapp.net
          // sock.user has both: { id: "number:10@s.whatsapp.net", lid: "lid_number:10@lid" }
          const myNumber = (sock.user?.id || '').replace(/:.*@/, '@').replace(/@.*/, '');
          const myLid = (sock.user?.lid || '').replace(/:.*@/, '@').replace(/@.*/, '');
          const chatNumber = chatId.replace(/@.*/, '');
          const isSelfChat = (myNumber && chatNumber === myNumber) || (myLid && chatNumber === myLid);
          emitDebugEvent({
            stage: 'self_chat_check',
            matched: !!isSelfChat,
            chatId: redactWhatsAppId(chatId),
            accountId: redactWhatsAppId(sock.user?.id),
            accountLid: redactWhatsAppId(sock.user?.lid),
          });
          if (!isSelfChat) {
            emitDebugEvent({
              stage: 'ignored',
              reason: 'self_chat_mismatch',
              chatId: redactWhatsAppId(chatId),
              senderId: redactWhatsAppId(senderId),
            });
            continue;
          }
        }
      }

      // Handle !fromMe messages (from other people) based on mode.
      // Self-chat mode only responds to the user's own messages to
      // themselves — stranger DMs / group pings must never reach the
      // Python gateway, otherwise a pairing-code reply fires in response
      // to arbitrary incoming messages (#8389).
      if (!msg.key.fromMe) {
        if (WHATSAPP_MODE === 'self-chat') {
          try {
            console.log(JSON.stringify({
              event: 'ignored',
              reason: 'self_chat_mode_rejects_non_self',
              chatId,
              senderId,
            }));
          } catch {}
          continue;
        }
        // MYNAH: a Status post is not a message to us, and answering one
        // publishes the reply to every contact the poster has.
        //
        // The `fromMe` branch above filters `status@broadcast`; this one checked
        // the sender allowlist and nothing else. A Status posted by an
        // allowlisted person — the owner himself, in the Message-Yourself setup
        // — arrives with `remoteJid: 'status@broadcast'`, passes the allowlist,
        // and becomes a message whose reply address is `status@broadcast`. The
        // agent's answer would go out as the owner's own WhatsApp Status.
        //
        // Groups are refused here for the same reason they are on the other
        // branch: `WhatsAppSenderAllowlist` refuses them on the Swift side too,
        // and a chat type this appliance does not serve should not reach the
        // spool at all.
        if (chatId === 'status@broadcast' || chatId.endsWith('@broadcast')) {
          emitDebugEvent({
            stage: 'ignored',
            reason: 'status_broadcast',
            chatId: redactWhatsAppId(chatId),
          });
          continue;
        }
        if (WHATSAPP_DM_POLICY !== 'pairing' && !matchesAllowedUser(senderId, ALLOWED_USERS, SESSION_DIR)) {
          try {
            // Redacted, like every neighbouring line. This one printed the
            // refused sender's full number and chat id into whatsapp.log — and
            // the sender who is refused most often is somebody the owner knows,
            // whose number is now on disk because they messaged him.
            console.log(JSON.stringify({
              event: 'ignored',
              reason: 'allowlist_mismatch',
              chatId: redactWhatsAppId(chatId),
              senderId: redactWhatsAppId(senderId),
            }));
          } catch {}
          continue;
        }
      }

      const messageContent = getMessageContent(msg);
      if (messageContent.pollUpdateMessage) {
        const pollUpdateMessage = messageContent.pollUpdateMessage;
        const pollKey = pollUpdateMessage.pollCreationMessageKey || {
          id: pollUpdateMessage.key?.id || msg.key.id,
          remoteJid: chatId,
          participant: senderId,
        };
        const pollCreation = messageStore.get(pollKey.id);
        let aggregation = [];
        let pollUpdates = [pollUpdateMessage];
        try {
          if (pollCreation) {
            const meId = jidNormalizedUser(sock.user?.id || 'me');
            const pollUpdate = pollUpdateForAggregation({
              pollUpdateMessage,
              pollUpdateMessageKey: msg.key,
              pollCreation,
              decryptPollVote,
              getKeyAuthor,
              meId,
              pollCreatorJids: [
                jidNormalizedUser(sock.user?.lid || ''),
                jidNormalizedUser(sock.user?.id || ''),
                getKeyAuthor(pollUpdateMessage.pollCreationMessageKey || pollKey, jidNormalizedUser(sock.user?.lid || '')),
                getKeyAuthor(pollUpdateMessage.pollCreationMessageKey || pollKey, jidNormalizedUser(sock.user?.id || '')),
              ],
              voterJids: [
                normalizeWhatsAppId(msg.key?.participant || ''),
                normalizeWhatsAppId(msg.key?.remoteJid || chatId || ''),
                normalizeWhatsAppId(senderId || ''),
              ],
            });
            if (pollUpdate) pollUpdates = [pollUpdate];
            aggregation = getAggregateVotesInPollMessage({
              message: pollCreation.message,
              pollUpdates,
            });
          }
        } catch (err) {
          console.warn('[bridge] failed to aggregate poll upsert:', err.message);
        }
        const selectedOptions = normalizePollUpdateOptions(aggregation, pollUpdates[0]);
        logPollUpdateDiagnostic({
          sourcePath: 'messages.upsert',
          pollId: pollKey.id,
          pollCreation,
          pollUpdates,
          selectedOptions,
          aggregation,
        });
        enqueuePollUpdateEvent({
          key: { ...pollKey, remoteJid: pollKey.remoteJid || chatId, participant: pollKey.participant || senderId },
          update: { pollUpdates },
          selectedOptions,
          aggregation,
        });
        continue;
      }

      const event = await extractBridgeEvent({
        msg,
        chatId,
        senderId,
        senderNumber,
        botIds,
        isGroup,
        downloadMedia: async (mediaMsg) => downloadMediaMessage(mediaMsg, 'buffer', {}, { logger, reuploadRequest: sock.updateMediaMessage }),
        cacheDirs: {
          image: IMAGE_CACHE_DIR,
          document: DOCUMENT_CACHE_DIR,
          audio: AUDIO_CACHE_DIR,
        },
      });
      event.fromOwner = fromOwner;

      // Ignore Hermes' own reply messages in self-chat mode to avoid loops.
      if (msg.key.fromMe && ((REPLY_PREFIX && event.body.startsWith(REPLY_PREFIX)) || recentlySentIds.has(msg.key.id))) {
        if (WHATSAPP_DEBUG) {
          emitDebugEvent({
            stage: 'ignored',
            reason: 'agent_echo',
            chatId: redactWhatsAppId(chatId),
            messageId: msg.key.id,
          });
        }
        continue;
      }

      // Skip empty messages
      if (!event.body && !event.hasMedia) {
        emitDebugEvent({
          stage: 'ignored',
          reason: 'empty',
          chatId: redactWhatsAppId(chatId),
          messageKeys: Object.keys(msg.message || {}),
        });
        continue;
      }

      messageStore.remember(msg);
      publish(event);   // MYNAH: was messageQueue.push; see publish()
      emitDebugEvent({
        stage: 'queued',
        chatId: redactWhatsAppId(chatId),
        senderId: redactWhatsAppId(senderId),
        fromOwner: !!fromOwner,
        bodyLength: event.body.length,
        hasMedia: event.hasMedia,
        mediaType: event.mediaType,
        queueLength: messageQueue.length,
      });
      // MYNAH: the trim that stood here moved into publish(), so both call
      // sites bound the queue the same way. Leaving it would have trimmed
      // twice on this path and once on the other.
    }
  });
}

// HTTP server
const app = express();
app.use(express.json());

// Host-header validation — defends against DNS rebinding.
// The bridge binds loopback-only (127.0.0.1) but a victim browser on
// the same machine could be tricked into fetching from an attacker
// hostname that TTL-flips to 127.0.0.1. Reject any request whose Host
// header doesn't resolve to a loopback alias.
// See GHSA-ppp5-vxwm-4cf7.
const _ACCEPTED_HOST_VALUES = new Set([
  'localhost',
  '127.0.0.1',
  '[::1]',
  '::1',
]);

app.use((req, res, next) => {
  const raw = (req.headers.host || '').trim();
  if (!raw) {
    return res.status(400).json({ error: 'Missing Host header' });
  }
  // Strip port suffix: "localhost:3000" → "localhost"
  const hostOnly = (raw.includes(':')
    ? raw.substring(0, raw.lastIndexOf(':'))
    : raw
  ).replace(/^\[|\]$/g, '').toLowerCase();
  if (!_ACCEPTED_HOST_VALUES.has(hostOnly)) {
    return res.status(400).json({
      error: 'Invalid Host header. Bridge accepts loopback hosts only.',
    });
  }
  next();
});

// MYNAH: a shared secret, because the Host check is not authentication and was
// the only thing in front of this API.
//
// **What it was protecting.** `POST /send` sends a WhatsApp message as the
// owner. `/send-media` takes a `filePath` this process reads and uploads, so any
// readable file on the Mac can be exfiltrated to any chat. `GET /messages`
// drains the inbound queue — every message the owner receives, and draining it
// takes it from whoever was reading. Before this, all of that was reachable by
// any process running as any user on the machine with one curl, and the Host
// header it had to send is a constant.
//
// The UNIX socket beside it is `0600` and carries acknowledgements in one
// direction only, so it was never the hole; the loopback port was, and
// `WhatsAppChannel` documents the port as the honest cost of using upstream's
// own send endpoint. This closes it without moving sends onto the socket.
//
// **A file rather than an argument.** A token in `ProgramArguments` is in the
// plist, which is world-readable, and in the output of `ps` for every account on
// the Mac. This reads a `0600` file that the same owner-only directory holds as
// the session keys. Absent means the token is generated and written here, so a
// bridge started by hand still comes up — and Mynah reads the same file.
//
// Compared with `timingSafeEqual`, which is not superstition on a local socket:
// an attacker who can time this can also run it a few million times.
const API_TOKEN_PATH = path.join(MYNAH_STATE_DIR, 'api-token');

function loadOrCreateApiToken() {
  try {
    const existing = readFileSync(API_TOKEN_PATH, 'utf8').trim();
    if (existing.length >= 32) return existing;
  } catch {}
  const minted = randomBytes(32).toString('hex');
  mkdirSync(MYNAH_STATE_DIR, { recursive: true, mode: 0o700 });
  writeFileSync(API_TOKEN_PATH, `${minted}\n`, { mode: 0o600 });
  // Rewritten explicitly: `mode` on writeFileSync is masked by umask, and a
  // umask of 022 turns 0600 into 0600 — but a pre-existing file keeps its own
  // mode entirely, which is the case that matters after an upgrade.
  chmodSync(API_TOKEN_PATH, 0o600);
  return minted;
}

const API_TOKEN = loadOrCreateApiToken();

app.use((req, res, next) => {
  // `/health` stays open. It reports liveness and nothing about the owner, and
  // it is what tells Mynah whether the bridge is up — including in the window
  // before it can read the token.
  if (req.path === '/health') return next();

  const offered = String(req.headers['x-mynah-token'] || '');
  const expected = API_TOKEN;
  // Length first: timingSafeEqual throws on a mismatch, and the length is not
  // the secret.
  if (offered.length !== expected.length ||
      !timingSafeEqual(Buffer.from(offered), Buffer.from(expected))) {
    return res.status(401).json({
      error: 'Missing or wrong X-Mynah-Token. This bridge answers only the app that started it.',
    });
  }
  next();
});

// Poll for new messages (long-poll style)
app.get('/messages', (req, res) => {
  const msgs = messageQueue.splice(0, messageQueue.length);
  res.json(msgs);
});

// Send a message
app.post('/send', async (req, res) => {
  if (!sock || connectionState !== 'connected') {
    return res.status(503).json({ error: 'Not connected to WhatsApp' });
  }

  const { chatId, message, replyTo } = req.body;
  if (!chatId || !message) {
    return res.status(400).json({ error: 'chatId and message are required' });
  }

  try {
    const chunks = splitLongMessage(formatOutgoingMessage(message));
    const messageIds = [];
    // The whole reply, not each chunk. See `enqueueReply`.
    await enqueueReply(async () => {
      for (let i = 0; i < chunks.length; i += 1) {
        const { content: payload, options } = buildTextSendPayload(chunks[i], {
          chatId,
          replyTo: i === 0 ? replyTo : undefined,
          messageStore,
        });
        const sent = await sendWithTimeout(chatId, payload, options);
        trackSentMessageId(sent);
        messageStore.remember(sent);
        if (sent?.key?.id) messageIds.push(sent.key.id);
        if (chunks.length > 1 && i < chunks.length - 1) {
          await sleep(CHUNK_DELAY_MS);
        }
      }
    });

    res.json({
      success: true,
      messageId: messageIds[messageIds.length - 1],
      messageIds,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Edit a previously sent message
app.post('/edit', async (req, res) => {
  if (!sock || connectionState !== 'connected') {
    return res.status(503).json({ error: 'Not connected to WhatsApp' });
  }

  const { chatId, messageId, message } = req.body;
  if (!chatId || !messageId || !message) {
    return res.status(400).json({ error: 'chatId, messageId, and message are required' });
  }

  try {
    const key = { id: messageId, fromMe: true, remoteJid: chatId };
    const chunks = splitLongMessage(formatOutgoingMessage(message));
    const messageIds = [];

    await sendWithTimeout(chatId, { text: chunks[0], edit: key });
    if (chunks.length > 1) {
      for (let i = 1; i < chunks.length; i += 1) {
        const sent = await sendWithTimeout(chatId, { text: chunks[i] });
        trackSentMessageId(sent);
        if (sent?.key?.id) messageIds.push(sent.key.id);
        if (i < chunks.length - 1) {
          await sleep(CHUNK_DELAY_MS);
        }
      }
    }

    res.json({ success: true, messageIds });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Send media (image, video, document) natively
app.post('/send-media', async (req, res) => {
  if (!sock || connectionState !== 'connected') {
    return res.status(503).json({ error: 'Not connected to WhatsApp' });
  }

  const { chatId, filePath, mediaType, caption, fileName } = req.body;
  if (!chatId || !filePath) {
    return res.status(400).json({ error: 'chatId and filePath are required' });
  }

  try {
    if (!existsSync(filePath)) {
      return res.status(404).json({ error: `File not found: ${filePath}` });
    }

    const buffer = readFileSync(filePath);
    const ext = filePath.toLowerCase().split('.').pop();
    const type = mediaType || inferMediaType(ext);
    let msgPayload;

    switch (type) {
      case 'image':
        if (ext === 'gif') {
          // WhatsApp's native animated-GIF UX is an MP4 video payload with
          // gifPlayback=true. Convert when ffmpeg is available; otherwise fall
          // back to a truthful image/gif send instead of mislabeling GIF bytes
          // as video/mp4.
          let tmpGifMp4 = null;
          try {
            tmpGifMp4 = path.join(tmpdir(), `hermes_gif_${randomBytes(6).toString('hex')}.mp4`);
            execFileSync(
              'ffmpeg',
              ['-y', '-i', filePath, '-movflags', 'faststart', '-pix_fmt', 'yuv420p', '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', tmpGifMp4],
              { timeout: 30000, stdio: 'pipe' }
            );
            msgPayload = {
              video: readFileSync(tmpGifMp4),
              caption: caption || undefined,
              mimetype: 'video/mp4',
              gifPlayback: true,
            };
          } catch (gifErr) {
            console.warn('[bridge] gif conversion failed, sending as image/gif:', gifErr.message);
            msgPayload = mediaPayloadForFile({ buffer, filePath, mediaType: type, caption, fileName });
          } finally {
            try { if (tmpGifMp4 && existsSync(tmpGifMp4)) unlinkSync(tmpGifMp4); } catch (_) {}
          }
        } else {
          msgPayload = mediaPayloadForFile({ buffer, filePath, mediaType: type, caption, fileName });
        }
        break;
      case 'video':
        msgPayload = mediaPayloadForFile({ buffer, filePath, mediaType: type, caption, fileName });
        break;
      case 'audio': {
        // WhatsApp only renders a native voice bubble (ptt) when the file is ogg/opus.
        // If the caller passes mp3, wav, m4a etc. (e.g. from Edge TTS / NeuTTS),
        // silently convert to ogg/opus via ffmpeg so ptt is always honoured.
        let audioBuffer = buffer;
        let audioExt = ext;
        const needsConversion = !['ogg', 'opus'].includes(ext);
        let tmpPath = null;
        if (needsConversion) {
          tmpPath = path.join(tmpdir(), `hermes_voice_${randomBytes(6).toString('hex')}.ogg`);
          try {
            execFileSync(
              'ffmpeg',
              ['-y', '-i', filePath, '-ar', '48000', '-ac', '1', '-c:a', 'libopus', tmpPath],
              { timeout: 30000, stdio: 'pipe' }
            );
            audioBuffer = readFileSync(tmpPath);
            audioExt = 'ogg';
          } catch (convErr) {
            // MYNAH: the usual case on this appliance, not an exception.
            //
            // ffmpeg ships with neither macOS nor this repository, and the
            // WhatsApp LaunchAgent's PATH is deliberately narrow. Mynah speaks
            // its replies as `.m4a`, so every spoken reply takes this branch
            // unless the owner happens to have ffmpeg installed — which the
            // plist's PATH now looks for.
            console.warn(
              `[bridge] could not convert ${ext} to ogg/opus (${convErr.message}). ` +
              `Sending it as an ordinary audio file: it plays, but WhatsApp will not ` +
              `draw it as a voice bubble. Install ffmpeg to get the bubble.`
            );
          } finally {
            try { if (tmpPath && existsSync(tmpPath)) unlinkSync(tmpPath); } catch (_) {}
          }
        }
        // MYNAH: the real type, rather than `audio/mpeg` for everything that is
        // not ogg.
        //
        // The fallback above is reached by every spoken Mynah reply, and it used
        // to label an AAC-in-MPEG-4 file as `audio/mpeg` — which is mp3. Some
        // clients take the declared type at its word and fail to decode; the
        // rest ignore it, which only means the mislabelling costs nothing
        // *today*. Sending a truthful type is free.
        const AUDIO_MIME_BY_EXTENSION = {
          ogg: 'audio/ogg; codecs=opus',
          opus: 'audio/ogg; codecs=opus',
          m4a: 'audio/mp4',
          mp4: 'audio/mp4',
          aac: 'audio/aac',
          mp3: 'audio/mpeg',
          wav: 'audio/wav',
          flac: 'audio/flac',
          amr: 'audio/amr',
        };
        const isVoiceNote = audioExt === 'ogg' || audioExt === 'opus';
        // Unknown extensions keep the old default rather than guessing something
        // new: this is the one place a wrong answer is worse than a vague one.
        const audioMime = AUDIO_MIME_BY_EXTENSION[audioExt] || 'audio/mpeg';
        msgPayload = { audio: audioBuffer, mimetype: audioMime, ptt: isVoiceNote };
        break;
      }
      case 'document':
      default:
        msgPayload = mediaPayloadForFile({ buffer, filePath, mediaType: 'document', caption, fileName });
        break;
    }

    const sent = await sendWithTimeout(chatId, msgPayload);
    trackSentMessageId(sent);
    messageStore.remember(sent);
    res.json({ success: true, messageId: sent?.key?.id });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Send poll primitive. Approval UX is intentionally not wired here; gateway
// approvals need text fallback and explicit confirmation semantics above this
// low-level transport helper.
app.post('/send-poll', async (req, res) => {
  if (!sock || connectionState !== 'connected') {
    return res.status(503).json({ error: 'Not connected to WhatsApp' });
  }

  const { chatId, question, options, selectableCount } = req.body;
  if (!chatId || !question || !Array.isArray(options)) {
    return res.status(400).json({ error: 'chatId, question, and options are required' });
  }

  try {
    const payload = buildPollPayload({ question, options, selectableCount });
    const sent = await sendWithTimeout(chatId, payload);
    trackSentMessageId(sent);
    rememberSentMessage(sent, payload);
    res.json({ success: true, messageId: sent?.key?.id });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// Send native WhatsApp location pin
app.post('/send-location', async (req, res) => {
  if (!sock || connectionState !== 'connected') {
    return res.status(503).json({ error: 'Not connected to WhatsApp' });
  }

  const { chatId, latitude, longitude, name, address } = req.body;
  if (!chatId || latitude === undefined || longitude === undefined) {
    return res.status(400).json({ error: 'chatId, latitude, and longitude are required' });
  }

  try {
    const payload = buildLocationPayload({ latitude, longitude, name, address });
    const sent = await sendWithTimeout(chatId, payload);
    trackSentMessageId(sent);
    messageStore.remember(sent);
    res.json({ success: true, messageId: sent?.key?.id });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// Typing indicator
app.post('/typing', async (req, res) => {
  if (!sock || connectionState !== 'connected') {
    return res.status(503).json({ error: 'Not connected' });
  }

  const { chatId } = req.body;
  if (!chatId) return res.status(400).json({ error: 'chatId required' });

  try {
    await sock.sendPresenceUpdate('composing', chatId);
    res.json({ success: true });
  } catch (err) {
    res.json({ success: false });
  }
});

// Mark an inbound message as read only after the Python adapter has accepted
// it through the authoritative DM/group/mention intake policy.
app.post('/read', async (req, res) => {
  if (!sock || connectionState !== 'connected') {
    return res.status(503).json({ error: 'Not connected' });
  }

  const receiptKeys = inboundReadReceiptKeys({
    key: req.body?.key,
    enabled: SEND_READ_RECEIPTS,
  });
  if (receiptKeys.length === 0) {
    return res.json({ success: true, marked: false });
  }

  try {
    await sock.readMessages(receiptKeys);
    return res.json({ success: true, marked: true });
  } catch (err) {
    console.warn('[bridge] failed to send read receipt:', err.message);
    return res.status(500).json({ error: 'Failed to send read receipt' });
  }
});

// Chat info
app.get('/chat/:id', async (req, res) => {
  const chatId = req.params.id;
  const isGroup = chatId.endsWith('@g.us');

  if (isGroup && sock) {
    try {
      const metadata = await sock.groupMetadata(chatId);
      return res.json({
        name: metadata.subject,
        isGroup: true,
        participants: metadata.participants.map(p => p.id),
      });
    } catch {
      // Fall through to default
    }
  }

  res.json({
    name: chatId.replace(/@.*/, ''),
    isGroup,
    participants: [],
  });
});

// Health check
app.get('/health', (req, res) => {
  res.json({
    status: connectionState,
    queueLength: messageQueue.length,
    uptime: process.uptime(),
    scriptHash: SCRIPT_HASH,
    sendReadReceipts: SEND_READ_RECEIPTS,
    // MYNAH: the durable path's state, so "is anything stuck?" is answerable
    // without reading files. `spool: null` means the socket was never asked
    // for — which is a different thing from a spool that is empty, and the two
    // must not look alike here of all places.
    spool: eventSpool
      ? { ...eventSpool.stats(), consumerConnected: eventSocket.hasConsumer }
      : null,
  });
});

// MYNAH: the last line of defence, and it belongs above everything that runs.
//
// One unawaited promise was enough to end this process — `saveCreds` was the
// one an audit found, and it is fixed at its own call site. This is here for the
// next one. Node 22 throws on an unhandled rejection by default, and a bridge
// that exits takes the owner's WhatsApp with it; launchd restarts it thirty
// seconds later, which turns a transient fault into a reconnect loop WhatsApp
// eventually responds to by dropping the linked device.
//
// **Deliberately does not exit.** That is the opposite of Node's default and it
// is the right trade for this process: it holds one socket and a spool, both of
// which survive an error in a request handler, and there is no state here worth
// more than the connection. Logged loudly enough to find, because a swallowed
// error nobody can see is how the next one takes a week to diagnose.
process.on('unhandledRejection', (reason) => {
  console.error(
    `[whatsapp] an operation failed and nothing was waiting for the result: ` +
    `${reason?.stack || reason?.message || reason}. The bridge is still running. ` +
    `If WhatsApp misbehaves after this line, it is the place to start.`
  );
});
process.on('uncaughtException', (error) => {
  console.error(
    `[whatsapp] uncaught: ${error?.stack || error?.message || error}. The bridge is still ` +
    `running, but this one is not routine — please report the lines above.`
  );
});

// Start
if (PAIR_ONLY) {
  // Pair-only mode: just connect, show QR, save creds, exit. No HTTP server.
  if (PAIR_JSON) {
    emitPairEvent({ event: 'started', session: SESSION_DIR });
  } else {
    console.log('📱 WhatsApp pairing mode');
    console.log(`📁 Session: ${SESSION_DIR}`);
    console.log();
  }
  startSocket().catch((err) => {
    emitPairEvent({ event: 'error', error: err?.message || String(err) });
    if (!PAIR_JSON) {
      console.error(err);
    }
    process.exit(1);
  });
} else {
  // MYNAH: the events socket comes up BEFORE the HTTP listener and before
  // WhatsApp is connected, and a failure here is fatal rather than logged.
  //
  // Both halves of that are deliberate. If it started later, messages could
  // arrive in the gap with nowhere durable to go. And the one way it fails is
  // clearStaleSocket refusing because another bridge already holds the path —
  // carrying on from that would mean two bridges on one WhatsApp session,
  // which is the failure PROVENANCE.md describes: they invalidate each other's
  // keys and both stop decrypting, silently.
  if (eventSocket) {
    await eventSocket.start().catch((error) => {
      console.error(`error: ${error.message}`);
      process.exit(1);
    });
    const waiting = eventSpool.stats().pending;
    if (waiting > 0) {
      console.log(`📬 ${waiting} message(s) waiting from before this restart`);
    }
  }

  app.listen(PORT, '127.0.0.1', () => {
    console.log(`🌉 WhatsApp bridge listening on port ${PORT} (mode: ${WHATSAPP_MODE})`);
    console.log(`📁 Session stored in: ${SESSION_DIR}`);
    if (ALLOWED_USERS.size > 0) {
      console.log(`🔒 Allowed users: ${Array.from(ALLOWED_USERS).join(', ')}`);
    } else if (WHATSAPP_MODE === 'self-chat') {
      console.log(`🔒 Self-chat mode — only your own messages to yourself are processed.`);
    } else if (WHATSAPP_MODE === 'bot' && WHATSAPP_DM_POLICY === 'pairing') {
      console.log(`🤝 WHATSAPP_DM_POLICY=pairing — unknown DMs are forwarded for gateway pairing.`);
    } else {
      console.log(`🔒 No WHATSAPP_ALLOWED_USERS set — incoming messages are rejected.`);
      console.log(`   Set WHATSAPP_ALLOWED_USERS=<phone> to authorize specific users,`);
      console.log(`   or WHATSAPP_ALLOWED_USERS=* for an explicit open bot.`);
    }
    if (WHATSAPP_MODE === 'bot' && FORWARD_OWNER_MESSAGES) {
      console.log(`👤 WHATSAPP_FORWARD_OWNER_MESSAGES=true — owner-typed messages will be forwarded with fromOwner:true`);
    }
    console.log();
    scheduleReconnect(0);
  });
}
