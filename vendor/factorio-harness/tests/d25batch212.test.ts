import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch212: QX1 flight_watch ammunition used per window, mixed part and replacement chain, with its boundaries.

test('Lua contract: tests/d25_batch212.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch212.lua'],{stdio:'pipe'});
});
