import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d22 batch90 Lua contract.
test('Lua contract: tests/d22_batch90.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d22_batch90.lua'], { stdio: 'pipe' });
});
