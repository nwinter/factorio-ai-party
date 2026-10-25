import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch201: QN1 uptime on rocket silos, QN2 output_stop and trace on an output that refuses ingredients, QN3 supply's residual.

test('Lua contract: tests/d25_batch201.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch201.lua'],{stdio:'pipe'});
});
