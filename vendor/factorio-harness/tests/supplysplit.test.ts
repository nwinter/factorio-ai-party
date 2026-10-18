import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/supplysplit.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/supplysplit.lua'], { stdio: 'pipe' });
});
