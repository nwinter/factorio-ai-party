import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch214: QZ2 the limits dry_run missed (uptime items and the sweep).

test('Lua contract: tests/d25_batch214b.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch214b.lua'],{stdio:'pipe'});
});
