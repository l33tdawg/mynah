// A message WhatsApp wrapped is still a message.
//
// `getMessageContent` unwrapped one level and knew five wrappers. Anything it
// missed matched none of `extractBridgeEvent`'s branches, so `body` stayed empty
// and `hasMedia` stayed false — the bridge treated it as an empty message and it
// never reached the spool at all. The owner sends a view-once photo, or edits
// something he already sent, and Mynah simply does not answer, with nothing in
// the log to say a message arrived.
//
// Found by an audit against Baileys' own `normalizeMessageContent`, which loops
// five levels and covers nine wrappers.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { getMessageContent, tokensMatch } from './bridge_helpers.js';

const text = (body) => ({ conversation: body });

test('a plain message is returned as it is', () => {
  assert.deepEqual(getMessageContent({ message: text('what time is the ferry') }), text('what time is the ferry'));
});

test('a message with nothing in it is an object, not undefined', () => {
  // Callers read properties off the result unguarded. Returning undefined here
  // turns a malformed message into a TypeError inside the socket's event
  // handler, which is the whole process.
  assert.deepEqual(getMessageContent({}), {});
  assert.deepEqual(getMessageContent(null), {});
  assert.deepEqual(getMessageContent({ message: null }), {});
});

test('the five wrappers that were already handled still are', () => {
  for (const wrapper of [
    'ephemeralMessage',
    'viewOnceMessage',
    'viewOnceMessageV2',
    'documentWithCaptionMessage',
  ]) {
    assert.deepEqual(
      getMessageContent({ message: { [wrapper]: { message: text('hello') } } }),
      text('hello'),
      `${wrapper} stopped being unwrapped`
    );
  }
});

test('a view-once photo sent the way WhatsApp sends them now is not dropped', () => {
  // viewOnceMessageV2Extension is what current WhatsApp uses, and it was in
  // Baileys' list and not in ours.
  assert.deepEqual(
    getMessageContent({ message: { viewOnceMessageV2Extension: { message: text('look at this') } } }),
    text('look at this')
  );
});

test('an edited message is read, rather than arriving as an empty one', () => {
  assert.deepEqual(
    getMessageContent({ message: { editedMessage: { message: text('actually make it Bangkok') } } }),
    text('actually make it Bangkok')
  );
});

test('wrappers inside wrappers are unwrapped all the way down', () => {
  // The common real shape: a disappearing-messages chat carrying a view-once
  // photo. One pass through the outer wrapper leaves the inner one in place, and
  // the result matches none of the content branches — so the message vanishes.
  assert.deepEqual(
    getMessageContent({
      message: {
        ephemeralMessage: {
          message: { viewOnceMessageV2: { message: text('the ferry ticket') } },
        },
      },
    }),
    text('the ferry ticket')
  );
});

test('a message that wraps itself does not spin the event handler for ever', () => {
  // A malformed or hostile message could nest indefinitely. The loop is bounded
  // at Baileys' own depth; what matters is that it terminates and returns
  // something, not what it returns.
  const deep = { message: {} };
  let node = deep.message;
  for (let i = 0; i < 40; i += 1) {
    const inner = {};
    node.ephemeralMessage = { message: inner };
    node = inner;
  }
  const result = getMessageContent(deep);
  assert.equal(typeof result, 'object');
});

test('the terminal shapes are returned rather than unwrapped', () => {
  // templateMessage, buttonsMessage and listMessage are not wrappers — the
  // bridge reads fields off them. Upstream's normaliser does not return these,
  // which is why this stays a local function.
  const buttons = { buttonsMessage: { contentText: 'pick one' } };
  assert.deepEqual(getMessageContent({ message: buttons }), buttons.buttonsMessage);

  const list = { listMessage: { description: 'choose' } };
  assert.deepEqual(getMessageContent({ message: list }), list.listMessage);

  const template = { templateMessage: { hydratedTemplate: { hydratedContentText: 'hi' } } };
  assert.deepEqual(getMessageContent({ message: template }), template.templateMessage.hydratedTemplate);
});

test('a terminal shape inside a wrapper is still found', () => {
  assert.deepEqual(
    getMessageContent({
      message: { ephemeralMessage: { message: { listMessage: { description: 'choose' } } } },
    }),
    { description: 'choose' }
  );
});

// --- the shared secret in front of the bridge's HTTP API ---

test('the right token matches and a wrong one does not', () => {
  const token = 'a'.repeat(64);
  assert.equal(tokensMatch(token, token), true);
  assert.equal(tokensMatch('b'.repeat(64), token), false);
  assert.equal(tokensMatch('', token), false);
  assert.equal(tokensMatch(undefined, token), false);
});

test('a non-ASCII token is refused rather than throwing a 500 with a stack trace', () => {
  // `timingSafeEqual` throws unless the buffers are the same size, and a
  // JavaScript string length counts UTF-16 code units — so a token of the right
  // CHARACTER count containing anything outside ASCII produced buffers of
  // different byte lengths. The throw escaped express's middleware and an
  // unauthenticated caller got a 500 describing the bridge's internals instead
  // of a 401.
  const token = 'a'.repeat(64);
  const sameCharacterCount = 'é'.repeat(64);
  assert.equal(sameCharacterCount.length, token.length, 'the test case no longer reproduces the mismatch');
  assert.notEqual(Buffer.byteLength(sameCharacterCount), Buffer.byteLength(token));
  assert.doesNotThrow(() => tokensMatch(sameCharacterCount, token));
  assert.equal(tokensMatch(sameCharacterCount, token), false);
});

test('an empty expected token refuses everything rather than accepting everything', () => {
  // A bridge that somehow failed to mint a token must fail closed. Two empty
  // buffers compare equal, so without this every caller would be authorised.
  assert.equal(tokensMatch('', ''), false);
  assert.equal(tokensMatch('anything', ''), false);
});
