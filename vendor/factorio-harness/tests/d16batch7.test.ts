import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d16 batch7 Lua contract (its own files, as batch6).

for (const file of ['tests/d16_batch7.lua', 'tests/d16_batch7_rt.lua']) {
  test(`Lua contract: ${file}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua', [file], { stdio: 'pipe' });
  });
}
