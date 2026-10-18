import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/reqrate.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/reqrate.lua'], { stdio: 'pipe' });
});
