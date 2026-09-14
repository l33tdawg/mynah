import { connectionURL, protocol, replyEvent, type ReplyEvent } from './protocol.ts';

/// Why a step could not be taken, authored per case.
///
/// The three refusals the relay can give have three different next steps: a link
/// that is gone (`//g2` again), a Mac that is not holding a poll yet (wait a
/// moment), and a Mac that took too long (tap again). Every one of them used to
/// arrive as the same sentence about a revoked pairing — which sent the owner to
/// re-pair a pairing that was fine, and is how "the link did not change" became
/// a question worth asking. The relay's own body text is not repeated for the
/// same reason it is not repeated anywhere else in this product: it is written
/// for an operator, not for a person holding glasses.
function refusal(status: number): Error {
  if (status === 404) return new Error('This pairing link has expired. Send //g2 in your chat for a new one, then paste it here.');
  if (status === 503) return new Error('Your Mac is not answering yet. Reconnecting automatically; tap again in a moment.');
  if (status === 504) return new Error('Your Mac did not answer in time. Tap again to retry.');
  return new Error('Mynah is offline or the pairing was revoked. Reconnecting automatically.');
}

/// A refusal to reach the relay at all.
///
/// `fetch` rejects with a bare `TypeError`, and both signals in this class abort
/// with a `DOMException` whose message is "The operation was aborted" or "signal
/// is aborted without reason". None of those is a sentence, and all of them used
/// to reach the status line as one. The phone's connection is the suspect
/// because that is the part the owner can do something about; the pairing is
/// not, and saying so is what made a working pairing look revoked.
function unreachable(error: unknown): Error {
  if (error instanceof Error && ['AbortError', 'TimeoutError', 'TypeError'].includes(error.name)) {
    return new Error('Mynah is unreachable from this phone. Check its connection; reconnecting automatically.');
  }
  return error instanceof Error ? error : new Error('Something went wrong reaching Mynah. Reconnecting automatically.');
}

export class MynahConnection {
  private peer?: RTCPeerConnection;
  private channel?: RTCDataChannel;
  private abort = new AbortController();
  private closed = false;
  private readyTimer?: ReturnType<typeof setTimeout>;
  // Ordinary fields rather than constructor parameter properties: this file is
  // imported directly by its test, and Node's type-stripping runner rejects the
  // short form. One assignment is a smaller price than a test that cannot read
  // the code it is testing.
  private event: (event: ReplyEvent) => void;
  private ended: () => void;
  constructor(event: (event: ReplyEvent) => void, ended: () => void) {
    this.event = event;
    this.ended = ended;
  }

  async connect(input: string) {
    try {
      await this.open(input);
    } catch (error) {
      // Aborted by `close()`, which is how the companion supersedes a connection
      // on purpose: the end path is already telling the owner what happened, and
      // this one must not add "unreachable from this phone" to it.
      if (this.closed) throw error;
      throw unreachable(error);
    }
  }

  private async open(input: string) {
    const url = connectionURL(input);
    const signal = AbortSignal.any([this.abort.signal, AbortSignal.timeout(30000)]);
    const config = await fetch(`${url}/connect`, { signal, credentials: 'omit', referrerPolicy: 'no-referrer' });
    if (!config.ok) throw refusal(config.status);
    const data = await config.json();
    if (data.protocol !== protocol || !Array.isArray(data.iceServers)) throw new Error('Update the Mynah relay to support G2.');
    signal.throwIfAborted();
    const peer = this.peer = new RTCPeerConnection({ iceServers: data.iceServers });
    const channel = this.channel = peer.createDataChannel(protocol, { ordered: true });
    channel.onmessage = message => {
      if (this.closed) return;
      try {
        const event = replyEvent(message.data);
        if (event.type === 'ready') clearTimeout(this.readyTimer);
        this.event(event);
      } catch { this.close(); }
    };
    channel.onclose = () => this.close();
    channel.onerror = () => this.close();
    peer.onconnectionstatechange = () => {
      if (['failed','closed','disconnected'].includes(peer.connectionState)) this.close();
    };
    this.readyTimer = setTimeout(() => this.close(), 45000);
    await peer.setLocalDescription(await peer.createOffer());
    await new Promise<void>((resolve, reject) => {
      const finish = () => { clearTimeout(timer); peer.removeEventListener('icegatheringstatechange', change); signal.removeEventListener('abort', abort); resolve(); };
      const change = () => { if (peer.iceGatheringState === 'complete') finish(); };
      const abort = () => {
        clearTimeout(timer); peer.removeEventListener('icegatheringstatechange', change);
        signal.removeEventListener('abort', abort); reject(signal.reason);
      };
      const timer = setTimeout(finish, 5000);
      peer.addEventListener('icegatheringstatechange', change);
      signal.addEventListener('abort', abort, { once: true });
      if (signal.aborted) abort(); else change();
    });
    signal.throwIfAborted();
    const response = await fetch(`${url}/offer`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sdp: peer.localDescription?.sdp }), signal,
      credentials: 'omit', referrerPolicy: 'no-referrer'
    });
    if (!response.ok) throw refusal(response.status);
    const answer = await response.json();
    signal.throwIfAborted();
    await peer.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
  }

  startRequest(id: string, parentId?: string) {
    if (this.channel?.readyState !== 'open') throw new Error('Mynah is disconnected.');
    this.channel.send(JSON.stringify({command:'start', id, parentId}));
  }

  control(command: 'start' | 'stop' | 'cancel') {
    if (this.channel?.readyState !== 'open') throw new Error('Mynah is disconnected. Connect again.');
    this.channel.send(command);
  }

  audio(pcm: Uint8Array) {
    const channel = this.channel;
    if (channel?.readyState !== 'open') throw new Error('Mynah is disconnected.');
    if (channel.bufferedAmount > 256000) throw new Error('Connection too slow. Try again when the network improves.');
    if (pcm.byteLength % 2) throw new Error('The microphone returned incomplete audio.');
    for (let offset = 0; offset < pcm.byteLength; offset += 8192) channel.send(pcm.slice(offset, offset + 8192));
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.readyTimer);
    this.abort.abort();
    this.channel?.close();
    this.peer?.close();
    this.ended();
  }
}
