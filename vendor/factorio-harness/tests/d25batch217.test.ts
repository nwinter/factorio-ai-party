import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch217: QAB1 reservations {position}: one chest's or pad's robots past the first 1024; sweep across ticks.

test('Lua contract: tests/d25_batch217.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch217.lua'],{stdio:'pipe'});
});
