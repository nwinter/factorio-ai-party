import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/d17_batch33.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch33.lua'], { stdio: 'pipe' });
});
