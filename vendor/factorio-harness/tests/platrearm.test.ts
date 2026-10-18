import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/platrearm.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/platrearm.lua'], { stdio: 'pipe' });
});
