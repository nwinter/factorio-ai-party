import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d16 batch8 Lua contract (its own file, as batch7).

for (const file of ['tests/d16_batch8.lua']) {
  test(`Lua contract: ${file}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua', [file], { stdio: 'pipe' });
  });
}
