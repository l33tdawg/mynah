export const protocol = 'mynah.g2.v1';
export const relayOrigin = 'https://call.sage.delivery';

export function connectionURL(input: string): URL {
  let url: URL;
  const hint = 'Copy the private pairing link from Mynah Settings → General → Your phone → Pair G2.';
  try { url = new URL(input.trim()); } catch { throw new Error(hint); }
  if (url.origin !== relayOrigin || url.username || url.password || url.search || url.hash || !/^\/[a-f0-9]{32}\/?$/.test(url.pathname)) {
    throw new Error(hint);
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

// Explicit lines avoid relying on native scrolling inside the narrow home card.
export function cardPages(text: string): string[] {
  const plain = text.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/[*`#]/g, '').trim();
  const lines: string[] = [];
  for (const paragraph of plain.split('\n')) {
    const chars = Array.from(paragraph);
    if (!chars.length) lines.push('');
    while (chars.length) {
      let end = 0, width = 0;
      while (end < chars.length) {
        const size = chars[end].codePointAt(0)! > 0x2e7f ? 2 : 1;
        if (width + size > 26) break;
        width += size; end++;
      }
      if (end < chars.length) {
        const boundary = chars.slice(0, end).lastIndexOf(' ');
        if (boundary > 0) end = boundary + 1;
      }
      lines.push(chars.splice(0, end).join(''));
    }
  }
  const result: string[] = [];
  for (let i = 0; i < lines.length; i += 6) result.push(lines.slice(i, i + 6).join('\n'));
  return result.length ? result : ['Tap to talk.'];
}
