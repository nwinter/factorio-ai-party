import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch219: QAD1 a split keeps the closed uptime watch whole as a segment, read by its id or segment_start.

test('Lua contract: tests/d25_batch219.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch219.lua'],{stdio:'pipe'});
});
