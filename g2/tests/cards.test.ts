import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Cards} from '../src/cards.ts';
import {clockPixels,batteryLabel,weatherLabel} from '../src/home.ts';
const card = (id: string, status = 'queued') => ({id,threadId:id,question:id,answer:status==='ready'?'answer':'',status});
test('completion waits for recording and opens the right answer afterward', () => {
  const c = new Cards(); c.add('one'); c.add('two');
  c.merge([card('one','ready'),card('two')],true);
  assert.equal(c.detail,false); assert.equal(c.pending,1);
  c.reveal(); assert.equal(c.current?.id,'one'); assert.equal(c.detail,true);
  c.merge([card('one','ready'),card('two','ready')],false);
  assert.equal(c.current?.id,'one'); assert.equal(c.items[1].unread,true);
});
test('a status refresh does not reopen a read answer or interrupt browsing', () => {
  const c = new Cards(); c.merge([card('one','ready')],false); c.home();
  c.merge([card('one','ready')],false); assert.equal(c.detail,false);
  c.select(1); c.merge([card('one','ready'),card('two','ready')],false);
  assert.equal(c.current?.id,'one'); assert.equal(c.detail,false);
});
test('clock bitmap is bounded and unknown battery is never a fake reading', () => {
  const data = clockPixels(new Date(2026,8,8,7,52));
  assert.equal(data.length,156*144/2); assert.ok(data.some(n=>n!==0)); assert.ok(data.every(n=>n>=0&&n<=255));
  assert.equal(batteryLabel(undefined),'[--]'); assert.ok(batteryLabel(75).includes('75%'));
  assert.equal(weatherLabel(0,21.2),'21°C\n☀ Clear');
});


test('saved answers do not steal Home on first snapshot, but new completions are revealed', () => {
  const c = new Cards(); c.merge([card('old','ready'),card('pending')],false);
  assert.equal(c.detail, false); assert.equal(c.selected, -1);
  c.merge([card('old','ready'),card('pending','ready')],false);
  assert.equal(c.detail, true); assert.equal(c.current?.id, 'pending');
});
