import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/focusdone.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/focusdone.lua'], { stdio: 'pipe' });
});
