import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch215: QZ3 watch ids name their owner; uptime read takes agent; an ambiguous id is refused.

test('Lua contract: tests/d25_batch215.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch215.lua'],{stdio:'pipe'});
});
