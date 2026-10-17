import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 batch18 Lua contract.
test('Lua contract: tests/d17_batch18.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch18.lua'], { stdio: 'pipe' });
});
