import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 batch21 Lua contracts.
test('Lua contract: tests/d17_batch21.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch21.lua'], { stdio: 'pipe' });
});
