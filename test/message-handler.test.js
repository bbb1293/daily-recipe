const test = require('node:test');
const assert = require('node:assert/strict');
const { createMessageHandler, splitMessage } = require('../bot/message-handler');

function message(content = '<@123> cook pork and cabbage') {
  const replies = [];
  const edits = [];
  const sends = [];
  return {
    guildId: 'guild', author: { id: 'user', bot: false }, content,
    replies, edits, sends,
    reply: async (payload) => { replies.push(payload); return { edit: async (edit) => edits.push(edit) }; },
    channel: { send: async (payload) => sends.push(payload) },
  };
}

test('only process human bot mentions in the configured guild', async () => {
  let calls = 0;
  const handler = createMessageHandler({ botId: '123', guildId: 'guild', processRequest: async () => { calls += 1; return 'recipe'; } });
  for (const item of [message('cook pork'), { ...message(), guildId: 'other' }, { ...message(), guildId: null },
    { ...message(), author: { id: 'bot', bot: true } }, { ...message(), webhookId: 'webhook' }, message('<@999> cook pork')]) {
    assert.equal(await handler(item), false);
    assert.equal(item.replies.length, 0);
  }
  assert.equal(calls, 0);
});

test('accept nickname mentions and reply without triggering mentions', async () => {
  let request;
  const item = message('<@!123> cook pork and cabbage');
  const handler = createMessageHandler({ botId: '123', guildId: 'guild', processRequest: async (text) => { request = text; return '@everyone recipe'; } });
  assert.equal(await handler(item), true);
  assert.equal(request, 'cook pork and cabbage');
  assert.equal(item.edits[0].content, '@everyone recipe');
  assert.deepEqual(item.edits[0].allowedMentions, { parse: [], repliedUser: false });
});

test('empty mentions explain how to ask without using Codex', async () => {
  const item = message('<@123>');
  const handler = createMessageHandler({ botId: '123', guildId: 'guild', processRequest: () => { throw new Error('should not run'); } });
  await handler(item);
  assert.match(item.replies[0].content, /cook pork and cabbage/);
});

test('optional user allowlist is enforced', async () => {
  const item = message();
  const handler = createMessageHandler({ botId: '123', guildId: 'guild', allowedUserIds: ['owner'], processRequest: () => { throw new Error('should not run'); } });
  assert.equal(await handler(item), false);
});

test('long replies preserve all output and stay within Discord limits', async () => {
  const output = '# Recipe\n' + 'a'.repeat(5000) + '\n' + '🥬'.repeat(1000);
  const parts = splitMessage(output);
  assert.equal(parts.join(''), output);
  assert.ok(parts.every((part) => part.length <= 1900));
  const item = message();
  const handler = createMessageHandler({ botId: '123', guildId: 'guild', processRequest: async () => output });
  await handler(item);
  assert.equal([item.edits[0].content, ...item.sends.map((sent) => sent.content)].join(''), output);
  assert.ok(item.sends.every((sent) => sent.allowedMentions.parse.length === 0));
});

test('overlapping requests report busy and recover after completion', async () => {
  let finish;
  let calls = 0;
  const handler = createMessageHandler({ botId: '123', guildId: 'guild', processRequest: () => { calls += 1; return new Promise((resolve) => { finish = resolve; }); } });
  const first = handler(message());
  await new Promise((resolve) => setImmediate(resolve));
  const second = message();
  await handler(second);
  assert.match(second.replies[0].content, /processing another/);
  assert.equal(calls, 1);
  finish('recipe');
  await first;
  const third = handler(message());
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls, 2);
  finish('recipe');
  await third;
});

test('failed multi-action requests show completed actions and allow retry', async () => {
  let calls = 0;
  const item = message();
  const handler = createMessageHandler({ botId: '123', guildId: 'guild', logger: { error() {} }, processRequest: async () => {
    calls += 1;
    if (calls === 1) throw Object.assign(new Error('fixture failure'), { completedOutput: 'Added pork' });
    return 'recipe';
  } });
  await handler(item);
  assert.match(item.edits[0].content, /Added pork/);
  assert.match(item.edits[0].content, /couldn’t complete/);
  const retry = message();
  await handler(retry);
  assert.equal(retry.edits[0].content, 'recipe');
});
