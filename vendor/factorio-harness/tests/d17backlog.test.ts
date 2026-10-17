import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 backlog Lua contract.
test('Lua contract: tests/d17_backlog.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_backlog.lua'], { stdio: 'pipe' });
});
