import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d20 batch67 Lua contract: board_review and claims read whole platform and planet names, longest first.

for (const file of ['tests/d20_batch67.lua']) {
  test(`Lua contract: ${file}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua', [file], { stdio: 'pipe' });
  });
}
