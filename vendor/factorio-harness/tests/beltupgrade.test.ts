import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/beltupgrade.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/beltupgrade.lua'], { stdio: 'pipe' });
});
