import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { Harness, luaString, utf8Chunks, LEGACY_INSTALL_BYTES } from '../host/harness.js';
import { tempDir } from './tmp.js';
const lua = process.env.LUA_BIN ?? 'lua';
// Decode a luaString literal the way Lua does (the opening newline is dropped).
function unwrap(literal: string): string {
  const m = literal.match(/^\[(=*)\[\n([\s\S]*)\]\1\]$/);
  assert(m, literal.slice(0, 40));
  return m[2]!;
}
function fakeWorld(limits?: object) {
  const commands: string[] = [];
  const chunks: string[] = [];
  const transport = {async command(text: string) {
    commands.push(text);
    if (text.includes('install_limits')) return limits ? JSON.stringify(limits) : '{}';
    const chunk = text.match(/"install_chunk", "(\w+)", (\d+), (\d+), (\[=*\[[\s\S]*\]=*\])\)\)$/);
    if (chunk) { chunks.push(unwrap(chunk[4]!)); return JSON.stringify({ok:true, received:Number(chunk[2])}); }
    const commit = text.match(/"install_commit", "(\w+)", (\d+)\)\)$/);
    if (commit) return JSON.stringify({ok:Number(commit[2]) === Buffer.byteLength(chunks.join('')), tick:1, protocol:2});
    return JSON.stringify({ok:true, tick:1, protocol:1});
  }};
  return {harness: new Harness(transport), commands, chunks};
}
test('luaString survives values that end in brackets (checked by Lua itself)', () => {
  for (const value of ['a]', 'a]=', ']]', 'x]==]', 'end\n', 'ü]']) {
    const out = execFileSync(lua, ['-e', `io.write(${luaString(value)})`]).toString();
    assert.equal(out, value);
  }
});
test('utf8Chunks keeps characters whole and every piece within the byte cap', () => {
  const text = 'aé€😀'.repeat(1000);
  const parts = utf8Chunks(text, 7);
  assert.equal(parts.join(''), text);
  for (const part of parts) { assert.ok(Buffer.byteLength(part) <= 7); assert.ok(!part.includes('�')); }
});
test('deploy sends one install when the runtime fits every world', async () => {
  const {harness, commands} = fakeWorld();
  const reply = await harness.deploy('return {}');
  assert.equal(reply.ok, true); assert.equal(commands.length, 1); assert.match(commands[0]!, /"install", \[/);
});
test('a larger runtime goes in chunks to a world that reports install limits', async () => {
  const {harness, commands, chunks} = fakeWorld({max_bytes:8388608, chunk_bytes:262144, protocol:2});
  const source = ('-- ü line\n' + 'x'.repeat(90) + ']\n').repeat(6000);
  assert.ok(Buffer.byteLength(source) > LEGACY_INSTALL_BYTES);
  const reply = await harness.deploy(source);
  assert.equal(reply.ok, true); assert.equal(reply.result.chunks, 3);
  assert.equal(chunks.join(''), source);
  for (const part of chunks) assert.ok(Buffer.byteLength(part) <= 262144 - 64);
  assert.match(commands.at(-1)!, new RegExp(`"install_commit", "\\w+", ${Buffer.byteLength(source)}\\)\\)$`));
});
test('the chunked commands deploy has control.lua install the exact runtime', async () => {
  const {harness, commands} = fakeWorld({max_bytes:8388608, chunk_bytes:262144, protocol:2});
  const source = 'local tail = "]"\nreturn {dispatch=function() return {} end,tick=function() end,stop_all=function() end}\n' +
    ('-- padding ]] ]=] ü\n').repeat(40000) + '-- ends in ]';
  await harness.deploy(source);
  const { writeFile, mkdtemp } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const dir = await tempDir('fh-deploy-');
  await writeFile(join(dir, 'expected.lua'), source);
  // control.lua under a minimal engine; every command runs as /silent-command would.
  const runner = [`package.path='mod/agent-harness_0.1.0/?.lua;'..package.path`,
    `log=function() end; storage={}; game={tick=1}; defines={events={on_tick=1}}`,
    `local function json(t) local parts={} for k,v in pairs(t) do if type(v)~='table' then parts[#parts+1]=string.format('%q:%q',k,tostring(v)) end end return '{'..table.concat(parts,',')..'}' end`,
    `helpers={table_to_json=json,json_to_table=function() end}`,
    `script={on_init=function(f) f() end,on_load=function() end,on_configuration_changed=function() end,on_event=function() end}`,
    `local interface`,
    `remote={add_interface=function(_,v) interface=v end,call=function(_,name,...) return interface[name](...) end}`,
    `package.loaded.runtime={dispatch=function() end,tick=function() end,stop_all=function() end}`,
    `dofile('mod/agent-harness_0.1.0/control.lua')`,
    `remote.interfaces={agent_harness=interface}`,
    `local printed={}`,
    `rcon={print=function(s) printed[#printed+1]=s end}`,
    ...commands.map(c => `assert(load(${luaString(c.replace(/^\/silent-command /, ''))}))()`),
    `local f=assert(io.open(${JSON.stringify(join(dir, 'expected.lua'))},'rb')); local want=f:read('a')`,
    `assert(storage.agent_harness.source==want,'source differs: '..#(storage.agent_harness.source or '')..' vs '..#want)`,
    `assert(printed[#printed]:find('"protocol":"2"',1,true),printed[#printed])`,
    `io.write('installed '..#want)`].join('\n');
  await writeFile(join(dir, 'run.lua'), runner);
  const out = execFileSync(lua, [join(dir, 'run.lua')]).toString();
  assert.equal(out, `installed ${Buffer.byteLength(source)}`);
  assert.ok(commands.filter(c => c.includes('install_chunk')).length >= 3);
});
test('a world without chunked installs gets a clear error, and a too-large runtime is refused', async () => {
  const big = 'x'.repeat(LEGACY_INSTALL_BYTES + 1);
  await assert.rejects(fakeWorld().harness.deploy(big), /takes at most 524288 bytes and has no chunked install. Restart the world with the current agent-harness mod/);
  await assert.rejects(fakeWorld({max_bytes:600000, chunk_bytes:262144}).harness.deploy('x'.repeat(600001)), /accepts at most 600000/);
});
