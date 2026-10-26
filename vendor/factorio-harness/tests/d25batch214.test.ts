import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch214: QZ1 uptime {read: true} in pages of structured rows; QZ2 dry_run counts.

test('Lua contract: tests/d25_batch214.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch214.lua'],{stdio:'pipe'});
});
