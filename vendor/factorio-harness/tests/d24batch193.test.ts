import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d24 batch193 QAI1 (viewer Aurora 20:58): a far vehicle refusal names the remote form.

test('Lua contract: tests/d24_batch193.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d24_batch193.lua'],{stdio:'pipe'});
});
