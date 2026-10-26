import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch216: QAA1 flight_watch foundation destroyed and rebuilt per window and mixed part; the platform read's foundation_lost.

test('Lua contract: tests/d25_batch216.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch216.lua'],{stdio:'pipe'});
});
