import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { hasUnfocusedNiriRule, shellQuote, startSession, stopSession, validateSessionName } from '../host/session.js';
const exec = promisify(execFile);

test('session names cannot escape the owned directory', () => {
  for (const name of ['../game', '.', '', '/tmp/game', 'a/b', 'A', 'a'.repeat(49), 'x\n']) {
    assert.throws(() => validateSessionName(name));
  }
  assert.equal(validateSessionName('test-world_2'), 'test-world_2');
});
test('graphical launch guard requires an active narrowly scoped unfocused rule', () => {
  const rule = 'window-rule { match app-id="niri" title="^niri$"\n open-focused false\n}';
  assert(hasUnfocusedNiriRule(rule));
  assert(!hasUnfocusedNiriRule('// '+rule.replaceAll('\n', '\n// ')));
  assert(!hasUnfocusedNiriRule('/* '+rule+' */'));
  assert(!hasUnfocusedNiriRule('/-'+rule));
  assert(!hasUnfocusedNiriRule(rule.replace('match ', '/-match ')));
  assert(!hasUnfocusedNiriRule(rule.replace('open-focused', '/-open-focused')));
  assert(!hasUnfocusedNiriRule(rule+'\nwindow-rule { open-focused true }'));
  assert(!hasUnfocusedNiriRule(rule.replace('false','true')));
  assert(!hasUnfocusedNiriRule(rule.replace('app-id="niri"','app-id="other"')));
  assert(!hasUnfocusedNiriRule(rule.replace('open-focused false','exclude app-id="niri"\nopen-focused false')));
});
test('nested shell command quoting preserves arguments without executing substitutions', async () => {
  const values = ['path with spaces', "path'with'quotes", '$(printf compromised)', '`printf bad`', 'semi;colon', 'new\nline', ''];
  const {stdout} = await exec('/bin/sh', ['-c', 'printf "%s\\0" '+values.map(shellQuote).join(' ')]);
  assert.deepEqual(stdout.split('\0').slice(0,-1), values);
});
test('invalid session operations reject before touching processes or paths', async () => {
  await assert.rejects(startSession({name:'../escape'}), /slug/);
  await assert.rejects(stopSession('../escape'), /slug/);
});
test('conflicting launch modes reject before looking for Factorio', async () => {
  await assert.rejects(startSession({name:'conflict', headless:true, niri:true}), /--niri/);
  await assert.rejects(startSession({name:'conflict', headless:true, bridge:true}), /--bridge/);
});
