import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readdir, readFile, writeFile, mkdir, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { compactLua } from '../host/compact.js';
import { bundleRuntime } from '../host/bundle.js';
const lua = process.env.LUA_BIN ?? 'lua';
test('compactLua drops comments and indentation, keeps strings and line numbers', () => {
  const source = [
    '-- header',
    'local a = "x -- not a comment" -- trailing',
    "  local b = 'it\\'s'",
    '\tlocal c = [[',
    '  -- inside a long string',
    ']]',
    'local d = [==[ ]] -- ]==] --[[ long',
    'comment ]] local e = 1',
    'local f = a--[[mid]]..b',
    'local g = "esc \\" -- still string"',
    'return {a=a,b=b,c=c,d=d,e=e,f=f,g=g}',
  ].join('\n');
  const out = compactLua(source);
  assert.equal(out.split('\n').length, source.split('\n').length);
  assert.equal(out, [
    '',
    'local a = "x -- not a comment"',
    "local b = 'it\\'s'",
    'local c = [[',
    '  -- inside a long string',
    ']]',
    'local d = [==[ ]] -- ]==]',
    'local e = 1',
    'local f = a ..b',
    'local g = "esc \\" -- still string"',
    'return {a=a,b=b,c=c,d=d,e=e,f=f,g=g}',
  ].join('\n'));
  assert.throws(() => compactLua('local s = "open'), /unfinished string/);
  assert.throws(() => compactLua('--[[ open'), /unfinished/);
});
test('every Lua suite passes against the compacted modules, and the compacted bundle compiles', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'fh-compact-'));
  await cp('mod', join(dir, 'mod'), {recursive: true});
  await mkdir(join(dir, 'tests'));
  await cp('tests/fixtures', join(dir, 'tests/fixtures'), {recursive:true});
  for (const file of await readdir('tests')) if (file.endsWith('.lua')) await cp(join('tests', file), join(dir, 'tests', file));
  const modDir = join(dir, 'mod/agent-harness_0.1.0');
  for (const file of await readdir(modDir)) {
    if (!file.endsWith('.lua')) continue;
    const path = join(modDir, file);
    await writeFile(path, compactLua(await readFile(path, 'utf8')));
  }
  const suites = [...(await readdir(join(dir, 'tests'))).filter(f => f.endsWith('.lua')).map(f => `tests/${f}`), 'mod/tests/runtime_test.lua', 'mod/tests/control_test.lua'];
  for (const suite of suites) execFileSync(lua, [suite], {cwd: dir, stdio: 'pipe'});
  const bundle = await bundleRuntime('mod/agent-harness_0.1.0/runtime.lua');
  const file = join(dir, 'bundle.lua');
  await writeFile(file, bundle);
  execFileSync(lua, ['-e', `local f=assert(io.open(${JSON.stringify(file)})); assert(load(f:read('a'),'@bundle','t'))`], {stdio: 'pipe'});
  assert.ok(Buffer.byteLength(bundle) < Buffer.byteLength(await bundleRuntime('mod/agent-harness_0.1.0/runtime.lua', {compact: false})));
});
