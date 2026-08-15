// Pushes spooled WhatsApp events to Mynah, and takes acknowledgements back.
// Mynah's, not upstream's.
//
// **Wire shape: one JSON object per line, both directions.** That is not a
// fresh invention — it is what signal-cli's JSON-RPC daemon speaks, so
// Sources/SageVoiceCore/Transport/SignalLineSocket.swift already reads it, and
// WhatsApp arrives on the Swift side in the same shape Signal does instead of
// as a second parallel mechanism. A serialised record can never contain a raw
// newline (JSON.stringify escapes them), so the delimiter is unambiguous even
// when somebody sends a multi-line message.
//
// Out, one per line:   {"seq":12,"event":{…}}
// In, one per line:    {"ack":12}
//
// **A UNIX socket, not the loopback TCP port upstream uses.** Upstream binds
// 127.0.0.1 and validates the Host header, which is a real defence against DNS
// rebinding (GHSA-ppp5-vxwm-4cf7) and still leaves the port reachable by every
// other account on the machine. A socket file at 0600 is checked by the
// kernel against the connecting user, needs no header validation to be safe,
// and cannot be reached by a browser at all. On a Mac with one login that is
// belt and braces; on a shared one it is the difference between a private
// channel and a public one.
//
// **Newest consumer wins.** Only one Mynah reads this. If a second connects,
// the first is closed rather than both being served, because two consumers
// sharing one ack stream means each one's ack retires the other's unread
// messages — silent loss, dressed as redundancy. Displacing rather than
// refusing is deliberate too: a daemon that crashed without closing its socket
// leaves a connection the kernel has not reaped yet, and refusing would lock
// the replacement out of its own bridge until something timed out.

import { connect, createServer } from 'net';
import { chmodSync, existsSync, unlinkSync } from 'fs';

const MAX_LINE_BYTES = 1 * 1024 * 1024;

// **A UNIX socket path is not an ordinary path, and the limit is small.**
// `sockaddr_un.sun_path` is 104 bytes on macOS, one of which is the
// terminator. Nothing warns you: `listen()` binds a TRUNCATED path and
// succeeds, and the first thing to notice is whatever touches the name you
// asked for — here, the chmod two lines later, failing ENOENT on a file that
// looks like it should obviously exist.
//
// This was found by running the real bridge with a long scratch path after
// ten socket tests had passed, because every test used a short one. The Swift
// side has known this all along — SignalLineSocket.swift:63 checks
// `sun_path`'s capacity and throws socketPathTooLong — and this file did not,
// which is the whole argument for the two ends speaking the same protocol
// rather than merely similar ones.
//
// The default lands at 82 bytes. That is under the limit but not comfortably,
// and it moves with the length of the account's home directory: a longer
// username than this Mac's is enough to push it over.
const MAX_SOCKET_PATH_BYTES = 103;

/**
 * @param {object} options
 * @param {string} options.path   socket file to listen on
 * @param {object} options.spool  createEventSpool() result
 * @param {(line: string) => void} [options.log]
 */
export function createEventSocket({ path: socketPath, spool, log = () => {} }) {
  let consumer = null;
  let server = null;

  function send(socket, record) {
    if (!socket || socket.destroyed) return;
    // MYNAH: which run of numbering this sequence belongs to.
    //
    // On every line rather than once at connect. A hello frame would be a
    // second line grammar for the consumer to recognise, and it only has to be
    // missed once — a reconnect that races it, a consumer that starts reading
    // mid-stream — for the epoch to be silently absent while sequences keep
    // arriving. Repeating it is ~20 bytes and cannot be missed.
    socket.write(`${JSON.stringify({ ...record, epoch: spool.epoch })}\n`);
  }

  /** Called by the bridge after spool.append(). */
  function notify(record) {
    send(consumer, record);
  }

  function handleLine(line) {
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      // Not fatal. A consumer that garbles a line has a bug, but dropping its
      // connection would stop delivery of everything else, and the events are
      // still spooled — the correct response is to say so and carry on.
      log(`[whatsapp] ignoring an unparseable line from the consumer`);
      return;
    }
    if (parsed && Object.prototype.hasOwnProperty.call(parsed, 'ack')) {
      const retired = spool.ack(parsed.ack);
      if (retired > 0) log(`[whatsapp] ${retired} event(s) acknowledged through ${parsed.ack}`);
      return;
    }
    log(`[whatsapp] consumer sent a line with no 'ack' field; ignoring`);
  }

  function attach(socket) {
    if (consumer && !consumer.destroyed) {
      log('[whatsapp] a second consumer connected; closing the first');
      consumer.destroy();
    }
    consumer = socket;
    socket.setNoDelay(true);

    // **Replay before anything live.** Everything unacknowledged goes out the
    // moment a consumer appears, in sequence order, including events that
    // arrived while nothing was listening. This is the half that makes the
    // spool worth having: without it a restart would still lose whatever came
    // in during the gap, and the disk file would be a diary nobody reads.
    const backlog = spool.pending();
    if (backlog.length > 0) {
      log(`[whatsapp] replaying ${backlog.length} unacknowledged event(s) to the new consumer`);
    }
    for (const record of backlog) send(socket, record);

    let buffer = '';
    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      if (buffer.length > MAX_LINE_BYTES) {
        log('[whatsapp] consumer sent an oversized line; dropping the connection');
        socket.destroy();
        buffer = '';
        return;
      }
      let newline;
      while ((newline = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) handleLine(line);
      }
    });

    const detach = () => { if (consumer === socket) consumer = null; };
    socket.on('close', detach);
    socket.on('error', (error) => {
      // A consumer going away mid-write is ordinary — Mynah restarts. The
      // events it had not acknowledged are still spooled and will be replayed.
      log(`[whatsapp] consumer connection ended: ${error.message}`);
      detach();
    });
  }

  async function start() {
    const pathBytes = Buffer.byteLength(socketPath, 'utf8');
    if (pathBytes > MAX_SOCKET_PATH_BYTES) {
      throw new Error(
        `the events socket path is ${pathBytes} bytes and the kernel allows ` +
        `${MAX_SOCKET_PATH_BYTES}:\n  ${socketPath}\n` +
        `Binding it would silently succeed on a truncated name and then fail ` +
        `somewhere unrelated. Pass a shorter --events-socket; anywhere you can ` +
        `write is fine, the socket itself is chmod 0600.`
      );
    }
    await clearStaleSocket(socketPath, log);
    server = createServer(attach);
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(socketPath, () => {
        server.removeListener('error', reject);
        resolve();
      });
    });
    // After listen, not before: the file does not exist until then.
    chmodSync(socketPath, 0o600);
    log(`[whatsapp] events socket at ${socketPath} (0600)`);
  }

  async function stop() {
    if (consumer && !consumer.destroyed) consumer.destroy();
    consumer = null;
    if (server) await new Promise((resolve) => server.close(resolve));
    server = null;
    if (existsSync(socketPath)) {
      try { unlinkSync(socketPath); } catch { /* already gone */ }
    }
  }

  return { start, stop, notify, get hasConsumer() { return !!consumer && !consumer.destroyed; } };
}

/**
 * A socket file left behind by a bridge that was killed rather than stopped.
 *
 * Deleting it unconditionally would be wrong: if a bridge really is running,
 * unlinking its socket makes it unreachable while it carries on holding the
 * WhatsApp session — the two-bridges collision described in PROVENANCE.md,
 * arrived at from the other direction. So: try to connect first. Something
 * answers, and this refuses to start. Nothing answers, and the file is a
 * corpse.
 */
function clearStaleSocket(socketPath, log) {
  return new Promise((resolve, reject) => {
    if (!existsSync(socketPath)) return resolve();

    const probe = connect(socketPath);
    const giveUp = setTimeout(() => { probe.destroy(); onDead(); }, 1000);

    function onDead() {
      clearTimeout(giveUp);
      try { unlinkSync(socketPath); } catch { /* raced with someone else */ }
      log(`[whatsapp] removed a stale socket at ${socketPath}`);
      resolve();
    }

    probe.once('connect', () => {
      clearTimeout(giveUp);
      probe.destroy();
      reject(new Error(
        `another bridge is already listening on ${socketPath}.\n` +
        `Stop it before starting this one — two bridges on one WhatsApp session ` +
        `invalidate each other's keys and both quietly stop decrypting.`
      ));
    });
    probe.once('error', onDead);
  });
}
