import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inputType } from '../src/input.ts';

test('routes text, list and system gestures, including zero-valued taps', () => {
  for (const field of ['textEvent', 'listEvent', 'sysEvent']) {
    for (const eventType of [0,1,2,3]) assert.equal(inputType({[field]: {eventType}}), eventType);
  }
  assert.equal(inputType({textEvent:{}}), 0);
  for (const eventSource of [1,2,3]) assert.equal(inputType({sysEvent:{eventSource}}), 0);
});
test('audio-only and empty system events never start recording; lifecycle stays distinct', () => {
  assert.equal(inputType({}), undefined);
  assert.equal(inputType({sysEvent:{}}), undefined);
  assert.equal(inputType({sysEvent:{eventType:5,eventSource:2}}), 5);
  assert.equal(inputType({textEvent:{eventType:0},sysEvent:{eventType:0}}), 0);
});


test('explicit system double tap and lifecycle events beat empty tap envelopes', () => {
  assert.equal(inputType({textEvent:{},sysEvent:{eventType:3,eventSource:1}}), 3);
  assert.equal(inputType({textEvent:{eventType:0},sysEvent:{eventType:5}}), 5);
  assert.equal(inputType({sysEvent:{eventSource:1},textEvent:{eventType:2}}), 2);
});
