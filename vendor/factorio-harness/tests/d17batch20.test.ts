import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 batch20 Lua contracts.
test('Lua contract: tests/d17_batch20.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch20.lua'], { stdio: 'pipe' });
});
