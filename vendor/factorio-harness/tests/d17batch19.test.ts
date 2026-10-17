import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 batch19 Lua contracts: the runtime through dispatch.
test('Lua contract: tests/d17_batch19_rt.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch19_rt.lua'], { stdio: 'pipe' });
});
