import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/beltsample.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/beltsample.lua'], { stdio: 'pipe' });
});
