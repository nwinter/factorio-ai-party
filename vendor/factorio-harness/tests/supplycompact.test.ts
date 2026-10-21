import { execFileSync } from 'node:child_process';
import { test } from 'node:test';

// d20 batch63 Y3: supply compact with consumers, makers, requesters and split (tests/supply_compact.lua).
test('Lua contract: tests/supply_compact.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/supply_compact.lua'], { stdio: 'pipe' });
});
