import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 alerts Lua contract.
test('Lua contract: tests/d17_alerts.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_alerts.lua'], { stdio: 'pipe' });
});
