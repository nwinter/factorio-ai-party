import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch208: QU2 configure settings on build and place_ghosts entries checked as configure checks them; storage_filter with bar.

test('Lua contract: tests/d25_batch208b.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch208b.lua'],{stdio:'pipe'});
});
