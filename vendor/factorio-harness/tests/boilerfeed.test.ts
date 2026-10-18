import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/boilerfeed.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/boilerfeed.lua'], { stdio: 'pipe' });
});
