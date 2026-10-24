import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d23 batch131 CN1 (Astra #2088): a platform turned back mid-connection.

test('Lua contract: tests/d23_batch131.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d23_batch131.lua'],{stdio:'pipe'});
});
