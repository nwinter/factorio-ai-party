import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d16 batch6 Lua contract (its own file, as batch5).

test('Lua contract: tests/d16_batch6.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d16_batch6.lua'],{stdio:'pipe'});
});
