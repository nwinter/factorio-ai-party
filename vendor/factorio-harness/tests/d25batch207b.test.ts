import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch207b: QT3 a queued build with clear_obstacles waits for its run again.

test('Lua contract: tests/d25_batch207b.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch207b.lua'],{stdio:'pipe'});
});
