import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/d18_batch37.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d18_batch37.lua'], { stdio: 'pipe' });
});
