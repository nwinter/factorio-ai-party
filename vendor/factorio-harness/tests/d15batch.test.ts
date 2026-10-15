import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d15 batch's Lua contract (its own file: tests/lua.test.ts is one line that parallel branches all edit).
test('Lua contract: tests/d15_batch.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d15_batch.lua'],{stdio:'pipe'});
});
