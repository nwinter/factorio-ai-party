import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// fuel_budget's reactors one by one (d20 batch63 Y1), apart from lua.test.ts's shared list.
test('Lua contract: tests/fuelreactor.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/fuelreactor.lua'],{stdio:'pipe'});
});
