import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d15 batch5 Lua contract (its own file, as batch4).

test('Lua contract: tests/d15_batch5.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d15_batch5.lua'],{stdio:'pipe'});
});

test('Lua contract: tests/d15_batch5_g3.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d15_batch5_g3.lua'],{stdio:'pipe'});
});
