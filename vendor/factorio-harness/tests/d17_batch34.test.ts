import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { walkLine } from '../host/format.js';
test('Lua contract: tests/d17_batch34.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch34.lua'], { stdio: 'pipe' });
});
// C3 (Haiku): a move_to --wait reply says first whether the walk arrived; exit 3 says the walk goes on and why.
test('walkLine: arrived, not arrived, and a wait a tell ended (exit 3)', () => {
  assert.equal(walkLine('move_to', {ok:true, result:{last:{outcome:'arrived', position:{x:12.5, y:-40}}}}, 0), 'walk: arrived at (12.5,-40)');
  assert.equal(walkLine('move_to', {ok:true, result:{completion:{outcome:'arrived_near'}}}, 0), 'walk: arrived (arrived_near)');
  assert.equal(walkLine('move_to', {ok:false, error:{code:'action_interrupted'}, result:{last:{outcome:'unreachable'}}}, 1), 'walk: not arrived: unreachable');
  assert.equal(walkLine('move_to', {ok:true, result:{outcome:'told', from:'sol', still_running:'move_to, up to 40 s more'}}, 3),
    'walk: not arrived: move_to goes on, up to 40 s more; a tell from sol ended the wait (exit 3: fh wait waits for it again; --wait-through-tells: a tell or mention does not end the wait)');
  assert.equal(walkLine('move_to', {ok:false, error:{code:'wait_timeout'}, result:{timed_out:true, still_running:{kind:'move_to'}}}, 3),
    'walk: not arrived: move_to goes on; the wait timed out (exit 3: fh wait waits for it again; --wait-through-tells: a tell or mention does not end the wait)');
  assert.equal(walkLine('transfer', {ok:true, result:{}}, 0), undefined);
});
