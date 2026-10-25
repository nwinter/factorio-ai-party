import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch205: QR1 pod_landed since_tick and quality from the pod ledger, its start kept across hold and requeue.

test('Lua contract: tests/d25_batch205.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch205.lua'],{stdio:'pipe'});
});
