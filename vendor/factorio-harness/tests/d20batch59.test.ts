import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d20 batch59 Lua contract: the character's switches and slot filters, the team blueprint library.

for (const file of ['tests/d20_batch59.lua']) {
  test(`Lua contract: ${file}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua', [file], { stdio: 'pipe' });
  });
}
