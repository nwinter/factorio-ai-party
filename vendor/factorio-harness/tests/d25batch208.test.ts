import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch208: QU1 a queue step's text and list lengths checked at submit and in dry_run, from the actions' constants.

test('Lua contract: tests/d25_batch208.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch208.lua'],{stdio:'pipe'});
});
