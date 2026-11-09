// Run explicitly on the local private copy; never targets a live world.
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {RconClient} from '../../dist/host/rcon.js';
import {Harness} from '../../dist/host/harness.js';
import {bundleRuntime} from '../../dist/host/bundle.js';
import {compactLua} from '../../dist/host/compact.js';
import {describeLines} from '../../dist/host/format.js';
import assert from 'node:assert/strict';
const copy='/Users/owner/code/personal/player-of-games/headless/pog-headless-b355';
const output='/Users/owner/code/personal/player-of-games/artifacts/batch355';
await mkdir(output,{recursive:true});
const rcon=new RconClient({host:'127.0.0.1',port:27355,password:(await readFile(copy+'/rcon-pass.txt','utf8')).trim(),timeoutMs:60000});
const harness=new Harness(rcon,1,undefined,'luna');
try {
  console.log(await rcon.command('/silent-command game.tick_paused=true; rcon.print(game.tick)'));
  const bundle=await bundleRuntime(fileURLToPath(new URL('../../mod/agent-harness_0.1.0/runtime.lua',import.meta.url)));
  const wrapper=compactLua(await readFile(new URL('./batch355-probe.lua',import.meta.url),'utf8'));
  const source=`local runtime=(function() ${bundle} end)(); local wrap=(function() ${wrapper} end)(); return wrap(runtime)`;
  const installed=await harness.deploy(source);
  if(!installed.ok) throw new Error(JSON.stringify(installed));
  console.log('Installed private probe',installed.tick);
  async function read(label,action,args={}) {
    const reply=await harness.request(action,args);
    await writeFile(`${output}/${label}.json`,JSON.stringify(reply,null,2));
    if(!reply.ok) throw new Error(JSON.stringify(reply.error));
    const result=reply.result;
    const p=result.batch355_proof;
    if(p && Object.values(p.equal).some(x=>!x)) throw new Error('state changed');
    if(p) assert.deepEqual(p.after,p.before);
    console.log(label,JSON.stringify({tick:reply.tick,equal:p?.equal,time:p?.query_time,
      entries:result.entries?.map(e=>({name:e.name,level:e.level,full:e.full_units,remaining:e.remaining_units,progress:e.progress,
        source:e.progress_source,eta:e.takes||e.done_in,cohort:e.cost?.cohort,physical:e.cost?.physical_packs_remaining})),
      refused:result.refused}));
    return result;
  }
  const native=await read('native-rounding','batch355_native');
  console.log('native count comparisons',native.native.length,'mismatches',JSON.stringify(native.native.filter(x=>!x.equal)));
  assert(native.native.every(x=>x.equal));
  await read('live-lds16','technologies',{name:'low-density-structure-productivity',level:16});
  await read('live-lds17','technologies',{name:'low-density-structure-productivity',level:17});
  await read('live-lds15-completed','technologies',{name:'low-density-structure-productivity',level:15});
  await read('live-default','technologies',{name:'low-density-structure-productivity'});
  for(let i=1;i<=6;i++) await read(`timing-${i}`,'technologies',{name:'low-density-structure-productivity',level:16});
  for(const level of [0,1.5,100]) assert((await read(`refused-${level}`,'technologies',{name:'low-density-structure-productivity',level})).refused);
  await read('active-fixture','batch355_fixture');
  assert.equal((await read('active-15','technologies',{name:'low-density-structure-productivity',level:15})).entries[0].remaining_units,109473.25);
  assert.equal((await read('active-16','technologies',{name:'low-density-structure-productivity',level:16})).entries[0].remaining_units,656840);
  const active=await read('active-queue','research');
  assert.deepEqual(active.entries.map(e=>e.level),[15,16,17]);
  assert.deepEqual(active.entries.map(e=>e.full_units),[437893,656840,985261]);
  assert.deepEqual(active.entries.map(e=>e.progress),[75,0,0]);
  await read('saved-fixture','batch355_fixture',{saved:true});
  assert.equal((await read('saved-15','technologies',{name:'low-density-structure-productivity',level:15})).entries[0].remaining_units,273683.125);
  assert.equal((await read('saved-16','technologies',{name:'low-density-structure-productivity',level:16})).entries[0].remaining_units,656840);
  const saved=await read('saved-queue','research');
  assert.deepEqual(saved.entries.slice(1).map(e=>e.level),[15,16,17]);
  assert.deepEqual(saved.entries.slice(1).map(e=>e.progress),[37.5,0,0]);
  const desc=await harness.request('describe');
  await writeFile(output+'/describe.json',JSON.stringify(desc.result,null,2));
  await writeFile(output+'/describe-normalized.json',describeLines(desc.result));
} finally { rcon.close(); }
