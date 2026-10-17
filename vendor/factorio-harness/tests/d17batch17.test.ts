import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 batch17 Lua contract (its own files, as batch16).

for (const file of ['tests/d17_batch17.lua', 'tests/d17_batch17_rt.lua']) {
  test(`Lua contract: ${file}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua', [file], { stdio: 'pipe' });
  });
}
