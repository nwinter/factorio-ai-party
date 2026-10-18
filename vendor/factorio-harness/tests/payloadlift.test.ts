import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('Lua contract: tests/payloadlift.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/payloadlift.lua'], { stdio: 'pipe' });
});
