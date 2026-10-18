import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/platsupport.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/platsupport.lua'], { stdio: 'pipe' });
});
