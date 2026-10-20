import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d20 batch56 Lua contract: inspect's empty area in sight or not, screenshot by remote view.

for (const file of ['tests/d20_batch56_rt.lua']) {
  test(`Lua contract: ${file}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua', [file], { stdio: 'pipe' });
  });
}
