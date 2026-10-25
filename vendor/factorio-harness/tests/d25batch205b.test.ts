import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch205: QR2 flight_watch {platform, read: true}.

test('Lua contract: tests/d25_batch205b.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch205b.lua'],{stdio:'pipe'});
});
