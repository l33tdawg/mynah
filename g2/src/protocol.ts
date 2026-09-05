export const protocol = 'mynah.g2.v1';
export const relayOrigin = 'https://call.sage.delivery';

export function connectionURL(input: string): URL {
  const url = new URL(input.trim());
  if (url.origin !== relayOrigin || url.username || url.password || url.search || url.hash || !/^\/[a-f0-9]{32}\/?$/.test(url.pathname)) {
    throw new Error('Paste the connection link Mynah sent in your chat.');
  }
  url.pathname = url.pathname.replace(/\/$/, '');
  return url;
}

// Conservative pages keep each SDK update small. Native scrolling is not
// programmatically controllable, so each swipe selects an explicit page.
export function pages(text: string): string[] {
  const plain = text.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/[*`#]/g, '').trim();
  const chars = Array.from(plain);
  const result: string[] = [];
  while (chars.length) {
    let end = Math.min(220, chars.length);
    if (end < chars.length) {
      const boundary = chars.slice(0, end).lastIndexOf(' ');
      if (boundary > 140) end = boundary;
    }
    result.push(chars.splice(0, end).join('').trim());
    while (chars[0] === ' ') chars.shift();
  }
  return result.length ? result : ['Tap to talk.'];
}

export type ReplyEvent = { type: 'ready' | 'thinking' | 'heard' | 'reply' | 'error' | 'done' | 'state'; text: string };
export function replyEvent(raw: string): ReplyEvent {
  const value = JSON.parse(raw);
  if (!value || !['ready','thinking','heard','reply','error','done','state'].includes(value.type) || typeof value.text !== 'string') {
    throw new Error('Mynah sent an unsupported response. Update the companion and Mynah.');
  }
  return value;
}
