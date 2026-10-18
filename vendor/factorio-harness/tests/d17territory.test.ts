import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d17 territory: demolisher territories, cleared or not, and drills stopped by a full chest.
test('Lua contract: tests/d17_territory.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_territory.lua'], { stdio: 'pipe' });
});
