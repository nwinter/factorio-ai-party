import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/wagonslots.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/wagonslots.lua'], { stdio: 'pipe' });
});
