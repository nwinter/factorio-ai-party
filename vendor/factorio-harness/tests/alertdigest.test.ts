import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/alertdigest.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/alertdigest.lua'], { stdio: 'pipe' });
});
