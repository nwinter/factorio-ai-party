import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/bomwatch.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/bomwatch.lua'], { stdio: 'pipe' });
});
