import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 batch16 Lua contract (its own files, as batch7).

for (const file of ['tests/d17_batch16.lua', 'tests/d17_batch16_rt.lua']) {
  test(`Lua contract: ${file}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua', [file], { stdio: 'pipe' });
  });
}
