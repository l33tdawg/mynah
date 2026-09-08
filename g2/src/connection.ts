import { connectionURL, protocol, replyEvent, type ReplyEvent } from './protocol.ts';

export class MynahConnection {
  private peer?: RTCPeerConnection;
  private channel?: RTCDataChannel;
  private abort = new AbortController();
  private closed = false;
  private readyTimer?: ReturnType<typeof setTimeout>;
  constructor(private event: (event: ReplyEvent) => void, private ended: () => void) {}

  async connect(input: string) {
    const url = connectionURL(input);
    const signal = AbortSignal.any([this.abort.signal, AbortSignal.timeout(30000)]);
    const config = await fetch(`${url}/connect`, { signal, credentials: 'omit', referrerPolicy: 'no-referrer' });
    if (!config.ok) throw new Error('Mynah is offline or the pairing was revoked. Reconnecting automatically.');
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
    if (!response.ok) throw new Error('Mynah is temporarily unavailable. Reconnecting automatically.');
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
