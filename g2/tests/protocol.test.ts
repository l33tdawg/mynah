import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connectionURL, pages, replyEvent } from '../src/protocol.ts';

test('only the configured relay capability is accepted', () => {
  const link = 'https://call.sage.delivery/' + 'a'.repeat(32);
  assert.equal(connectionURL(link).toString(), link);
  for (const invalid of [link+'?token=other',link+'#x',link.replace('https:','http:'),link.replace('call.sage.delivery','evil.example'), 'https://user:pass@call.sage.delivery/'+ 'a'.repeat(32)]) {
    assert.throws(() => connectionURL(invalid));
  }
});
test('long answers preserve Unicode and every word across pages', () => {
  const text = Array.from({length: 300}, (_, i) => `word${i}界`).join(' ');
  const result = pages(text);
  assert.equal(result.join(' '), text);
  assert.ok(result.every(page => Array.from(page).length <= 220));
  assert.ok(pages('界'.repeat(501)).every(page => page.length <= 220));
});
test('unsupported or malformed server messages are rejected', () => {
  assert.deepEqual(replyEvent('{"type":"reply","text":"hello"}'), {type:'reply',text:'hello'});
  assert.throws(() => replyEvent('{"type":"execute","text":"x"}'));
  assert.throws(() => replyEvent('{"type":"reply","text":null}'));
});
