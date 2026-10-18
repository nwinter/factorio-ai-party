import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Harness, luaString, parseReply, helperThread } from '../host/harness.js';
import { bundleRuntime, bundleId } from '../host/bundle.js';
import { renderMap } from '../host/view.js';
import { execFileSync } from 'node:child_process';
import { mkdtemp, writeFile, rm, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { inflateSync } from 'node:zlib';

test('Lua quoting roundtrips hostile delimiters, Unicode and leading newlines', () => {
  for (const text of ['normal','\nleading newline','"]]; error("oops") --',']===] café 🏭\n\\"\t']) {
    const result = execFileSync('lua',['-e',`io.write(${luaString(text)})`],{encoding:'utf8'});
    assert.equal(result,text);
  }
});
test('request preserves caller ID, sends JSON rather than interpolated action code', async () => {
  let command = '';
  const h = new Harness({async command(c) {command=c;return '{"ok":true,"id":"stable","result":{}}';}},3);
  await h.request('observe',{name:'"]; game.speed=99 --'},'stable');
  assert.match(command,/remote.call\("agent_harness", "dispatch"/);
  assert.match(command,/"player":3/);
  assert.match(command,/"id":"stable"/);
});
test('rejects mismatched IDs and malformed bridge response', async () => {
  const h = new Harness({async command() {return '{"ok":true,"id":"wrong"}';}});
  await assert.rejects(h.request('observe',{},'expected'),/ID mismatch/);
  assert.throws(()=>parseReply('Unknown remote interface'),/agent-harness/);
  assert.throws(()=>parseReply('{"result":1}'),/ok field/);
});
test('bundled sibling modules reload atomically with lexical require and UTF8', async () => {
  await mkdir('.cache',{recursive:true});
  const folder = await mkdtemp(resolve('.cache/bundle-'));
  try {
    await writeFile(resolve(folder,'runtime.lua'),'return {value=require("helper").value}');
    await writeFile(resolve(folder,'helper.lua'),'return {value="café"}');
    await writeFile(resolve(folder,'control.lua'),'error("must not be bundled")');
    const source = await bundleRuntime(resolve(folder,'runtime.lua'));
    const result = execFileSync('lua',['-e',`local result=(function()\n${source}\nend)(); io.write(result.value)`],{encoding:'utf8'});
    assert.equal(result,'café');
  } finally {await rm(folder,{recursive:true,force:true});}
});
test('a bundle names its id (its content hash) as BUNDLE_ID on its first line, so line numbers stay its own', async () => {
  await mkdir('.cache',{recursive:true});
  const folder = await mkdtemp(resolve('.cache/bundle-'));
  try {
    await writeFile(resolve(folder,'runtime.lua'),'return {id=require("helper").id()}');
    await writeFile(resolve(folder,'helper.lua'),'return {id=function() return BUNDLE_ID end}');
    const source = await bundleRuntime(resolve(folder,'runtime.lua'));
    const first = source.split('\n')[0]!;
    const match = /^local BUNDLE_ID = '([0-9a-f]{16})'; local original_require = require$/.exec(first);
    assert.ok(match, first);
    assert.equal(match[1], bundleId(source.slice(first.length - 'local original_require = require'.length)));
    const result = execFileSync('lua',['-e',`local result=(function()\n${source}\nend)(); io.write(result.id)`],{encoding:'utf8'});
    assert.equal(result, match[1]);
    await writeFile(resolve(folder,'helper.lua'),'return {id=function() return BUNDLE_ID, 2 end}');
    assert.notEqual((await bundleRuntime(resolve(folder,'runtime.lua'))).split('\n')[0], first, 'another bundle, another id');
  } finally {await rm(folder,{recursive:true,force:true});}
});
test('headless PNG includes only provided local data and a valid RGB payload', () => {
  const png = renderMap({player:{position:{x:0,y:0}},tiles:[{name:'water',position:{x:-1,y:0}}],entities:[]},2);
  assert.equal(png.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
  assert.equal(png.readUInt32BE(16),40);
  const dataLength = png.readUInt32BE(33);
  assert.equal(png.subarray(37,41).toString(),'IDAT');
  const pixels = inflateSync(png.subarray(41,41+dataLength));
  assert.equal(pixels.length,(40*3+1)*40);
  assert.deepEqual([...pixels.subarray(1,4)],[19,25,31]);
  const playerPixel = 16*(40*3+1)+1+16*3;
  assert.deepEqual([...pixels.subarray(playerPixel,playerPixel+3)],[250,250,255]);
});

test('the fog view: remembered buildings drawn dim, ours lost out of sight outlined in red', () => {
  const png = renderMap({player:{position:{x:0,y:0}},tiles:[],entities:[{name:'gun-turret',type:'ammo-turret',position:{x:1,y:0},remembered:true}],
    fog:{lost:[{name:'gun-turret',position:{x:-1,y:0}}]}},2);
  const pixels = inflateSync(png.subarray(41,41+png.readUInt32BE(33)));
  const at = (tx:number, ty:number, dx:number, dy:number) => { const i=((ty+2)*8+dy)*(40*3+1)+1+((tx+2)*8+dx)*3; return [...pixels.subarray(i,i+3)]; };
  assert.deepEqual(at(1,0,4,4),[120,110,80]);
  assert.deepEqual(at(-1,0,0,4),[224,65,62]);
  assert.deepEqual(at(-1,0,4,4),[19,25,31]);
});
test('renderer accepts Factorio empty Lua tables encoded as objects', () => {
  const image = renderMap({player:{position:{x:0,y:0}},tiles:{},entities:{}},1);
  assert.equal(image.readUInt32BE(16),24);
});
test('map view uses the bootstrap read-only observation action without mutating caller args', async () => {
  let command='';
  const h=new Harness({async command(value){command=value;return '{"ok":true,"id":"map-read","result":{}}';}});
  const args={radius:128};
  await h.request('map',args,'map-read');
  assert.match(command,/"action":"observe"/);
  assert.match(command,/"scope":"map"/);
  assert.deepEqual(args,{radius:128});
});
test('nearest, craftable and power travel as read-only observe scopes', async () => {
  const commands:string[]=[];
  const h=new Harness({async command(value){commands.push(value);return `{"ok":true,"id":"read-${commands.length}","result":{}}`;}});
  await h.request('nearest',{name:'iron-ore'},'read-1');
  await h.request('craftable',{},'read-2');
  await h.request('power',{radius:32},'read-3');
  const [nearest, craftable, power] = commands as [string, string, string];
  assert.match(nearest,/"action":"observe".*"scope":"nearest"/);
  assert.match(craftable,/"action":"observe".*"scope":"craftable"/);
  assert.match(power,/"action":"observe".*"scope":"power"/);
});
test('science and supply travel as read-only observe scopes (a loaded bootstrap caches unknown actions)', async () => {
  const commands:string[]=[];
  const h=new Harness({async command(value){commands.push(value);return `{"ok":true,"id":"read-${commands.length}","result":{}}`;}});
  await h.request('science',{},'read-1');
  await h.request('supply',{item:'advanced-circuit',near:{x:1,y:2}},'read-2');
  const [science, supply] = commands as [string, string];
  assert.match(science,/"action":"observe".*"scope":"science"/);
  assert.match(supply,/"action":"observe".*"item":"advanced-circuit".*"scope":"supply"/);
});

test('platform PNG draws empty space, foundation and footprints without a phantom player',()=>{
  const png=renderMap({platform:'Sunward',position:{x:0,y:0},tile_runs:[{name:'space-platform-foundation',x:0,y:0,count:1}],
    entities:[{name:'crusher',type:'assembling-machine',position:{x:1,y:1},box:{left_top:{x:0,y:1},right_bottom:{x:2,y:2}}}]},2);
  const pixels=inflateSync(png.subarray(41,41+png.readUInt32BE(33)));
  const pixel=(x:number,y:number)=>[...pixels.subarray(y*(40*3+1)+1+x*3,y*(40*3+1)+4+x*3)];
  assert.deepEqual(pixel(20,20),[79,88,100]);
  assert.deepEqual(pixel(12,20),[19,25,31]);
  assert.deepEqual(pixel(20,28),[77,154,160]);assert.deepEqual(pixel(28,28),[77,154,160]);
});

test('a subagent thread marks its requests helper (d15: tells went to Astra\'s helpers); an old runtime drops the mark', async () => {
  assert.equal(helperThread({CODEX_THREAD_ID:'a', CODEX_SESSION_ID:'a'}), false);
  assert.equal(helperThread({CODEX_THREAD_ID:'b', CODEX_SESSION_ID:'a'}), true);
  assert.equal(helperThread({MUSE_THREAD_ID:'t2', MUSE_SESSION_ID:'t1'}), true);
  assert.equal(helperThread({}), false);
  const kept = {t: process.env.CODEX_THREAD_ID, s: process.env.CODEX_SESSION_ID};
  process.env.CODEX_THREAD_ID = 'helper-1'; process.env.CODEX_SESSION_ID = 'root';
  try {
    const sent: any[] = [];
    let refuse = true;
    const h = new Harness({async command(c) {
      const req = JSON.parse(c.match(/dispatch", \[(=*)\[([\s\S]*)\]\1\]\)\)$/)?.[2] ?? '{}');
      sent.push(req);
      if (refuse && req.args.helper) { refuse = false; return JSON.stringify({ok:false,id:req.id,error:{message:'unknown argument helper for status; valid: brief'}}); }
      return JSON.stringify({ok:true,id:req.id,result:{}});
    }});
    const r = await h.request('status', {brief:true});
    assert.equal(r.ok, true);
    assert.equal(sent[0].args.helper, true);
    assert.equal(sent[1].args.helper, undefined);
    assert.notEqual(sent[0].id, sent[1].id);
    await h.request('status', {});
    assert.equal(sent[2].args.helper, undefined, 'not sent again to that runtime');
  } finally {
    if (kept.t === undefined) delete process.env.CODEX_THREAD_ID; else process.env.CODEX_THREAD_ID = kept.t;
    if (kept.s === undefined) delete process.env.CODEX_SESSION_ID; else process.env.CODEX_SESSION_ID = kept.s;
  }
});
