const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createNaturalLanguageProcessor, validatePlan, commandFor } = require('../bot/natural-language');

const action = (kind, fields = {}) => ({ kind, list: 'none', items: [], date: '', force: false, urgent: false, ...fields });
const plan = (...actions) => ({ actions, reply: '' });

function fixture(result, failKind, outputs = {}) {
  const calls = [];
  const run = async (file, args, options) => {
    calls.push({ file, args, options });
    if (file === 'codex') {
      await fs.writeFile(args[args.indexOf('--output-last-message') + 1], JSON.stringify(result));
      return 'progress is ignored';
    }
    if (args[0] === 'list') return '== ingredients ==\n(frozen) pork\ncabbage\n== pantry ==\nsalt\n';
    if (args[0] === failKind) throw new Error('fixture execution failure');
    if (Object.hasOwn(outputs, args[0])) return outputs[args[0]];
    return path.basename(file) === 'kitchen.sh' ? 'Added frozen pork\n' : '# Pork and cabbage\nRecipe body.\n';
  };
  const processor = createNaturalLanguageProcessor({ projectDir: '/fixture', env: { PATH: '/bin' }, run, now: () => new Date(2026, 9, 1) });
  return { calls, ...processor };
}

test('Codex interprets with a schema, kitchen context, and Luna; temporary files are removed', async () => {
  const f = fixture(plan(action('cook', { items: ['(frozen) pork', 'cabbage'] })));
  const parsed = await f.interpret('cook frozen pork and cabbage');
  assert.equal(parsed.actions[0].items[0], '(frozen) pork');
  const call = f.calls[1];
  assert.equal(call.args[call.args.indexOf('--model') + 1], 'gpt-5.6-luna');
  assert.ok(call.args.includes('--output-schema'));
  assert.ok(call.args.includes('read-only'));
  assert.ok(call.args.includes('shell_tool'));
  assert.ok(call.options.input.includes('(frozen) pork'));
  assert.ok(call.options.input.includes('2026-10-01'));
  assert.equal(call.options.timeout, 120000);
  assert.notEqual(call.options.cwd, '/fixture');
  await assert.rejects(fs.access(call.options.cwd), { code: 'ENOENT' });
});

test('execute requested inventory changes before cooking, using argument arrays', async () => {
  const f = fixture(plan(action('add', { list: 'ingredients', items: ['pork'] }), action('cook', { items: ['pork', 'cabbage'] })));
  const result = await f.processRequest('add pork and cook it with cabbage');
  assert.deepEqual(f.calls.slice(2).map(({ args }) => args), [['add', 'ingredients', 'pork'], ['--print', '--use', 'pork', '--use', 'cabbage']]);
  assert.match(result, /Added frozen pork/);
  assert.match(result, /Pork and cabbage/);
});

test('unsupported requests return clarification without executing actions', async () => {
  const f = fixture({ actions: [], reply: 'Which ingredients should I cook with?' });
  assert.equal(await f.processRequest('do something'), 'Which ingredients should I cook with?');
  assert.equal(f.calls.length, 2); // Kitchen snapshot and Codex interpretation only.
});

test('validate the entire plan before any mutation', async () => {
  const f = fixture(plan(action('add', { list: 'ingredients', items: ['pork'] }), action('exec', { items: ['rm -rf /'] })));
  await assert.rejects(f.processRequest('malicious request'), /Invalid action/);
  assert.equal(f.calls.length, 2);
  await assert.rejects(fs.access(f.calls[1].options.cwd), { code: 'ENOENT' });
});

test('script failures preserve completed output for the reply', async () => {
  const f = fixture(plan(action('add', { list: 'ingredients', items: ['pork'] }), action('cook', { items: ['pork'] })), '--print');
  await assert.rejects(f.processRequest('add pork and cook'), (error) => {
    assert.equal(error.completedOutput, 'Added frozen pork');
    return true;
  });
});

test('ambiguous inventory matches stop later actions', async () => {
  const f = fixture(plan(action('remove', { list: 'ingredients', items: ['tuna'] }), action('cook', { items: ['pork'] })), undefined, {
    remove: 'Multiple matches in ingredients for: tuna\n- tuna\n- spicy tuna\n',
  });
  assert.match(await f.processRequest('remove tuna then cook pork'), /Multiple matches/);
  assert.equal(f.calls.length, 3);
  assert.equal(f.calls[2].args[0], 'remove');
});

test('map daily dates, pantry, and urgency onto the existing CLI', () => {
  assert.deepEqual(commandFor(action('daily', { date: 'today', force: true }), '/fixture')[1], ['--print', '--today', '--force']);
  assert.deepEqual(commandFor(action('daily', { date: 'tomorrow' }), '/fixture')[1], ['--print']);
  assert.deepEqual(commandFor(action('daily', { date: '2026-10-08' }), '/fixture')[1], ['--print', '--date', '2026-10-08']);
  assert.deepEqual(commandFor(action('list', { list: 'both' }), '/fixture')[1], ['list']);
  assert.deepEqual(commandFor(action('list', { list: 'pantry' }), '/fixture')[1], ['list', 'pantry']);
  assert.deepEqual(commandFor(action('add', { list: 'ingredients', items: ['spinach'], urgent: true }), '/fixture')[1], ['add', 'ingredients', 'spinach', '--urgent']);
  assert.deepEqual(commandFor(action('unurgent', { items: ['spinach'] }), '/fixture')[1], ['unurgent', 'spinach']);
});

test('reject options, control characters, invalid dates, and unexpected model fields', () => {
  for (const invalid of [
    action('cook', { items: ['--notify'] }), action('cook', { items: ['pork\n--force'] }),
    action('cook', { items: [] }), action('daily', { date: '../../config.sh' }),
    action('daily', { date: '2026-02-30' }), action('add', { list: 'pantry', items: ['salt'], urgent: true }),
    action('remove', { list: 'both', items: ['salt'] }), action('cook', { items: ['pork'], force: true }),
    { ...action('cook', { items: ['pork'] }), command: 'rm -rf /' },
  ]) assert.throws(() => validatePlan(plan(invalid)));
  assert.throws(() => validatePlan(plan(...Array(6).fill(action('list', { list: 'both' })))));
  assert.throws(() => validatePlan({ actions: [], reply: '' }));
});

test('shell-looking ingredient names stay literal arguments', () => {
  const name = 'pork; $(touch /tmp/unwanted)';
  const parsed = validatePlan(plan(action('cook', { items: [name] })));
  assert.deepEqual(commandFor(parsed.actions[0], '/fixture')[1], ['--print', '--use', name]);
});

test('failed interpretation cleans up and runs no actions', async () => {
  let workDir;
  const processor = createNaturalLanguageProcessor({ run: async (file, args, options) => {
    if (file !== 'codex') return 'kitchen snapshot';
    workDir = options.cwd;
    throw new Error('model unavailable');
  } });
  await assert.rejects(processor.processRequest('cook pork'), /model unavailable/);
  await assert.rejects(fs.access(workDir), { code: 'ENOENT' });
});
