import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { tempDir } from './tmp.js';
const exec = promisify(execFile);
async function engine(reply: (request:any)=>any, run:(port:number)=>Promise<void>) {
  const sockets = new Set<Socket>();
  const server = createServer(socket => {
    sockets.add(socket);socket.on('close',()=>sockets.delete(socket));
    let buffered=Buffer.alloc(0);
    socket.on('data',data=>{
      buffered=Buffer.concat([buffered,data]);
      while (buffered.length>=4 && buffered.length>=buffered.readInt32LE(0)+4) {
        const size=buffered.readInt32LE(0), frame=buffered.subarray(4,size+4);
        buffered=buffered.subarray(size+4);
        const id=frame.readInt32LE(0), kind=frame.readInt32LE(4), text=frame.subarray(8,-2).toString();
        let body='';
        if(kind===2) {
          const match=text.match(/\n(\{.*\})\]\]/);
          assert(match,`bad dispatch: ${text}`);
          const request=JSON.parse(match[1]!);
          body=JSON.stringify({id:request.id,tick:1,...reply(request)});
        }
        const out=Buffer.alloc(Buffer.byteLength(body)+14);
        out.writeInt32LE(out.length-4,0);out.writeInt32LE(id,4);out.writeInt32LE(kind===3?2:0,8);out.write(body,12);
        socket.write(out);
      }
    });
  }).listen(0,'127.0.0.1');
  await once(server,'listening');
  const address=server.address();assert(address && typeof address!=='string');
  try { await run(address.port); }
  finally {for(const socket of sockets)socket.destroy();await new Promise<void>(resolve=>server.close(()=>resolve()));}
}
function cli(port:number,args:string[]) {
  return exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),...args],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
}
test('CLI help works without a server or credentials',async()=>{
  const {stdout}=await exec(process.execPath,['dist/host/cli.js','--help']);
  assert.match(stdout,/queue submit/);assert.match(stdout,/blueprint import/);
});
test('fh help ACTION and fh call ACTION --help print that action from describe (help was an unknown command)',async()=>{
  await engine(request=>{
    assert.equal(request.action,'describe');
    return {ok:true,result:{actions:{circuit_set:{position:'{x,y} of the entity',enable:'a condition',returns:'the readback'}}}};
  },async port=>{
    for (const args of [['help','circuit_set'],['call','circuit_set','--help']]) {
      const {stdout}=await cli(port,args);
      assert.equal(stdout,"circuit_set: fh call circuit_set --args '{...}'\n  position: {x,y} of the entity\n  enable: a condition\nreturns: the readback\n");
    }
  });
});
test('fh help ACTION keeps describe per runtime bundle: if_bundle gets {unchanged}, a new bundle or an old runtime is read whole',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'fh-describe-'));
  const cache=join(dir,'.fh-describe.json');
  const schema=(text:string)=>({actions:{circuit_set:{position:text}}});
  let bundle:string|undefined='b1', text='{x,y} one', seen:any[]=[];
  try {
    await engine(request=>{
      seen.push(request.args ?? {});
      if (request.args?.if_bundle !== undefined && bundle === undefined) return {ok:false,error:{code:'action_failed',message:'unknown argument if_bundle for describe'}};
      if (bundle !== undefined && request.args?.if_bundle === bundle) return {ok:true,result:{bundle,unchanged:true}};
      return {ok:true,result:{...schema(text),...(bundle ? {bundle} : {})}};
    },async port=>{
      const env={...process.env,FACTORIO_RCON_PASSWORD:'test-only',FH_DESCRIBE_CACHE:cache};
      const help=async()=>(await exec(process.execPath,['dist/host/cli.js','--port',String(port),'help','circuit_set'],{env})).stdout;
      assert.match(await help(),/position: \{x,y\} one/);
      assert.deepEqual(seen,[{}]);
      // the same bundle: the game answers two fields and the help comes from the cache
      text='{x,y} not read';
      assert.match(await help(),/position: \{x,y\} one/);
      assert.deepEqual(seen[1],{if_bundle:'b1'});
      // a deploy: a new bundle's describe comes whole and replaces the cache
      bundle='b2'; text='{x,y} two';
      assert.match(await help(),/position: \{x,y\} two/);
      assert.match(await help(),/position: \{x,y\} two/);
      assert.deepEqual(seen.slice(2),[{if_bundle:'b1'},{if_bundle:'b2'}]);
      // a runtime without bundle ids refuses if_bundle: read whole, nothing cached
      bundle=undefined; text='{x,y} three';
      assert.match(await help(),/position: \{x,y\} three/);
      assert.deepEqual(seen.slice(4),[{if_bundle:'b2'},{}]);
    });
  } finally { await rm(dir,{recursive:true,force:true}); }
});
test('fh help TOPIC prints the workspace reference topic and is journaled; fh help lists the topics; an argument refusal names the topic',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'fh-ref-'));
  try {
    const ref=join(dir,'ref');
    await exec('mkdir',['-p',ref]);
    await writeFile(join(ref,'building.md'),'# building\n\n- `build` places things.\n');
    await writeFile(join(ref,'commands.tsv'),'build\tbuilding\nplace_ghosts\tbuilding\ntransfer\tmoving-items\n');
    const env={...process.env,FH_REF_DIR:ref,FACTORIO_RCON_PASSWORD:'test-only'};
    const journal=join(dir,'journal.jsonl');
    const {stdout}=await exec(process.execPath,['dist/host/cli.js','help','building','--journal',journal],{env});
    assert.equal(stdout,'# building\n\n- `build` places things.\n');
    // (d22 batch90 AZ3) fh call help|more runs the subcommand (s55-57 sent them as actions)
    assert.equal((await exec(process.execPath,['dist/host/cli.js','call','help','building'],{env})).stdout,'# building\n\n- `build` places things.\n');
    assert.match((await exec(process.execPath,['dist/host/cli.js','call','more'],{env:{...env,FH_MORE_FILE:join(dir,'none.txt')}})).stdout,/^nothing more/);
    const line=JSON.parse((await import('node:fs')).readFileSync(journal,'utf8').trim());
    assert.equal(line.event,'help');assert.equal(line.topic,'building');
    const list=await exec(process.execPath,['dist/host/cli.js','help'],{env});
    assert.match(list.stdout,/Reference topics \(\.\/fh help TOPIC prints one\): building\n$/);
    await engine(request=>{
      if(request.action==='build') return {ok:false,error:{code:'action_failed',message:'unknown argument ghosts for build; valid: position, item'}};
      if(request.action==='queue_submit') return {ok:false,error:{code:'action_failed',message:'steps[2] (transfer): direction is required (to_entity|to_player)'}};
      if(request.action==='buld') return {ok:false,error:{code:'action_failed',message:'unsupported action; call describe'}};
      if(request.action==='bild') return {ok:false,error:{code:'action_failed',message:'unsupported action; closest: build, place_ghosts; call describe'}};
      return {ok:false,error:{code:'action_failed',message:'entity not found at (1,2)'}};
    },async port=>{
      const run=async(args:string[])=>JSON.parse((await exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),...args],{env}).catch(e=>e)).stdout).error.message;
      assert.equal(await run(['call','build','--args','{"ghosts":1}']),'unknown argument ghosts for build; valid: position, item (reference: ./fh help building)');
      assert.equal(await run(['call','queue_submit','--args','{"steps":[]}']),'steps[2] (transfer): direction is required (to_entity|to_player) (reference: ./fh help moving-items)');
      assert.equal(await run(['call','buld']),'unsupported action; call describe (similar: build; reference: ./fh help building)');
      // (d22 batch90 AZ3) the runtime's closest names: only their topics added
      assert.equal(await run(['call','bild']),'unsupported action; closest: build, place_ghosts; call describe (reference: ./fh help building)');
      assert.equal(await run(['call','inspect']),'entity not found at (1,2)', 'a refusal of the game state gets no reference');
    });
  } finally { await rm(dir,{recursive:true,force:true}); }
});
test('queue command maps to runtime protocol with JSON-only stdout',async()=>{
  await engine(request=>{
    assert.equal(request.action,'queue_status');assert.equal(request.player,2);
    return {ok:true,result:{revision:5,pending:[]}};
  },async port=>{
    const {stdout,stderr}=await cli(port,['queue','status','--player','2']);
    assert.equal(stderr,'');assert.equal(JSON.parse(stdout).result.revision,5);
  });
});
test('--bot and FH_BOT address a bot by name instead of a player',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{}};},async port=>{
    await cli(port,['call','status','--bot','astra']);
    await exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),'call','status'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only',FH_BOT:'opus'}});
    await exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),'call','status','--player','2'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only',FH_BOT:'opus'}});
  });
  assert.equal(seen[0].bot,'astra');assert.equal(seen[0].player,undefined);
  assert.equal(seen[1].bot,'opus');
  assert.equal(seen[2].player,2);assert.equal(seen[2].bot,undefined);
  await assert.rejects(cli(1,['call','status','--bot','astra','--player','2']),(e:any)=>/not both/.test(e.stdout+e.stderr));
  await assert.rejects(cli(1,['call','status','--bot','Astra!']),(e:any)=>/must be a bot name/.test(e.stdout+e.stderr));
});
test('queue submit rejects a plan file that is not an array before contacting the game',async()=>{
  const {writeFile,mkdtemp}=await import('node:fs/promises');
  const {tmpdir}=await import('node:os');
  const {join}=await import('node:path');
  const dir=await tempDir('fh-plan-');
  const file=join(dir,'plan.json');
  await writeFile(file,JSON.stringify({action:'walk',args:{direction:'east',ticks:10}}));
  await engine(()=>{assert.fail('no request expected');},async port=>{
    await assert.rejects(cli(port,['queue','submit','--file',file]),(error:any)=>{
      assert.match(String(error.stderr)+String(error.stdout),/must be a JSON array of steps/); return true;
    });
  });
});
test('--wait waits for shoot channel and reports interrupted completion',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='shoot')return {ok:true,result:{until_tick:60}};
    assert.equal(request.action,'status');polls++;
    if(polls<=2)assert.equal(request.args.peek,true);
    return {ok:true,result:polls===1?{active:{kind:'shoot'},combat:{until_tick:60}}:{active:false,combat:false,last_combat:{outcome:'interrupted'}}};
  },async port=>{
    try {
      await cli(port,['call','shoot','--args','{"auto":true,"ticks":60}','--wait']);
      assert.fail('interrupted action must exit nonzero');
    } catch(error:any) {
      assert.equal(error.code,1);
      assert.equal(JSON.parse(error.stdout).error.code,'action_interrupted');
      assert.equal(polls,3); // two peek polls, then the reply the agent sees
    }
  });
});
test('--wait on a pickup that took everything succeeds (picked_up)',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='pickup')return {ok:true,result:{until_tick:60,item_stacks:2}};
    assert.equal(request.action,'status');polls++;
    return {ok:true,result:polls===1?{active:{kind:'pickup'}}:{active:false,last:{kind:'pickup',outcome:'picked_up',picked:{coal:100}}}};
  },async port=>{
    const {stdout}=await cli(port,['call','pickup','--args','{"radius":8}','--wait']);
    assert.equal(JSON.parse(stdout).ok,true);
  });
});
// Cliff explosives by hand (Sol 17:21 and 17:32): clear_cliffs --wait (and use_item cliff-explosives --wait) waits for
// the throws to land, and cliffs_destroyed ends it as a success; fh wait after it too.
const cliffCalls: Array<[string, string]> = [['clear_cliffs','{"positions":[{"x":82,"y":38.5}]}'],['use_item','{"item":"cliff-explosives","position":{"x":82,"y":38.5}}']];
for (const [action,args] of cliffCalls) {
  test(`--wait on ${action} with cliff explosives waits for the blast and succeeds (cliffs_destroyed)`,async()=>{
    let polls=0;
    await engine(request=>{
      if(request.action===action)return {ok:true,result:{until_tick:7260,spots:[{position:{x:82,y:38.5},cliffs:[{name:'cliff-gleba'}]}],range:10}};
      assert.equal(request.action,'status');polls++;
      return {ok:true,result:polls===1?{active:{kind:'clear_cliffs',until_tick:7260}}:
        {active:false,last:{kind:'clear_cliffs',outcome:'cliffs_destroyed',tick:70,thrown:1,destroyed:[{name:'cliff-gleba',position:{x:82,y:38.5}}],left:3}}};
    },async port=>{
      const {stdout}=await cli(port,['call',action,'--args',args,'--wait']);
      const reply=JSON.parse(stdout);
      assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.outcome,'cliffs_destroyed'); assert.equal(polls,3);
    });
  });
}
test('fh wait after clear_cliffs: cliffs_destroyed is a success (exit 0)',async()=>{
  await engine(()=>({ok:true,result:{active:false,last:{kind:'clear_cliffs',outcome:'cliffs_destroyed',tick:70,thrown:1,left:3}}}),async port=>{
    const {stdout}=await cli(port,['wait']);
    assert.equal(JSON.parse(stdout).ok,true);
  });
});
test('use_item with a grenade is not waited for (no until_tick)',async()=>{
  let statuses=0;
  await engine(request=>{
    if(request.action==='use_item')return {ok:true,result:{used:'grenade',kind:'throw',left:3}};
    statuses++;
    return {ok:true,result:{active:false}};
  },async port=>{
    const {stdout}=await cli(port,['call','use_item','--args','{"item":"grenade","position":{"x":5,"y":0}}','--wait']);
    assert.equal(JSON.parse(stdout).ok,true); assert.ok(statuses<=1,String(statuses));
  });
});
test('--wait on a transfer that is awaiting a hand craft waits for the feed to land',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='transfer')return {ok:true,result:{awaiting_craft:{item:'lab',held:0,need:1,crafting:1},until_tick:900}};
    assert.equal(request.action,'status');polls++;
    return {ok:true,result:polls===1?{active:{kind:'feed',awaiting_craft:true,until_tick:900}}:{active:false,last:{kind:'feed',outcome:'fed',result:{transferred:1}}}};
  },async port=>{
    const {stdout}=await cli(port,['call','transfer','--args','{"position":{"x":1,"y":1},"item":"lab"}','--wait']);
    const reply=JSON.parse(stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.outcome,'fed'); assert.equal(polls,3);
  });
});
test('compact CLI output preserves failure details and nonzero exit status',async()=>{
  await engine(()=>({ok:false,error:{code:'placement_blocked',message:'Cannot build here'}}),async port=>{
    await assert.rejects(cli(port,['call','build','--format','compact']), (error:any)=>{
      assert.equal(error.code,1);
      assert.match(error.stdout,/error: placement_blocked: Cannot build here\n$/);
      return true;
    });
  });
});

test('CLI defaults to compact output',async()=>{
  await engine(()=>({ok:true,result:{revision:5}}),async port=>{
    const {stdout}=await exec(process.execPath,['dist/host/cli.js','--port',String(port),'queue','status'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
    assert.match(stdout,/revision: 5/);
    assert.throws(()=>JSON.parse(stdout));
  });
});
test('blueprint inspection uses the existing read-only export protocol',async()=>{
  await engine(request=>{
    assert.equal(request.action,'blueprint_export');
    assert.deepEqual(request.args,{slot:'plan',layout:true});
    return {ok:true,result:{layout:[]}};
  },async port=>{await cli(port,['blueprint','inspect','--args','{"slot":"plan"}']);});
});
test('a library entry\'s export goes to blueprints/NAME.txt in the workspace without --out (d20 batch59 U2)',async()=>{
  const dir=await tempDir('fh-bpexport-');
  const {readFile}=await import('node:fs/promises');
  await engine(request=>{
    assert.equal(request.action,'blueprint_export');
    return {ok:true,result:{name:'smelter-row',author:'sol',blueprint:'0eNqA'}};
  },async port=>{
    const {stdout}=await exec(process.execPath,[join(process.cwd(),'dist/host/cli.js'),'--format','json','--port',String(port),'blueprint','export','--args','{"name":"smelter-row"}'],
      {cwd:dir,env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
    const reply=JSON.parse(stdout);
    assert.equal(reply.result.blueprint,undefined,'the string is in the file, not the reply');
    assert.equal(reply.result.path,join(await (await import('node:fs/promises')).realpath(dir),'blueprints','smelter-row.txt'));
    assert.equal(await readFile(join(dir,'blueprints','smelter-row.txt'),'utf8'),'0eNqA\n');
  });
  // (d22 batch80 AP1) a whole platform's string in pages: the file gets every page, in order.
  const froms:unknown[]=[];
  await engine(request=>{
    froms.push(request.args.from);
    const pages:Record<string,any>={'undefined':{blueprint:'0eA',next_from:3},'3':{blueprint:'BC',next_from:5},'5':{blueprint:'D'}};
    return {ok:true,result:{name:'asterion',...pages[String(request.args.from)],blueprint_page:'bytes'}};
  },async port=>{
    const {stdout}=await exec(process.execPath,[join(process.cwd(),'dist/host/cli.js'),'--format','json','--port',String(port),'call','blueprint_export','--args','{"name":"asterion"}'],
      {cwd:dir,env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
    const reply=JSON.parse(stdout);
    assert.deepEqual(froms,[undefined,3,5]);
    assert.equal(reply.result.pages,3); assert.equal(reply.result.next_from,undefined); assert.equal(reply.result.blueprint,undefined);
    assert.equal(await readFile(join(dir,'blueprints','asterion.txt'),'utf8'),'0eABCD\n');
  });
  // A slot's export without --out stays in the reply, as before.
  await engine(()=>({ok:true,result:{slot:'clipboard',blueprint:'0eNqB'}}),async port=>{
    const {stdout}=await cli(port,['call','blueprint_export']);
    assert.equal(JSON.parse(stdout).result.blueprint,'0eNqB');
  });
});
test('a --wait that outlasts its timeout reports the action still running, after showing acceptance in compact output',async()=>{
  await engine(request=>{
    if(request.action==='construct')return {ok:true,result:{until_tick:36000,total:4}};
    return {ok:true,result:{active:{kind:'construct',remaining:4,awaiting_craft:true}}};
  },async port=>{
    try {
      await exec(process.execPath,['dist/host/cli.js','--port',String(port),'call','construct','--wait','--wait-timeout','250'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
      assert.fail('an unfinished wait must exit nonzero');
    } catch(error:any) {
      assert.equal(error.code,3,'3: the action still runs');
      assert.match(error.stdout,/^tick: 1\nwaiting: .*\nuntil_tick: 36000\ntotal: 4\n/);
      assert.match(error.stdout,/wait_timeout/);
      assert.match(error.stdout,/STILL RUNNING/);
      assert.match(error.stdout,/timed_out: true/);
      assert.match(error.stdout,/still_running:/);
      assert.match(error.stdout,/awaiting_craft/);
      assert.doesNotMatch(error.stdout,/completion:/);
    }
  });
});
test('a timed-out --wait in JSON has no completion, only timed_out and still_running',async()=>{
  await engine(request=>{
    if(request.action==='construct')return {ok:true,result:{until_tick:36000,total:4}};
    return {ok:true,result:{active:{kind:'construct',until_tick:36000,remaining:4}}};
  },async port=>{
    try {
      await cli(port,['call','construct','--wait','--wait-timeout','250']);
      assert.fail('an unfinished wait must exit nonzero');
    } catch(error:any) {
      const reply=JSON.parse(error.stdout);
      assert.equal(reply.ok,false); assert.equal(reply.error.code,'wait_timeout');
      assert.equal(reply.result.timed_out,true); assert.equal(reply.result.still_running.kind,'construct');
      assert.equal(reply.result.completion,undefined); assert.equal(reply.result.accepted.total,4);
      assert.match(reply.error.message,/fh wait/);
    }
  });
});
test('fh wait blocks until the character is idle and reports the last outcome',async()=>{
  let polls=0;
  await engine(request=>{
    assert.equal(request.action,'status'); polls++;
    return {ok:true,tick:polls*10,result:polls<3?{active:{kind:'construct',until_tick:600}}:{active:false,combat:false,last:{kind:'construct',outcome:'constructed'}}};
  },async port=>{
    const {stdout}=await cli(port,['wait']);
    const reply=JSON.parse(stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.idle,true); assert.equal(reply.result.last.outcome,'constructed'); assert.equal(polls,4);
  });
});
test('fh wait exits nonzero when the action ended badly or is still running at the timeout',async()=>{
  await engine(()=>({ok:true,result:{active:false,combat:false,last:{kind:'move_to',outcome:'blocked'}}}),async port=>{
    await assert.rejects(cli(port,['wait']),(error:any)=>{ assert.equal(JSON.parse(error.stdout).error.code,'action_interrupted'); return true; });
  });
  await engine(()=>({ok:true,tick:5,result:{active:{kind:'mine',until_tick:65}}}),async port=>{
    await assert.rejects(cli(port,['wait','--wait-timeout','200']),(error:any)=>{
      assert.equal(error.code,3);
      const reply=JSON.parse(error.stdout);
      assert.equal(reply.error.code,'wait_timeout'); assert.equal(reply.result.still_running.kind,'mine'); assert.match(reply.error.message,/up to 1 s more/);
      // Exit 3 says on stderr that the action goes on (Grok, d15).
      assert.match(error.stderr,/still running \(exit 3\): mine goes on after this wait ended \(a walk keeps walking\); fh wait resumes waiting for it/);
      assert.match(error.stderr,/A call that drives your character \(move_to, transfer, collect.*stops it; reads .* leave it running/);
      return true;
    });
  });
});
test('fh wait allows a feed short only when up_to was recorded on its completion',async()=>{
  for (const allowed of [true,false]) {
    await engine(()=>({ok:true,result:{active:false,last:{kind:'gather',op:'feed',outcome:'out_of_items',short_allowed:allowed,moved:100,left:1}}}),async port=>{
      const {code,stdout}=await compact(port,['wait']);
      assert.equal(code,allowed?0:1,stdout);
      assert.match(stdout,/out_of_items/);
    });
  }
});
test('board and plan commands map to the board actions',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{}};},async port=>{
    await cli(port,['board','--bot','astra']);
    await cli(port,['board','post','--bot','astra','--args','{"kind":"task","title":"x"}']);
    await cli(port,['board','request','--bot','astra','--args','{"title":"x","problem":"y"}']);
    const dir=await tempDir('fh-plan-save-');  // (d24 batch186) not .cache/ in the checkout: the gate runs in the live one
    const file=`${dir}/plan.json`;
    await (await import('node:fs/promises')).writeFile(file,'[{"action":"walk","args":{"direction":"east","ticks":5}}]');
    await cli(port,['plan','save','east','--file',file,'--bot','astra']);
    await cli(port,['plan','run','east','--bot','astra']);
    await cli(port,['plan','delete','east','--bot','astra']);
    await cli(port,['plan','list','--bot','astra']);
  });
  assert.deepEqual(seen.map(r=>r.action),['board','board_post','harness_request','plan_save','plan_run','plan_save','plans']);
  assert.equal(seen[1].args.title,'x'); assert.equal(seen[1].bot,'astra');
  assert.equal(seen[3].args.name,'east'); assert.equal(seen[3].args.steps[0].action,'walk');
  assert.equal(seen[4].args.name,'east'); assert.equal(seen[5].args.delete,true);
  await assert.rejects(cli(1,['plan','run']),(e:any)=>/requires a plan NAME/.test(e.stdout+e.stderr));
  await assert.rejects(cli(1,['board','bogus']),(e:any)=>/board expects/.test(e.stdout+e.stderr));
});
function compact(port:number,args:string[],env:Record<string,string>={},input?:string) {
  const child=execFile(process.execPath,['dist/host/cli.js','--port',String(port),...args],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only',...env}});
  const done=new Promise<{code:number|null,stdout:string}>((resolve)=>{
    let stdout='';child.stdout!.on('data',d=>stdout+=d);child.on('close',code=>resolve({code,stdout}));
  });
  if(input!==undefined)child.stdin!.end(input);
  return done;
}
test('say takes plain text, a file or stdin, without JSON quoting',async()=>{
  const seen:any[]=[];
  const {writeFile}=await import('node:fs/promises');
  const dir=await tempDir('fh-say-');
  await writeFile(`${dir}/line.txt`,"it's \"done\" $HOME\n");
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length}};},async port=>{
    await cli(port,['say',"I'll","bring","gears",'--bot','astra']);
    await cli(port,['say','--text-file',`${dir}/line.txt`,'--aloud','--bot','astra']);
    assert.equal((await compact(port,['say','-','--bot','astra'],{},"from stdin, it's fine\n")).code,0);
    assert.equal((await compact(port,['say','--bot','astra'],{},'piped\n')).code,0);
    const empty=await compact(port,['say','--bot','astra'],{},'');
    assert.equal(empty.code,1); assert.match(empty.stdout,/error: client_error: say needs text/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args.text,r.args.aloud]),[
    ['say',"I'll bring gears",undefined],['say','it\'s "done" $HOME',true],['say',"from stdin, it's fine",undefined],['say','piped',undefined]]);
});
test('a say over 500 bytes posts numbered parts cut at sentence ends (d19 batch42 A1); reply_to and look go with the first',async()=>{
  const seen:any[]=[];
  const sentence='The recyclers feed the assemblers through one belt, and the second line takes their output to a chest. ';
  const text='@Foobator '+sentence.repeat(7).trim();
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:100+seen.length}};},async port=>{
    const {stdout}=await cli(port,['say',text,'--aloud','--args','{"reply_to":7}','--bot','muse']);
    const reply=JSON.parse(stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.seq,102);
    assert.deepEqual(reply.result.parts.map((p:any)=>p.seq),[101,102]);
    assert.match(reply.result.split,/2 parts at sentence ends/);
    const many=await compact(port,['say','word. '.repeat(700),'--bot','muse']);
    assert.equal(many.code,1); assert.match(many.stdout,/fh posts up to 6 parts of 500 bytes, and this needs \d+; nothing was sent/);
  });
  assert.deepEqual(seen.map(r=>[r.args.text.slice(0,16),r.args.aloud,r.args.reply_to]),[['@Foobator (1/2) ',true,7],['@Foobator (2/2) ',true,undefined]]);
  assert(seen.every(r=>Buffer.byteLength(r.args.text)<=500 && r.args.text.endsWith('chest.')));
});
test('a tell goes whole up to 2000 bytes with --summary, over 2000 refused (d27 batch273 TL; parts until then)',async()=>{
  const seen:any[]=[];
  const sentence='Water route is live now and the chamber is full, so the egg line can run without hand feeding. ';
  const text=sentence.repeat(8).trim();
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:40+seen.length,to:['astra']}};},async port=>{
    const {stdout}=await cli(port,['tell','astra',text,'--summary','egg line runs without hand feeding','--wake','--bot','luna']);
    const reply=JSON.parse(stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.seq,41); assert.equal(reply.result.parts,undefined);
    const over=await compact(port,['tell','astra','x'.repeat(2001),'--summary','s','--bot','luna']);
    assert.equal(over.code,1); assert.match(over.stdout,/tell text is 2001 bytes; the limit is 2000: shorten it; nothing was sent/);
    const where=await compact(port,['say','hi','--summary','s','--bot','luna']);
    assert.equal(where.code,1); assert.match(where.stdout,/--summary applies to tell/);
    // a confession or chronicle entry over its limit: refused, nothing sent (the runtime cut them without a word)
    const conf=await compact(port,['confess','x'.repeat(301),'--bot','luna']);
    assert.equal(conf.code,1); assert.match(conf.stdout,/confess text is 301 bytes; the limit is 300: shorten it; nothing was sent/);
    const chron=await compact(port,['chronicle','Short entry.','--title','t'.repeat(81),'--bot','luna']);
    assert.equal(chron.code,1); assert.match(chron.stdout,/chronicle title is 81 bytes; the limit is 80/);
  });
  assert.equal(seen.length,1);
  assert.deepEqual(seen.map(r=>[r.action,r.args.to,r.args.text,r.args.summary,r.args.fyi,r.args.wake]),
    [['tell','astra',text,'egg line runs without hand feeding',undefined,true]]);
});
test('confess takes text like say and maps to the confess action',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length,note:'viewers hear this; teammates do not'}};},async port=>{
    await cli(port,['confess',"I","don't","trust","grok's","belts",'--bot','astra']);
    assert.equal((await compact(port,['confess','-','--bot','astra'],{},"it's going fine\n")).code,0);
    const loud=await compact(port,['confess','x','--aloud','--bot','astra']);
    assert.equal(loud.code,1); assert.match(loud.stdout,/error: client_error: --aloud applies to say/);
    const empty=await compact(port,['confess','--bot','astra'],{},'');
    assert.match(empty.stdout,/error: client_error: confess needs text/);
    await cli(port,['call','confessions','--since','4','--bot','astra']);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['confess',{text:"I don't trust grok's belts"}],['confess',{text:"it's going fine"}],['confessions',{since:4}]]);
});
test('chronicle takes text like say, an optional --title, and maps to the chronicle action',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length,game_time:'40h02m'}};},async port=>{
    await cli(port,['chronicle','The',"silo's",'first','rocket','left','at','dusk.','--title','Liftoff','--bot','sol']);
    assert.equal((await compact(port,['chronicle','-','--bot','sol'],{},"Vulcanus at last.\n")).code,0);
    await cli(port,['call','chronicle','Starling','fell','to','the','rocks','--bot','sol']);
    const titled=await compact(port,['say','x','--title','T','--bot','sol']);
    assert.equal(titled.code,1); assert.match(titled.stdout,/error: client_error: --title applies to chronicle/);
    const loud=await compact(port,['chronicle','x','--aloud','--bot','sol']);
    assert.match(loud.stdout,/error: client_error: --aloud applies to say; a chronicle entry goes to the site's chronicle/);
    const empty=await compact(port,['chronicle','--bot','sol'],{},'');
    assert.match(empty.stdout,/error: client_error: chronicle needs text/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['chronicle',{text:"The silo's first rocket left at dusk.",title:'Liftoff'}],
    ['chronicle',{text:'Vulcanus at last.'}],['chronicle',{text:'Starling fell to the rocks'}]]);
});
test('operator takes text like say and maps to the operator action',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length,note:'filed for the operator'}};},async port=>{
    await cli(port,['operator','a','viewer',"wants","Grok's",'voice','louder','--bot','astra']);
    assert.equal((await compact(port,['operator','-','--bot','astra'],{},"belt_route can't start diagonally\n")).code,0);
    await cli(port,['call','operator','tools','request','--bot','astra']);
    const loud=await compact(port,['operator','x','--aloud','--bot','astra']);
    assert.equal(loud.code,1); assert.match(loud.stdout,/an operator request goes to the operator/);
    const empty=await compact(port,['operator','--bot','astra'],{},'');
    assert.match(empty.stdout,/error: client_error: operator needs text/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['operator',{text:"a viewer wants Grok's voice louder"}],
    ['operator',{text:"belt_route can't start diagonally"}],['operator',{text:'tools request'}]]);
});
test('tell takes recipients then text like say; tells reads with --since',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length,to:['sol']}};},async port=>{
    await cli(port,['tell','sol',"29","plates","in","the","chest","at","(-18.5,-34.5)",'--bot','astra']);
    assert.equal((await compact(port,['tell','luna,sol','-','--bot','astra'],{},"it's in the mall chest\n")).code,0);
    await cli(port,['tell','team','north belt is down','--bot','astra']);
    const loud=await compact(port,['tell','sol','x','--aloud','--bot','astra']);
    assert.equal(loud.code,1); assert.match(loud.stdout,/error: client_error: --aloud applies to say; a tell stays off/);
    const noname=await compact(port,['tell','--bot','astra']);
    assert.match(noname.stdout,/error: client_error: tell needs a name/);
    const empty=await compact(port,['tell','sol','--bot','astra'],{},'');
    assert.match(empty.stdout,/error: client_error: tell needs text: fh tell NAME "text"/);
    await cli(port,['tells','--since','2','--bot','astra']);
    await cli(port,['call','tell','sol','call','form','--bot','astra']);
    await cli(port,['call','tell','--args','{"to":"sol","text":"json form"}','--bot','astra']);
    await cli(port,['tell','sonnet','freight','needs','you','--wake','--bot','astra']);
    const wakeSay=await compact(port,['say','x','--wake','--bot','astra']);
    assert.equal(wakeSay.code,1); assert.match(wakeSay.stdout,/--wake applies to tell/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['tell',{to:'sol',text:'29 plates in the chest at (-18.5,-34.5)'}],
    ['tell',{to:'luna,sol',text:"it's in the mall chest"}],['tell',{to:'team',text:'north belt is down'}],['tells',{since:2}],
    ['tell',{to:'sol',text:'call form'}],['tell',{to:'sol',text:'json form'}],['tell',{to:'sonnet',text:'freight needs you',wake:true}]]);
});
test('fh platform NAME reads one platform (the platforms read); without a name, all',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{platforms:[]}};},async port=>{
    await cli(port,['platform','Sunward','--bot','gemini']);
    await cli(port,['platform','Deep','Blue','--bot','gemini']);
    await cli(port,['platform','--bot','gemini']);
  });
  // (platforms goes over the wire as observe {scope: platforms}, as fh call platforms does)
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['observe',{platform:'Sunward',scope:'platforms'}],
    ['observe',{platform:'Deep Blue',scope:'platforms'}],['observe',{scope:'platforms'}]]);
});
test('vote, votes, players and restore take words; fh call accepts the same words',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{id:1}};},async port=>{
    await cli(port,['vote','kick','nick','mined',"the","bus's","poles",'--bot','astra']);
    await cli(port,['vote','no','kick','nick','--bot','astra']);
    await cli(port,['call','vote','yes','trust','nick','rebuilt it','--bot','astra']);
    await cli(port,['votes','--bot','astra']);
    await cli(port,['players','--bot','astra']);
    await cli(port,['players','nick','--args','{"minutes":30}','--bot','astra']);
    await cli(port,['call','restore','nick','--bot','astra']);
    await cli(port,['restore','--args','{"player":"nick","minutes":5}','--bot','astra']);
    const bare=await compact(port,['vote','kick','--bot','astra']);
    assert.equal(bare.code,1); assert.match(bare.stdout,/error: client_error: vote kick needs a player: fh vote kick PLAYER/);
    assert.match((await compact(port,['restore','--bot','astra'])).stdout,/error: client_error: restore needs a player/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['vote',{kind:'kick',player:'nick',reason:"mined the bus's poles"}],
    ['vote',{yes:false,kind:'kick',player:'nick'}],['vote',{yes:true,kind:'trust',player:'nick',reason:'rebuilt it'}],['votes',{}],
    ['players',{}],['players',{minutes:30,player:'nick'}],['restore',{player:'nick'}],['restore',{player:'nick',minutes:5}]]);
});
test('vote mute|unmute VIEWER reason maps to the vote action; vote list to votes',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{votes:1,needed:2,active:3}};},async port=>{
    await cli(port,['vote','mute','Troll42','slurs','in','chat','--bot','astra']);
    assert.equal((await compact(port,['vote','unmute','Troll42','-','--bot','astra'],{},"he's sorry\n")).code,0);
    await cli(port,['vote','list','--bot','astra']);
    const bad=await compact(port,['vote','poke','x','y','--bot','astra']);
    assert.equal(bad.code,1); assert.match(bad.stdout,/vote takes mute, unmute, kick, ban, trust or list/);
    assert.match((await compact(port,['vote','mute','--bot','astra'])).stdout,/vote mute needs a viewer/);
    assert.match((await compact(port,['vote','mute','bob','--bot','astra'])).stdout,/vote mute needs a reason/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['vote',{kind:'mute',viewer:'Troll42',reason:'slurs in chat'}],
    ['vote',{kind:'unmute',viewer:'Troll42',reason:"he's sorry"}],['votes',{}]]);
});
test('board plan takes goals, doing and for NAME as words; research [done] maps to research and research_done',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{plan:false}};},async port=>{
    await cli(port,['board','plan','--bot','astra']);
    await cli(port,['board','plan','goals','robots',"by",'hour','3','--bot','astra']);
    await cli(port,['board','plan','doing','oil','at','the','north','field','--bot','astra']);
    await cli(port,['board','plan','for','luna','scout','south','--bot','astra']);
    assert.equal((await compact(port,['board','plan','goals','-','--bot','astra'],{},"it's the plan\n")).code,0);
    await cli(port,['board','plan','doing','','--bot','astra']);
    await cli(port,['board','plan','goals','--bot','astra']);
    await cli(port,['board','plan','goals','','--bot','astra']);
    assert.match((await compact(port,['board','plan','doing','--bot','astra'])).stdout,/board plan doing needs the text \("" removes the line\)/);
    assert.match((await compact(port,['board','plan','for','luna','--bot','astra'])).stdout,/board plan for NAME needs the text/);
    await cli(port,['research','--bot','astra']);
    await cli(port,['research','done','--bot','astra']);
    assert.match((await compact(port,['board','plan','why','--bot','astra'])).stdout,/board plan takes goals "text", doing "text" or for NAME "text"/);
    assert.match((await compact(port,['board','plan','for','--bot','astra'])).stdout,/board plan for needs a NAME/);
    assert.match((await compact(port,['research','queue','--bot','astra'])).stdout,/research takes nothing or done/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['board_plan',{}],['board_plan',{goals:'robots by hour 3'}],
    ['board_plan',{doing:'oil at the north field'}],['board_plan',{agent:'luna',doing:'scout south'}],['board_plan',{goals:"it's the plan"}],
    ['board_plan',{doing:''}],['board_plan',{goals:''}],['board_plan',{clear:true}],['research',{}],['research_done',{}]]);
});
test('fh call say with words sends them as text (it used to send {})',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:1}};},async port=>{
    await cli(port,['call','say',"it's","fine",'--bot','astra']);
    await cli(port,['call','confess','quietly','--bot','astra']);
    await cli(port,['call','say','--args','{"text":"json form"}','--bot','astra']);
    await assert.rejects(cli(port,['call','say','--bot','astra']),(e:any)=>/say needs text/.test(e.stdout));
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args.text]),[['say',"it's fine"],['confess','quietly'],['say','json form']]);
});
test('--format json failures keep stdout one JSON document and print the error: line on stderr',async()=>{
  await engine(()=>({ok:false,error:{code:'action_failed',message:'no transport-belt in inventory'}}),async port=>{
    await assert.rejects(cli(port,['call','build']),(e:any)=>{
      assert.equal(JSON.parse(e.stdout).error.code,'action_failed');
      assert.equal(e.stderr.trim().split('\n').pop(),'error: action_failed: no transport-belt in inventory');
      return true;
    });
  });
  await engine(()=>({ok:true,result:{crafted:2,short:{'iron-plate':4}}}),async port=>{
    const {stdout,stderr}=await cli(port,['call','craft']);
    assert.equal(JSON.parse(stdout).result.crafted,2);
    assert.match(stderr,/^warning: short: /m);
  });
  await engine(()=>({ok:true,result:{seq:1}}),async port=>{
    assert.equal((await cli(port,['call','status'])).stderr,'');
  });
});
test('chat and board events take --since; chat --limit and --peek',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{messages:[],cursor:9}};},async port=>{
    await cli(port,['chat','--bot','astra']);
    await cli(port,['chat','--since','0','--limit','5','--peek','--bot','astra']);
    await cli(port,['call','chat','--since','7','--bot','astra']);
    await cli(port,['board','events','--since','12','--bot','astra']);
    await assert.rejects(cli(port,['call','status','--since','3']),(e:any)=>/--since applies to/.test(e.stdout));
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['chat',{}],['chat',{since:0,limit:5,peek:true}],['chat',{since:7}],['board_events',{since_seq:12}]]);
});
test('the clock line carries the time left from the deadline file',async()=>{
  const {writeFile}=await import('node:fs/promises');
  const dir=await tempDir('fh-deadline-');
  const at=new Date(Date.now()+23*60000+30000);
  const pad=(n:number)=>String(n).padStart(2,'0');
  await writeFile(`${dir}/deadline.txt`,`${at.getFullYear()}-${pad(at.getMonth()+1)}-${pad(at.getDate())} ${pad(at.getHours())}:${pad(at.getMinutes())}\n`);
  await engine(()=>({ok:true,result:{clock:'game 1m; +5s since your last request'}}),async port=>{
    const viaEnv=await compact(port,['call','status'],{FH_DEADLINE_FILE:`${dir}/deadline.txt`});
    assert.match(viaEnv.stdout,/clock: "game 1m; \+5s since your last request; deadline in 2[23]m"/);
    const viaFlag=await compact(port,['call','status','--deadline-file',`${dir}/deadline.txt`]);
    assert.match(viaFlag.stdout,/deadline in 2[23]m/);
    const missing=await compact(port,['call','status','--deadline-file',`${dir}/none.txt`]);
    assert.equal(missing.code,0); assert.doesNotMatch(missing.stdout,/deadline/);
  });
});
test('compact --wait: outcome, position, inventory change and one clock line; peek polls leave the hints for that reply',async()=>{
  const seen:any[]=[];
  let polls=0;
  await engine(request=>{
    seen.push(request);
    if(request.action==='observe'){
      const inventory=request.args.peek?[{name:'coal',count:10}]:[{name:'coal',count:4},{name:'iron-ore',count:12}];
      return {ok:true,result:{player:{position:{x:5,y:-2},health:250,max_health:250,inventory},
        ...(request.args.peek?{}:{team:{alerts:['attack near (0,0)']},clock:'game 2m; +3s since your last request',chat:{unread:1,latest:'sol: hi'}})}};
    }
    if(request.action==='mine')return {ok:true,result:{until_tick:120},};
    polls++;
    assert.equal(request.args.peek,true);
    return {ok:true,result:polls===1?{active:{kind:'mine',until_tick:120}}:{active:false,last:{kind:'mine',outcome:'target_mined',result:{mined:12}},position:{x:5,y:-2},
      factory:{huge:'status block'},evolution:{factor:0.1}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','mine','--args','{"position":{"x":5,"y":-3}}','--wait']);
    assert.equal(code,0);
    const second=stdout.slice(stdout.indexOf('\ntick:',1)+1);
    assert.match(second,/outcome: target_mined\naction: mine\nwaited_s: [\d.]+\nposition: 5,-2\ninventory: "coal-6 iron-ore\+12"\ndetail: mined=12\nteam: alerts=\["attack near \(0,0\)"\]\nclock: "game 2m; \+3s since your last request"\nchat: unread=1 latest="sol: hi"\n$/);
    assert.doesNotMatch(stdout,/huge|evolution/);
    assert.equal(stdout.match(/clock:/g)?.length,1);
  });
  assert.deepEqual(seen.map(r=>r.action),['observe','mine','status','status','observe']);
});
test('compact --wait on shoot reports the combat outcome, ammo used and the ammo-slot change, not the last movement',async()=>{
  // shake2: Grok's shoot "returned outcome move_to and did not spend ammo";
  // the magazines had gone from the ammo slots, which the diff skipped.
  let polls=0;
  await engine(request=>{
    if(request.action==='observe'){
      const ammo=request.args.peek?[{name:'firearm-magazine',count:10}]:[{name:'firearm-magazine',count:8}];
      return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[{name:'coal',count:5}],ammo},clock:'c'}};
    }
    if(request.action==='shoot')return {ok:true,result:{until_tick:60,ammo:10}};
    polls++;
    return {ok:true,result:polls===1?{active:false,combat:{until_tick:60}}
      :{active:false,combat:false,last:{kind:'move_to',outcome:'arrived'},last_combat:{outcome:'duration_elapsed',ammo_used:2}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','shoot','--args','{"auto":true,"ticks":60}','--wait']);
    assert.equal(code,0);
    const second=stdout.slice(stdout.indexOf('\ntick:',1)+1);
    assert.match(second,/outcome: duration_elapsed\naction: shoot\nwaited_s: [\d.]+\nposition: 1,1\ninventory: firearm-magazine-2\nammo_used: 2\n/);
    assert.doesNotMatch(second,/move_to|arrived/);
  });
});
test('--full keeps the whole completion status; fh wait is compact too',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='walk')return {ok:true,result:{until_tick:60}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:10,max_health:250,inventory:[]},clock:'c'}};
    polls++;
    return {ok:true,result:{active:false,last:{kind:'walk',outcome:'duration_elapsed'},evolution:{factor:0.1},team:request.args.peek?undefined:{board:['x']}}};
  },async port=>{
    const full=await compact(port,['call','walk','--args','{"direction":"east","ticks":60}','--wait','--full']);
    assert.match(full.stdout,/completion:/); assert.match(full.stdout,/evolution/); assert.match(full.stdout,/board=\[x\]/);
    const idle=await compact(port,['wait']);
    assert.match(idle.stdout,/^outcome: duration_elapsed\naction: walk\nwaited_s: [\d.]+\nposition: 1,1\nhealth: "10\/250"\nclock: c\n$/m);
  });
});
test('a compact wait that ends badly still ends with the error line and exits nonzero',async()=>{
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:60}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]},clock:'c'}};
    return {ok:true,result:{active:false,last:{kind:'move_to',outcome:'blocked'}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','move_to','--args','{"position":{"x":9,"y":9}}','--wait']);
    assert.equal(code,1);
    assert.match(stdout,/outcome=blocked/);
    assert.match(stdout,/\nerror: action_interrupted: Control ended: blocked\n$/);
  });
});
test('compact load_silo wait retains the measured cadence when it times out',async()=>{
  await engine(request=>{
    if(request.action==='load_silo')return {ok:true,result:{until_tick:60,waiting:{why:'no rocket'}}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]}}};
    return {ok:true,result:{active:false,last:{kind:'feed',handler:'load_silo',outcome:'timed_out',
      silo_wait:{parts:46,parts_per_min:0.8,idle_window_s:225,gives_up_tick:216000}}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','load_silo','--args','{"items":{"iron-plate":1}}','--wait']);
    assert.equal(code,1);
    assert.match(stdout,/silo_wait:/);
    assert.match(stdout,/parts_per_min[=:] ?0.8/);
    assert.match(stdout,/idle_window_s[=:] ?225/);
  });
});
test('load_silo --wait follows a walking load tour to its end (Sol 07:50)',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='load_silo')return {ok:true,tick:1,result:{op:'load_silo',walk:true,until_tick:18001,needs:'iron-plate 10 (you hold 0)'}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]}}};
    polls++;
    return polls<3?{ok:true,tick:10*polls,result:{active:{kind:'gather',op:'load_silo',until_tick:18001},combat:false}}
      :{ok:true,tick:40,result:{active:false,combat:false,last:{kind:'gather',op:'load_silo',outcome:'launched',loaded:10}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','load_silo','--args','{"items":{"iron-plate":10},"walk":true,"from":{"x":5,"y":5}}','--wait']);
    assert.equal(code,0);
    assert.ok(polls>=3,'polled until the tour ended');
    assert.match(stdout,/launched/);
  });
});
test('kite --wait waits for the fight to end and reports it like move_to',async()=>{
  // Sol, shift09: kite --wait returned at once while the kite still ran.
  for (const end of [
    {last:{kind:'kite',outcome:'clear',why:'no enemies left within the scan radius',kills:7,enemies_left:0,ammo_used:24,ammo_left:16}, code:0},
    {last:{kind:'kite',outcome:'timed_out',why:'time up',kills:2,enemies_left:5,ammo_used:10,ammo_left:30}, code:0},
    {last:{kind:'kite',outcome:'low_health',why:'health 38% fell below min_health 40%',kills:1,enemies_left:9,ammo_used:20,ammo_left:20}, code:1},
  ]) {
    let polls=0;
    await engine(request=>{
      if(request.action==='kite')return {ok:true,result:{until_tick:180,ammo:40,equipped:true}};
      if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:4},health:250,max_health:250,inventory:[]},clock:'c'}};
      polls++;
      return {ok:true,result:polls<3?{active:{kind:'kite',until_tick:180},combat:false}:{active:false,combat:false,last:end.last}};
    },async port=>{
      const {code,stdout}=await compact(port,['call','kite','--args','{"radius":30}','--wait']);
      assert.equal(code,end.code,stdout);
      assert.ok(polls>=3,'it polled until the kite ended');
      const second=stdout.slice(stdout.indexOf('\ntick:',1)+1);
      // A kite that stopped early is a failed wait: the same fields under error_result.
      assert.match(second,new RegExp(`outcome: ${end.last.outcome}\\n\\s*action: kite\\n`));
      for (const key of ['kills','enemies_left','ammo_used','ammo_left'] as const) assert.match(second,new RegExp(`\\n\\s*${key}: ${end.last[key]}\\n`));
      assert.match(second,new RegExp(`\\n\\s*why: "${end.last.why}"\\n`));
      if (end.code) assert.match(stdout,/\nerror: action_interrupted: Control ended: low_health: health 38% fell below min_health 40%\n$/);
    });
  }
});
test('spider_kite --wait waits for the spidertron fight to end and reports kills, rockets and recovery',async()=>{
  // d24 batch191 QAG1: a spidertron's fight runs while the model waits; timed_out is done, as kite's.
  for (const end of [
    {last:{kind:'spider_kite',outcome:'clear',why:'no enemies left within 40 tiles in chunks our force sees',kills:30,enemies_left:0,ammo_used:31,ammo_left:277,spidertron:'spidertron #7 at (1,2), health 100%'}, code:0},
    {last:{kind:'spider_kite',outcome:'timed_out',why:'time up',kills:3,enemies_left:4,ammo_used:5,ammo_left:60,spidertron:'spidertron #7 at (1,2), health 90%'}, code:0},
    {last:{kind:'spider_kite',outcome:'stalled',why:'no progress toward (100,0) for 6 s from (0,0); re-routed once (its route turned 60 degrees)',kills:0,enemies_left:0,ammo_used:0,ammo_left:40,spidertron:'spidertron #7 at (0,0), health 100%',recovery:'re-routed once (its route turned 60 degrees)'}, code:1},
  ]) {
    let polls=0;
    await engine(request=>{
      if(request.action==='spider_kite')return {ok:true,result:{until_tick:180,ammo:40,by:'remote view'}};
      if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:4},health:250,max_health:250,inventory:[]},clock:'c'}};
      polls++;
      return {ok:true,result:polls<3?{active:{kind:'spider_kite',until_tick:180},combat:false}:{active:false,combat:false,last:end.last}};
    },async port=>{
      const {code,stdout}=await compact(port,['call','spider_kite','--args','{"vehicle":7}','--wait']);
      assert.equal(code,end.code,stdout);
      assert.ok(polls>=3,'it polled until the fight ended');
      const second=stdout.slice(stdout.indexOf('\ntick:',1)+1);
      assert.match(second,new RegExp(`outcome: ${end.last.outcome}\\n\\s*action: spider_kite\\n`));
      for (const key of ['kills','enemies_left','ammo_used','ammo_left'] as const) assert.match(second,new RegExp(`\\n\\s*${key}: ${end.last[key]}\\n`));
      assert.ok(second.includes(end.last.spidertron),second);
      if (end.code) assert.ok(second.includes('recovery: "re-routed once (its route turned 60 degrees)"'),second);
    });
  }
});
test('a walk that gave up says why on the error line',async()=>{
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:60}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]},clock:'c'}};
    return {ok:true,result:{active:false,last:{kind:'move_to',outcome:'unreachable',why:'closed in: the character (0.4 tiles wide) fits through no gap out of the area (9,42)-(14,53) (about 45 tiles)',nearest_reachable:{x:9.5,y:42.5}}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','move_to','--args','{"position":{"x":6.5,"y":38.9}}','--wait']);
    assert.equal(code,1);
    assert.match(stdout,/nearest_reachable/);
    assert.match(stdout,/\nerror: action_interrupted: Control ended: unreachable: closed in: the character \(0\.4 tiles wide\) fits through no gap out of the area \(9,42\)-\(14,53\) \(about 45 tiles\)\n$/);
  });
});
test('move_to and drive --wait show gaps, escapes, enemies gone around; no_safe_route fails with why',async()=>{
  // Sol (shift09 03:13): trapped in gaps between pipes and machines; Opus (03:20): walked past a nest, a tank stuck on cliffs.
  const ends=[
    // round1050f: a belt line that mined the rocks and trees in its way.
    {action:'build_path',last:{kind:'build_path',outcome:'path_built',placed:30,skipped:0,next_index:31,total:30,cleared:3,cleared_names:'big-volcanic-rock*2 tree-08*1'},code:0,shown:['placed','cleared','cleared_names'],lines:['big-volcanic-rock*2 tree-08*1']},
    {action:'build_path',last:{kind:'build_path',outcome:'build_failed',placed:4,skipped:0,next_index:5,total:30,next_position:{x:24.5,y:0.5},error:'placement blocked by stone-furnace (24,1)',cleared:1,cleared_names:'huge-rock*1'},code:1,shown:['placed','next_index','next_position','cleared'],lines:['Control ended: build_failed: placement blocked by stone-furnace (24,1)']},
    {action:'transfer',last:{kind:'gather',op:'transfer',outcome:'transferred',moved:43,entities:[{position:{x:15.5,y:53.5},inventory:'chest',moved:43,delivery_note:'fast-inserter (15.5,54.5) takes from this chest -> rocket-silo (15.5,59.5)'}]},code:0,shown:['moved'],lines:['transfers[1]:','rocket-silo (15.5,59.5)']},
    // Round 00:20: a feed explicitly allowing a short succeeds without hiding out_of_items or remaining stops.
    {action:'feed',last:{kind:'gather',op:'feed',outcome:'out_of_items',short_allowed:true,moved:100,left:1},code:0,shown:['moved','left']},
    {action:'feed',last:{kind:'gather',op:'feed',outcome:'out_of_items',moved:100,left:1},code:1,shown:['moved','left']},
    // collectwait: a collect waiting at a machine, what it took against what the inserters took.
    {action:'collect',last:{kind:'gather',outcome:'collected',took:'iron-gear-wheel*11',made:'iron-gear-wheel*10',inserters_took:'iron-gear-wheel*3',crafts:10,waited_s:5},code:0,shown:['took','made','inserters_took','crafts','waited_s']},
    {action:'move_to',last:{kind:'move_to',outcome:'arrived_near',pocket:'(55,21) lies in a gap narrower than 0.7 tiles (assembling-machine-2 (53.5,22.5)) that no path led into; stopped at (51.5,24.4), 4.8 tiles from it (squeeze=true walks in)'},code:0,shown:['pocket']},
    {action:'move_to',last:{kind:'move_to',outcome:'arrived',escaped:'no path led out of the gap at (54.2,21): walked out to (55,24.3) first',avoided_enemies:['2 big-worm-turret around (88,165)'],passed_within_margin:['medium-worm-turret (60,170): 33.7 tiles (range 30)']},code:0,shown:['escaped','avoided_enemies','passed_within_margin']},
    {action:'move_to',last:{kind:'move_to',outcome:'unreachable',why:'closed in: ...; mining pipe (-27.5,69.5) opens a way out to (-26.7,69.5)',mine_to_get_out:['pipe (-27.5,69.5)']},code:1,shown:['mine_to_get_out']},
    {action:'move_to',last:{kind:'move_to',outcome:'no_safe_route',why:'no way to (100,0) around 4 medium-worm-turret around (100,0): the path passes medium-worm-turret (60,0) (range 30 + 4) at 0.0 tiles'},code:1,shown:[]},
    // movetarget: a walk to an entity's reach, an end within reach counted as arrived.
    {action:'move_to',last:{kind:'move_to',outcome:'arrived',reach:'iron-chest (20.5,0.5): 9.6 tiles to its box (transfer reach 10)',reach_note:'within its reach already when the walk ended unreachable'},code:0,shown:['reach','reach_note'],lines:['9.6 tiles to its box (transfer reach 10)','when the walk ended unreachable']},
    // round0620c: a via walk's legs, a build spot, a squeeze walked along gaps.
    {action:'move_to',last:{kind:'move_to',outcome:'arrived',legs:[{to:{x:10,y:100},outcome:'arrived',s:1.9,avoided_enemies:['1 medium-worm-turret around (14,104)']},{to:{x:32,y:104},outcome:'arrived',s:2.4}],squeezed:'no path request led into the gaps: walked them from (60.5,160.5) to (60,150.5)'},code:0,shown:['legs','squeezed'],lines:['(10,100) arrived 1.9s; around 1 medium-worm-turret around (14,104)','(32,104) arrived 2.4s']},
    {action:'move_to',last:{kind:'move_to',outcome:'unreachable',why:'no path request found a way for the character to (60.5,140.5), nor to anywhere within 15 tiles of it',build_spot:{x:60,y:150},build_spot_note:'(60,150) is reachable and within build reach of (60.5,140.5): 9.5 tiles (build reach 10); it lies in a gap narrower than 0.7 tiles',build_spot_squeeze:true,legs:[{to:{x:10,y:100},outcome:'unreachable',s:0.2,why:'no path'},{to:{x:32,y:104},outcome:'not walked'}]},code:1,shown:['build_spot','build_spot_note','build_spot_squeeze','legs'],lines:['(10,100) unreachable 0.2s: no path','(32,104) not walked']},
    // retreat: the walk back that got there ends retreated (exit 1, so a chained next step does not run), saying why.
    {action:'move_to',last:{kind:'move_to',outcome:'retreated',why:'health 36% (90/250) under 40%; back at (-10,0)',retreated:{why:'health 36% (90/250) under 40%',from:{x:20,y:0},health:'90/250',to:{x:-10,y:0},health_now:'95/250',going:'back at (-10,0)'}},code:1,shown:['retreated'],lines:['Control ended: retreated: health 36% (90/250) under 40%; back at (-10,0)']},
    // drivesafe: the plan, a stop short of the target, ours it braked for; a dry run's preview exits 0.
    {action:'vehicle',last:{kind:'drive',outcome:'arrived',path_length:48,plan:'turning room, near the target',stopped_short:'7.5 tiles from (-265,-386): the tank\'s turning room fits no closer (our entities or obstacles around it)',spared:'pumpjack (-261.5,-398.5)'},code:0,shown:['plan','stopped_short','spared'],lines:['7.5 tiles from (-265,-386)']},
    {action:'vehicle',last:{kind:'drive',outcome:'previewed',preview:{path:'(-229.2,-390.2) (-257.5,-385.5)',path_length:48,plan:'turning room',touches:'none'}},code:0,shown:['preview'],lines:['touches=none']},
    {action:'vehicle',last:{kind:'drive',outcome:'arrived',remote:true,vehicle:'tank, unit_number 311799',shots:120,kills:3,kills_by_name:'2 small-biter, 1 medium-biter'},code:0,shown:['remote','vehicle','shots','kills','kills_by_name']},
    {action:'vehicle',last:{kind:'drive',outcome:'arrived',path_length:69,backed_up:'stuck at (30.0,123.7) (in front: cliff (30,126.5)): backed up and asked for a new path',avoided_enemies:['1 medium-worm-turret around (60,170)']},code:0,shown:['path_length','backed_up','avoided_enemies']},
  ];
  for (const end of ends) {
    let polls=0;
    await engine(request=>{
      if(request.action===end.action)return {ok:true,result:{until_tick:180}};
      if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:4},health:250,max_health:250,inventory:[]},clock:'c'}};
      polls++;
      return {ok:true,result:polls<2?{active:{kind:end.last.kind,until_tick:180}}:{active:false,last:end.last}};
    },async port=>{
      const args=end.action==='transfer'?'{"position":{"x":15.5,"y":53.5},"item":"low-density-structure","walk":true}':end.action==='feed'?'{"radius":20,"item":"coal","up_to":true}':end.action==='vehicle'?'{"drive":{"x":30,"y":145}}':end.action==='collect'?'{"position":{"x":55,"y":21},"wait_ticks":300}':'{"position":{"x":55,"y":21}}';
      const {code,stdout}=await compact(port,['call',end.action,'--args',args,'--wait']);
      assert.equal(code,end.code,stdout);
      // A wait that ended in success lists fields one per line; a failed one on the error_result line (key=value).
      for (const key of end.shown) assert.match(stdout,new RegExp(`(\\n\\s*|\\s)${key}[:=]`),key);
      for (const line of (end as any).lines ?? []) assert.ok(stdout.includes(line),`${line} in ${stdout}`);
      if (end.last.outcome==='no_safe_route') assert.match(stdout,/\nerror: action_interrupted: Control ended: no_safe_route: no way to \(100,0\) around/);
    });
  }
});
test('a timed collect or a load_silo tour blocks without --wait, its outcome the exit status; --no-wait returns at acceptance',async()=>{
  // batch24 A1 (Grok): both returned exit 0 at acceptance while the character worked on.
  const cases=[
    {action:'load_silo',args:'{"position":{"x":65.5,"y":14.5},"items":{"agricultural-science-pack":1000},"from":{"x":14.5,"y":28.5},"walk":true,"launch":true}',last:{kind:'gather',outcome:'launched',moved:226},code:0,line:/outcome: launched/},
    {action:'collect',args:'{"position":{"x":21.5,"y":33.5},"item":"rocket-fuel","count":20,"wait_ticks":7200}',last:{kind:'gather',outcome:'collected',moved:20},code:0,line:/outcome: collected/},
    {action:'collect',args:'{"position":{"x":21.5,"y":33.5},"item":"rocket-fuel","count":20,"keep_taking":true}',last:{kind:'gather',outcome:'failed',error:'the machine stopped'},code:1,line:/Control ended: failed: the machine stopped/},
  ];
  for (const c of cases) for (const flags of [[],['--no-wait']]) {
    let polls=0;
    await engine(request=>{
      if(request.action===c.action)return {ok:true,result:{until_tick:180}};
      if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:4},health:250,max_health:250,inventory:[]},clock:'c'}};
      polls++;
      return {ok:true,result:polls<2?{active:{kind:c.last.kind,until_tick:180}}:{active:false,last:c.last}};
    },async port=>{
      const {code,stdout}=await compact(port,['call',c.action,'--args',c.args,...flags]);
      if (flags.length) { assert.equal(code,0,stdout); assert.equal(polls,0); assert.match(stdout,/until_tick: 180/); }
      else { assert.equal(code,c.code,stdout); assert.ok(polls>=2,`${c.action} polled until it ended: ${stdout}`); assert.match(stdout,c.line); }
    });
  }
  // A collect with no wait_ticks or keep_taking stays as it was (at once).
  let polls=0;
  await engine(request=>{
    if(request.action==='collect')return {ok:true,result:{until_tick:180,moved:3}};
    polls++; return {ok:true,result:{active:false}};
  },async port=>{
    const {code}=await compact(port,['call','collect','--args','{"position":{"x":1,"y":1},"item":"coal"}']);
    assert.equal(code,0); assert.equal(polls,0);
  });
  const both=await compact(1,['call','collect','--args','{}','--wait','--no-wait']);
  assert.notEqual(both.code,0); assert.match(both.stdout,/--wait or --no-wait, not both/);
});
test('belt_flow waits for its sampling: it reads belt_flow {} until the result is in; --no-wait returns the start',async()=>{
  for (const flags of [[],['--no-wait']]) {
    const seen:any[]=[];
    await engine(request=>{
      if(request.action!=='belt_flow')return {ok:true,result:{}};
      seen.push(request.args);
      if(request.args.position)return {ok:true,result:{sampling:true,until_tick:600,seconds:2,points:['section end (3.5,0.5)']}};
      return {ok:true,result:seen.length<3?{sampling:true,seconds_left:1}:{done:true,lines:['section (1.5,0.5) to (3.5,0.5) (3 tiles): left lane 112.5/min (iron-plate 4); right lane empty']}};
    },async port=>{
      const {code,stdout}=await compact(port,['call','belt_flow','--args','{"position":{"x":2.5,"y":0.5},"seconds":2}',...flags]);
      assert.equal(code,0,stdout);
      if (flags.length) { assert.equal(seen.length,1); assert.match(stdout,/sampling: true/); }
      else { assert.equal(seen.length,3); assert.match(stdout,/left lane 112\.5\/min/); }
    });
  }
});
test('a build that waited for a hand craft and then failed keeps the blocker on the error line',async()=>{
  // Sol, shift09: the silo build hit trees after its craft and read "Control ended: failed".
  let polls=0;
  const error='placement blocked by stingfrond (63.9375,11.375), stingfrond (68.125,12.4375); it needs the trees mined first (mine them, or place_ghosts marks them and construct clears them)';
  await engine(request=>{
    if(request.action==='build')return {ok:true,result:{awaiting_craft:{item:'rocket-silo',held:0,need:1,crafting:1},until_tick:900}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:60,y:19},health:250,max_health:250,inventory:[]},clock:'c'}};
    polls++;
    return {ok:true,result:polls<2?{active:{kind:'feed',awaiting_craft:true,until_tick:900}}:{active:false,last:{kind:'feed',handler:'build',outcome:'failed',tick:5,error}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','build','--args','{"item":"rocket-silo","position":{"x":65.5,"y":14.5}}','--wait']);
    assert.equal(code,1);
    assert.match(stdout,/error_result: outcome=failed action=build /);
    assert.ok(stdout.endsWith(`\nerror: action_interrupted: Control ended: failed: ${error}\n`),stdout);
  });
});
test('drop --wait follows a full drop\'s pods that wait for a hatch, apart from the character\'s action',async()=>{
  let polls=0;
  const pods=[{pod:1,drop:4,items:'iron-plate*1000',slots:10},{pod:2,drop:5,items:'coal*300',slots:6}];
  await engine(request=>{
    if(request.action==='drop')return {ok:true,result:{drop:4,pods:[pods[0]],pods_waiting:'1 more pod wait for a free hatch',until_tick:900}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]},clock:'c'}};
    polls++;
    // The character walks meanwhile: its own action is no part of the drop's wait.
    return {ok:true,result:polls<3?{active:{kind:'move_to',until_tick:5000},drop_pending:{kind:'drop',pods_sent:1,pods_left:1,until_tick:900}}
      :{active:{kind:'move_to',until_tick:5000},last_drop:{kind:'drop',outcome:'dropped',tick:7,result:{pods,dropped:['iron-plate*1000','coal*300']}}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','drop','--args','{"platform":"Sunward","full":true,"items":[{"item":"iron-plate","count":1000},{"item":"coal","count":300}]}','--wait']);
    assert.equal(code,0,stdout);
    assert.ok(polls>=3,'it polled until the pods were sent');
    assert.match(stdout,/outcome: dropped\n\s*action: drop\n/);
    assert.match(stdout,/coal\*300/);
  });
  // Pods not sent: the error line says why.
  polls=0;
  await engine(request=>{
    if(request.action==='drop')return {ok:true,result:{drop:4,pods:[pods[0]],until_tick:900}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]},clock:'c'}};
    polls++;
    return {ok:true,result:polls<2?{drop_pending:{kind:'drop',pods_left:1,until_tick:900}}
      :{last_drop:{kind:'drop',outcome:'failed',tick:7,why:'platform Sunward left vulcanus (at vulcanus->nauvis 2%)',result:{pods:[pods[0]],not_sent:'coal*300'}}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','drop','--args','{"platform":"Sunward","full":true,"items":[{"item":"coal","count":300}]}','--wait']);
    assert.equal(code,1);
    assert.ok(stdout.endsWith('\nerror: action_interrupted: Control ended: failed: platform Sunward left vulcanus (at vulcanus->nauvis 2%)\n'),stdout);
  });
});
test('polls fall back to plain status on a runtime without peek',async()=>{
  const seen:any[]=[];
  await engine(request=>{
    seen.push(request);
    if(request.args?.peek)return {ok:false,error:{code:'invalid_argument',message:'unknown argument peek for status'}};
    if(request.action==='walk')return {ok:true,result:{until_tick:60}};
    return {ok:true,result:{active:false,last:{kind:'walk',outcome:'duration_elapsed'}}};
  },async port=>{
    const {stdout}=await cli(port,['call','walk','--args','{"direction":"east","ticks":60}','--wait']);
    assert.equal(JSON.parse(stdout).ok,true);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args.peek??false]),[['walk',false],['status',true],['status',false]]);
});

test('fh view platform=NAME writes a platform schematic PNG',async()=>{
  const {mkdtemp,readFile,rm}=await import('node:fs/promises');
  const {tmpdir}=await import('node:os');
  const {join}=await import('node:path');
  const dir=await tempDir('fh-platform-view-');
  try {
    await engine(request=>{
      assert.equal(request.action,'observe');assert.equal(request.args.platform,'Sunward');assert.equal(request.args.tiles,true);
      return {ok:true,result:{platform:'Sunward',position:{x:0,y:0},entities:[],tiles:[{name:'space-platform-foundation',position:{x:0,y:0}}]}};
    },async port=>{
      const path=join(dir,'sunward.png');
      const {stdout}=await cli(port,['view','platform=Sunward','--out',path]);
      const result=JSON.parse(stdout).result;
      assert.equal(result.kind,'platform-schematic');assert.equal(result.platform,'Sunward');assert.deepEqual(result.position,{x:0,y:0});
      assert.equal((await readFile(path)).subarray(0,8).toString('hex'),'89504e470d0a1a0a');
    });
  } finally {await rm(dir,{recursive:true,force:true});}
});

test('fh view draws round the position asked; an area is its centre and radius (batch26 A4, Opus)',async()=>{
  const {readFile,rm}=await import('node:fs/promises');
  const {join}=await import('node:path');
  const dir=await tempDir('fh-view-');
  try {
    const seen:any[]=[];
    await engine(request=>{
      seen.push(request.args);
      return {ok:true,result:{player:{position:{x:0,y:0}},entities:[{name:'gun-turret',position:{x:5,y:563}}],tiles:[]}};
    },async port=>{
      const path=join(dir,'v.png');
      let r=JSON.parse((await cli(port,['view','--args','{"position":{"x":5,"y":563},"radius":26}','--out',path])).stdout).result;
      assert.deepEqual(r.position,{x:5,y:563}); assert.deepEqual(seen[0].position,{x:5,y:563}); assert.equal(seen[0].radius,26);
      r=JSON.parse((await cli(port,['view','--args','{"area":{"left_top":{"x":-20,"y":540},"right_bottom":{"x":30,"y":590}}}','--out',path])).stdout).result;
      assert.deepEqual(seen[1].position,{x:5,y:565}); assert.equal(seen[1].radius,25); assert.equal(seen[1].area,undefined); assert.deepEqual(r.position,{x:5,y:565});
      assert.equal((await readFile(path)).subarray(0,8).toString('hex'),'89504e470d0a1a0a');
      await assert.rejects(cli(port,['view','--args','{"area":{"left_top":{"x":0,"y":0},"right_bottom":{"x":100,"y":100}}}','--out',path]),(e:any)=>/at most 64x64/.test(e.stdout));
    });
  } finally {await rm(dir,{recursive:true,force:true});}
});
test('CLI waits follow a silo deadline extension; explicit timeouts still stop',async()=>{
  const dir=await tempDir('fh-silo-clock-');
  const preload=join(dir,'clock.cjs');
  // Accelerate the wall clock only. Real one-second polling crosses the old
  // 30-second budget, so this catches a wait that keeps its acceptance limit.
  await writeFile(preload,'const real=Date.now.bind(Date);const start=real();Date.now=()=>start+(real()-start)*100;');
  try {
    for (const args of [['call','load_silo','--wait'],['wait'],['wait','--wait-timeout','50']]) {
      let polls=0;
      await engine(request=>{
        if(request.action==='load_silo')return {ok:true,tick:1,result:{until_tick:61,waiting:{why:'no rocket'}}};
        polls++;
        return {ok:true,tick:1+(polls-1)*6000,result:polls<4?{active:{kind:'feed',until_tick:polls===1?61:24001,
          silo_wait:{gives_up_tick:216001}},combat:false}:{active:false,combat:false,last:{kind:'feed',handler:'load_silo',outcome:'fed'}}};
      },async port=>{
        const run=()=>exec(process.execPath,['--require',preload,'dist/host/cli.js','--format','json','--port',String(port),...args],
          {env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
        if(args.includes('--wait-timeout')) await assert.rejects(run(),(e:any)=>{assert.equal(JSON.parse(e.stdout).error.code,'wait_timeout');return true;});
        else {const {stdout}=await run();assert.equal(JSON.parse(stdout).ok,true);assert(polls>=4);}
      });
    }
  } finally {await rm(dir,{recursive:true,force:true});}
});

test('refuel area --wait follows the gather and retains fuel source facts',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='refuel')return {ok:true,result:{until_tick:180,op:'refuel',places:2}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:30,y:0},health:250,max_health:250,inventory:[]}}};
    polls++;
    return {ok:true,result:polls<2?{active:{kind:'gather',until_tick:180}}:{active:false,last:{kind:'gather',op:'refuel',outcome:'topped_up',moved:20,fuel_taken:20,sources:[{name:'iron-chest',taken:20}]}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','refuel','--args','{"area":{"left_top":{"x":0,"y":0},"right_bottom":{"x":40,"y":10}},"from":"nearest"}','--wait']);
    assert.equal(code,0,stdout);assert.ok(polls>=2);assert.match(stdout,/outcome: topped_up/);assert.match(stdout,/fuel_taken: 20/);assert.match(stdout,/iron-chest/);
  });
});

test('failed feed --wait retains the verified smaller-margin facts in compact output',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='feed')return {ok:true,result:{until_tick:180,op:'feed',places:1}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:0,y:0},health:250,max_health:250,inventory:[]}}};
    polls++;
    return {ok:true,result:polls<2?{active:{kind:'gather',until_tick:180}}:{active:false,last:{kind:'gather',op:'feed',outcome:'unreached',
      why:'no route at requested clearance',route_failures:[{position:{x:40,y:0},smaller_margins:{largest_verified_margin:2,line:'largest verified margin 2 tiles'}}]}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','feed','--args','{"item":"coal","count":1,"radius":32}','--wait']);
    assert.equal(code,1,stdout);assert.match(stdout,/largest_verified_margin=2/);assert.match(stdout,/largest verified margin 2 tiles/);
  });
});
test('a flag the command does not read is refused before anything is sent, naming the flags it takes (batch35 A1, Astra: --file on fh call sent {})',async()=>{
  const sent:any[]=[];
  await engine(request=>{ sent.push(request); return {ok:true,result:{}}; },async port=>{
    const refused=async(args:string[])=>{ try { await cli(port,args); } catch (e:any) { assert.equal(e.code,1); const out=String(e.stdout).trim(); return out.startsWith('{') ? JSON.parse(out).error.message as string : out.replace(/^error: client_error: /,''); } assert.fail(`${args.join(' ')} was not refused`); };
    let m=await refused(['call','upgrade_belts','--file','x.json','--bot','astra','--journal','/dev/null']);
    assert.match(m,/^fh call upgrade_belts does not take --file \(--file is for fh queue submit\|repeat\|edit, fh plan save, fh blueprint import, fh run, fh deploy\); nothing was sent\. fh call upgrade_belts takes --args, --args-file, --since, --limit, --peek, the connection flags/);
    m=await refused(['upgrade_belts','--file','x.json']);
    assert.match(m,/^fh upgrade_belts does not take --file/);
    m=await refused(['call','sleep','30','--until','crafting_done']);
    assert.match(m,/^fh call sleep does not take --until \(--until is for fh sleep, fh wait\)/);
    m=await refused(['sleep','30','--file','x']);
    assert.match(m,/^fh sleep does not take --file .*fh sleep takes --args, --args-file, --until, --then, --require-met/);
    m=await refused(['queue','status','--file','x']);
    assert.match(m,/^fh queue status does not take --file/);
    m=await refused(['view','--file','x']);
    assert.match(m,/^fh view does not take --file .*fh view takes --args, --args-file, --out/);
    // a flag no command has: node's error named neither the command nor its flags
    m=await refused(['call','status','--argz','{}']);
    assert.match(m,/^fh call status does not take --argz \(no fh command has it\); nothing was sent\. fh call status takes --args/);
    m=await refused(['more','--wait']);
    assert.match(m,/^fh more does not take --wait; nothing was sent\. fh more takes no flags of its own, the connection flags \(--player, --session, --socket, --timeout, --id \.\.\.\), and everywhere --format/);
    m=await refused(['call','upgrade_belts','x.json']);
    assert.equal(m,'fh call upgrade_belts takes its arguments as --args JSON or --args-file FILE; the words "x.json" after it are not read, so nothing was sent');
    m=await refused(['upgrade_belts','a','b']);
    assert.match(m,/the words "a" "b" after it are not read/);
    assert.deepEqual(sent,[]);
    // the flags each takes still go
    await cli(port,['call','status','--args','{}','--wait','--bot','astra']);
    await cli(port,['status','--no-wait','--wake-local','--limit','5']);
    await cli(port,['call','blueprint_export','--args','{"layout":true}','--out','/dev/null']);
    assert.equal(sent.length,3);
  });
});
// d22 batch106 BP1 (Luna: "the wait action returns a stale completed gather rather than waiting" while her belt_flow
// sample ran): fh wait's polls ask for the watches (status {brief, work}); with no action running and a belt_flow sample
// begun after the last action ended, it waits for the sample and gives its result.
const flowRow=(state:string,end=160)=>({id:'belt_flow@100',kind:'belt_flow',scope:'5 points',state,start_tick:100,end_tick:end,line:'belt_flow@100 5 points: '+state});
test('fh wait with no action running waits for a running belt_flow sample and gives its result; its polls ask for work',async()=>{
  const seen:any[]=[]; let polls=0;
  await engine(request=>{
    seen.push(request);
    if(request.action==='status'){polls++; const tick=100+polls*20;
      return {ok:true,tick,result:{active:false,combat:false,last:{kind:'gather',outcome:'timed_out',tick:50},watches:[flowRow(tick<160?'running':'done')]}};}
    if(request.action==='belt_flow')return {ok:true,tick:170,result:{lines:['section (1.5,0.5) to (3.5,0.5) (3 tiles): left lane 112.5/min (iron-plate 4)'],samples:12}};
    return {ok:true,result:{}};
  },async port=>{
    const json=JSON.parse((await cli(port,['wait'])).stdout);
    assert.equal(json.ok,true); assert.equal(json.result.waited_for,'belt_flow@100');
    assert.deepEqual(json.result.lines,['section (1.5,0.5) to (3.5,0.5) (3 tiles): left lane 112.5/min (iron-plate 4)']);
    assert.equal(json.result.note,'no action ran when this wait began; it waited for your belt_flow sample belt_flow@100 (until tick 160): this is its result');
    const statuses=seen.filter(r=>r.action==='status');
    assert(statuses.length>=3 && statuses.every(r=>r.args.work===true && r.args.brief===true),JSON.stringify(statuses.map(r=>r.args)));
    assert.equal(seen.filter(r=>r.action==='belt_flow').length,1);
  });
  // compact: the result's lines and the note
  polls=0;
  await engine(request=>{
    if(request.action==='status'){polls++; const tick=100+polls*20; return {ok:true,tick,result:{active:false,combat:false,last:false,watches:[flowRow(tick<160?'running':'done')]}};}
    if(request.action==='belt_flow')return {ok:true,tick:170,result:{lines:['section (1.5,0.5) to (3.5,0.5) (3 tiles): left lane 112.5/min (iron-plate 4)']}};
    return {ok:true,result:{}};
  },async port=>{
    const {code,stdout}=await compact(port,['wait']);
    assert.equal(code,0,stdout); assert.match(stdout,/left lane 112\.5\/min/); assert.match(stdout,/it waited for your belt_flow sample belt_flow@100/);
  });
});
test('fh wait on a belt_flow sample keeps --max and the wake rules: STILL SAMPLING at the cap, a tell ends it with the sample going on',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='status'){polls++; return {ok:true,tick:100+polls*20,result:{active:false,combat:false,last:false,watches:[flowRow('running',100000)]}};}
    return {ok:true,result:{}};
  },async port=>{
    await assert.rejects(cli(port,['wait','--max','1']),(error:any)=>{
      const reply=JSON.parse(error.stdout);
      assert.equal(reply.error.code,'wait_timeout');
      assert.match(reply.error.message,/^your belt_flow sample belt_flow@100 is STILL SAMPLING: the wait gave up after \d+ s, up to \d+ s more, until tick 100000\. No action of yours or stop ends it; belt_flow \{\} reads its result once it ends/);
      assert.match(reply.result.still_running,/^belt_flow sample belt_flow@100, up to \d+ s more$/); return true;
    });
  });
  polls=0;
  await engine(request=>{
    if(request.action==='status'){polls++; const tick=100+polls*20;
      return {ok:true,tick,result:{active:false,combat:false,last:false,watches:[flowRow('running',100000)],...(polls>=2?{inbox:{tick:130,woke:'told',from:'sol'}}:{})}};}
    return {ok:true,result:{}};
  },async port=>{
    // exit 3: the wait ended while the sample goes on, said on stderr as a sample's
    await assert.rejects(cli(port,['wait']),(error:any)=>{
      assert.equal(error.code,3);
      const json=JSON.parse(error.stdout);
      assert.equal(json.ok,true); assert.equal(json.result.outcome,'told'); assert.equal(json.result.from,'sol');
      assert.match(json.result.still_running,/^belt_flow sample belt_flow@100, up to \d+ s more$/);
      assert.match(json.result.note,/a tell from sol ended this wait \(the team block has it\); your belt_flow sample belt_flow@100 keeps going: fh wait waits for it again/);
      assert.match(error.stderr,/still running \(exit 3\): belt_flow sample belt_flow@100, up to \d+ s more goes on after this wait ended; fh wait resumes waiting for it\. No action of yours or stop ends it \(it ends at its until_tick\)/);
      assert.doesNotMatch(error.stderr,/A call that drives your character/); return true;
    });
  });
});
test('fh wait names the other watches running, and a sample begun before the action that ended, without waiting for them',async()=>{
  const uptime={id:'uptime@90',kind:'uptime',scope:'4 machines',state:'running',start_tick:90,end_tick:4000,line:'uptime@90 ...'};
  const flight={id:'flight#3',kind:'flight_watch',scope:'Spindle',state:'running',start_tick:95,end_tick:9000,line:'flight watch #3 ...'};
  let polls=0;
  await engine(request=>{
    if(request.action==='status'){polls++; return {ok:true,tick:400,result:{active:false,combat:false,last:{kind:'move_to',outcome:'arrived',tick:390},
      watches:[uptime,flight,{...uptime,id:'turret_tally@80',kind:'turret_tally',state:'done'}]}};}
    return {ok:true,result:{}};
  },async port=>{
    const json=JSON.parse((await cli(port,['wait'])).stdout);
    assert.equal(json.ok,true); assert.equal(polls>=1,true); assert.equal(json.result.last.outcome,'arrived');
    assert.deepEqual(json.result.watches.map((r:any)=>r.id),['uptime@90','flight#3']);
    assert.equal(json.result.note,'no action runs; your uptime uptime@90 runs until tick 4000 (60 s more): no action of yours or stop ends it; uptime {} reads its result; '
      +'your flight_watch flight#3 runs until tick 9000 (144 s more): no action of yours or stop ends it; flight_watch {id: 3} reads its result');
  });
  // the move_to ended at tick 390, after the sample began at 100: the wait is the move_to's, the sample named
  await engine(request=>{
    if(request.action==='status')return {ok:true,tick:400,result:{active:false,combat:false,last:{kind:'move_to',outcome:'arrived',tick:390},watches:[flowRow('running',1000)]}};
    return {ok:true,result:{}};
  },async port=>{
    const json=JSON.parse((await cli(port,['wait'])).stdout);
    assert.equal(json.result.last.outcome,'arrived'); assert.equal(json.result.waited_for,undefined);
    assert.match(json.result.note,/your belt_flow belt_flow@100 runs until tick 1000 \(10 s more\): no action of yours or stop ends it; belt_flow \{\} \(fh call belt_flow \{\} waits for it\) reads its result/);
    const {stdout}=await compact(port,['wait']);
    assert.match(stdout,/your belt_flow belt_flow@100 runs until tick 1000/);
  });
});
