import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/platdigest.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/platdigest.lua'], { stdio: 'pipe' });
});
