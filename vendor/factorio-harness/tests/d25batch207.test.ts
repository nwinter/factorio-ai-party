import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// d25 batch207: QT1 pod_landed counts a pod at its cargo delivery; QT2 platform ammo alerts in magazines.

test('Lua contract: tests/d25_batch207.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua',['tests/d25_batch207.lua'],{stdio:'pipe'});
});
