import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Harness, luaString, parseReply } from '../host/harness.js';
import { bundleRuntime } from '../host/bundle.js';
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
