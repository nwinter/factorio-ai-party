import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// rail_route ground and level elevated (d20 batch61 W1/W2), apart from lua.test.ts's shared list.
for (const path of ['tests/rails.lua','tests/elevated.lua']) {
  test(`Lua contract: ${path}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua',[path],{stdio:'pipe'});
  });
}
