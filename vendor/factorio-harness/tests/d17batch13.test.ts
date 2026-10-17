import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 batch13 Lua contract.
test('Lua contract: tests/d17_batch13.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch13.lua'], { stdio: 'pipe' });
});
