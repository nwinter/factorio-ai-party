import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
// (d26 batch254 TL) Every tests/*.lua and mod/tests/*.lua is a suite, found by pattern: a new suite needs no line here
// (a hand-kept list of 263 conflicted between nearly every pair of parallel batches). None of them is a helper: no
// suite or test loads another by its path, and none ends by returning a module. Each runs in its own lua process and
// writes no file, so the order (sorted by path) does not matter.
// Left out here:
// - a suite another tests/*.test.ts names by its path (its own test, often with more checks beside it): run there once
//   (compact.test.ts runs every suite against the compacted modules, a check of its own: it does not count);
// - SKIP, each with its reason (none now; an entry naming no file fails below).
const SKIP: Record<string, string> = {};
const own = new Set<string>();
for (const file of readdirSync('tests')) {
  if (!file.endsWith('.test.ts') || file === 'lua.test.ts' || file === 'compact.test.ts') continue;
  for (const m of readFileSync(`tests/${file}`, 'utf8').matchAll(/['"`]((?:mod\/)?tests\/[\w.-]+\.lua)['"`]/g)) own.add(m[1]!);
}
const suites = ['tests', 'mod/tests'].flatMap(dir => readdirSync(dir).filter(f => f.endsWith('.lua')).map(f => `${dir}/${f}`))
  .filter(path => !own.has(path) && !(path in SKIP)).sort();
test('Lua suites: every SKIP entry names a suite', () => {
  for (const path of Object.keys(SKIP)) if (!existsSync(path)) throw new Error(`SKIP names ${path}, which is gone`);
});
for (const path of suites) {
  test(`Lua contract: ${path}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua',[path],{stdio:'pipe'});
  });
}
