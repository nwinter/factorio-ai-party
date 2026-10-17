import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
// The d17 artycam Lua contract (artillery_live, the stream's artillery shot).
test('Lua contract: tests/d17_artycam.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_artycam.lua'], { stdio: 'pipe' });
});
